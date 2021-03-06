require "synapse/service_watcher/base/base"

require 'thread'
require 'resolv'

class Synapse::ServiceWatcher
  class DnsWatcher < BaseWatcher
    def start
      @check_interval = @discovery['check_interval'] || 30.0
      @nameserver = @discovery['nameserver']

      @watcher = Thread.new do
        watch
      end
    end

    def ping?
      @watcher.alive? && !(resolver.getaddresses('airbnb.com').empty?)
    end

    def discovery_servers
      @discovery['servers']
    end

    private
    def validate_discovery_opts
      raise ArgumentError, "invalid discovery method #{@discovery['method']}" \
        unless @discovery['method'] == 'dns'
      raise ArgumentError, "a non-empty list of servers is required" \
        if discovery_servers.empty?
    end

    def watch
      last_resolution = resolve_servers
      configure_backends(last_resolution)
      until @should_exit
        begin
          start = Time.now
          current_resolution = resolve_servers
          unless last_resolution == current_resolution
            last_resolution = current_resolution
            configure_backends(last_resolution)
          end

          sleep_until_next_check(start)
        rescue => e
          log.warn "synapse: dns error in watcher thread: #{e.inspect}"
          log.warn e.backtrace
        end
      end

      log.info "synapse: dns watcher exited successfully"
    end

    def sleep_until_next_check(start_time)
      sleep_time = @check_interval - (Time.now - start_time)
      if sleep_time > 0.0
        sleep(sleep_time)
      end
    end

    IP_REGEX = Regexp.union([Resolv::IPv4::Regex, Resolv::IPv6::Regex])

    def resolve_servers
      resolver.tap do |dns|
        resolution = discovery_servers.map do |server|
          if server['host'] =~ IP_REGEX
            addresses = [server['host']]
          else
            addresses = dns.getaddresses(server['host']).map(&:to_s)
          end
          [server, addresses.sort]
        end

        return resolution
      end
    rescue => e
      statsd_increment('synapse.watcher.dns.resolve_failed', ["service_name:#{@name}"])
      log.warn "synapse: dns resolve error while resolving host names: #{e.inspect}"
      []
    end

    def resolver
      args = [{:nameserver => @nameserver}] if @nameserver
      Resolv::DNS.open(*args)
    end

    def configure_backends(servers, config_for_generator={})
      new_backends = servers.flat_map do |(server, addresses)|
        addresses.map do |address|
          {
            'host' => address,
            'port' => server['port'],
            'name' => server['name'],
            'labels' => server['labels'],
          }
        end
      end

      set_backends(new_backends, config_for_generator)
    end
  end
end
