#!/usr/bin/ruby

require 'open-uri'
require 'logger'
require 'json'
require 'yaml'
require 'timeout'
require 'singleton'
require 'etc'
require 'syslog'
require 'socket'

class Utils
	include Singleton
	attr_reader :log
	attr_reader :syslog
	attr_reader :ec2_work_dir

	def initialize()
		@log = Logger.new(STDERR)
		@log.level = Logger::ERROR
		@syslog = Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS)

		@ec2_work_dir = '/var/lib/puppet/ec2'
	end
	
	def email(to, subject, contents)
		headers = [
			"From: #{Etc.getlogin}  <#{Etc.getlogin}@#{Socket.gethostname}>",
			"To: #{to}",
			"Subject: #{subject}"
		]
		message = headers.join("\n") + "\n" + contents + "\n"
		IO.popen("mail -s '#{subject}' #{to}", 'w+') { |m|
			m.write(message)
			m.write("\n.\n")
		}
	end
	
	def get_next_friendly_name(type)
		serial_file = @ec2_work_dir + "/#{type}.serial"
		prev_serial = 0
		if File.exists?(serial_file)
			prev_serial = IO.read(serial_file).to_i
		end
		serial = prev_serial + 1
		f=File.new(serial_file, 'w')
		f.write(serial)
		f.close()
		return "#{type}-#{serial}"
	end
	
	def runas(user)
		if Etc.getpwuid(Process.uid).name != user
			abort("please run this as #{user}")
		end
	end

	def uri_fetch(uri)
		uri_data = nil
		begin
			status = Timeout::timeout(2) do
				@log.info("fetching uri item #{uri}")
				uri_data = open(uri).read()
				@log.debug("fetched #{uri_data}")
			end
		rescue Exception => e
			@log.error("uri fetchh caught error #{e.to_s}")
			return nil
		end
		return uri_data
	end

	def metadata_fetch(item)
		return uri_fetch("http://169.254.169.254/latest/meta-data/" + item)
	end
	
	def inventory_rpc(rpc)
		return uri_fetch("http://localhost:8080/v2/" + rpc)
	end

	def cmd(command)
		@log.info("calling command #{command}")
		
		command_out=`#{command}`
		if $?.to_i !=0
			@log.error("command #{command} failed")
			@log.error("output: #{command_out}")
			return nil
		end
		return command_out
	end

	def lock_file(file_path)
		lock_file = File.new(file_path, 'w')

		locked = lock_file.flock( File::LOCK_NB|File::LOCK_EX )
		if locked
			return lock_file
		end
		return locked
	end
	
	def unlock_file(locked_file)
		unlocked = locked_file.flock(File::LOCK_UN)
		if unlocked
			locked_file.close()
		end
		return unlocked
	end	
end

class Ec2Cli
	def initialize()
		@utils = Utils.instance
		@default_region = nil
	end

	def get_region
		if not @default_region
			zone = @utils.metadata_fetch('placement/availability-zone')
			if not zone
				@utils.log.error('Could not automatically determine ec2 region')
			end 
			@default_region = zone[0..-2]
		end
		return @default_region
	end

	def cli(command, region=nil)
		@utils.log.info("calling ec2 command #{command}")

		region = get_region() unless region
		
		if not region
			@utils.log.error("could not find ec2 region")
			return nil
		end
		
		ec2_command_out=@utils.cmd("/usr/local/bin/aws --region=#{region} ec2 #{command} 2>&1")
		if not ec2_command_out or ec2_command_out.empty?
			@utils.log.error("aws api command #{command} failed")
			return nil
		end
		return ec2_command_out
	end
end


class Ec2Instances
	def initialize(timeout=300)
		@utils = Utils.instance
		@ec2 = Ec2Cli.new()
		@utils.log.info('Ec2Instances cache starting up')

		@cache_dir = @utils.ec2_work_dir
		@cache_file = @cache_dir + '/instance_cache.yaml'
		@cache_timeout = timeout
		@instances = load_cache()
	end

	def method_missing(name, *args, &block)
		@instances.send(name, *args, &block)
	end
	
	def load_cache()
		if not File.exists?(@cache_file) or get_file_age(@cache_file) > @cache_timeout
			update_cache()
		end
		@utils.log.info("loading cache #{@cache_file}")
		yml = IO.read(@cache_file)
		@utils.log.debug("yml: #{yml}")
		instances = YAML.load( yml )
		@utils.log.debug("instances is #{instances}")
		return instances
	end

	def check_make_cache_dir
		Dir.mkdir(@cache_dir) unless File.exists?(@cache_dir)
	end

	def get_file_age(file)
		return Time.now - File.mtime(file)
	end

	def colapse_ec2_tags(instance)
		if instance.has_key?('Tags')
			instance["RawTags"] = instance["Tags"].clone
			tags = {}
			instance["Tags"].each do |tag|
				tags[ tag["Key"] ] = tag["Value"]
			end
			instance["Tags"] = tags
		end
	end

	def update_cache
		@utils.log.info("updating #{@cache_file}")
		primary_mac_address = @utils.metadata_fetch('network/interfaces/macs/').split('\n')[0]
		vpc_id = @utils.metadata_fetch("network/interfaces/macs/#{primary_mac_address}/vpc-id")
		
		if not primary_mac_address or not vpc_id
			return nil
		end
		
		instances = {}
	
		response_json = @ec2.cli("describe-instances --filters 'Name=vpc-id,Values=#{vpc_id}'")
		if not response_json
			return nil
		end
		response=JSON.parse( response_json )
	
		response["Reservations"].each do |reservation|
			reservation["Instances"].each do |instance|
				@utils.log.info("Found instance " + instance["InstanceId"])
				colapse_ec2_tags(instance)
				instances[instance["InstanceId"]]=instance
			end
		end
	 
		@utils.log.debug("instances is #{instances}")

	 	@utils.log.info("writing cache file #{@cache_file}.tmp")
		f=File.new(@cache_file + '.tmp', 'w')
		f.write(YAML.dump(instances))
		f.close()
	 	@utils.log.info("moving cache file #{@cache_file}.tmp to #{@cache_file}")
		File.rename(@cache_file + '.tmp', @cache_file)
	end
end

class PuppetInventory
	def initialize()
		@utils = Utils.instance
		
		@utils.log.info('PuppetInventory Starting up')
		@nodes = nil
	end
	
	def rpc(rpc_url)
		response_json = @utils.inventory_rpc(rpc_url)
		if not response_json
			return nil
		end
		response=JSON.parse( response_json )
		return response
	end
	
	def nodes
		if not @nodes
			@nodes = {}
			rpc('nodes').each do |node|
				@nodes[node['name']] = node
			end
		end
		return @nodes
	end
end
