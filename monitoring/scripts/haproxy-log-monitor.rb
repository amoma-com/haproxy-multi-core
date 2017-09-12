#!/usr/bin/ruby
require 'tempfile'
require 'pp'

# uncomment this to make the script talk to you
DEBUG = true

# Set these before running
ZBX_SERVER = '10.10.0.10'
ZBX_PORT = 10051
LB_HOSTS = ['load-balancer-01','load-balancer-02']

log_path = '/var/log/haproxy.log'

# to test uncomment down, run, check Zabbix, uncomment up, remove offset file, run again
#log_path = '/tmp/haproxytest-down.log'
#log_path = '/tmp/haproxytest-up.log'

offset_path = '/tmp/haproxy.log.offset'
simulate_only = false
zabbix_key = "haproxy_status_string"

regexp = Regexp.new('^.*: Server (\S+)\/(\S+) is (DOWN|UP), reason: (.*), code: (\d+), info: "(.*)".*$')

def _debug(str)
  puts(str) if DEBUG
end

def die(str)
  _debug(str)
  exit
end

class LBStateMachine
  def initialize
    @state = Hash.new
    @server_state = Hash.new
    @state_history = Array.new
  end

  def map(server, host, state, reason, code, info)
    # create a detail to report, UP if state changed to UP or error code, such as 500 or 403
    detail = state == "UP" ? "UP" : code

    update_host(host, server, detail)

    # add a per LB server state
    if not @server_state.has_key?(server) then
    else
    end

    # add to history
    history_line = [Time.now, server, host, state, reason, code, info]
    @state_history << history_line
  end

  def get(host)
    @state[host]
  end

  def get_state
    @state
  end

  def get_server_stats
    @server_state
  end

  def get_host_cluster_pair(host, server)
    @state[host][server]
  end

  def get_history
    @state_history
  end

  def get_num_hosts
    @state.keys.count
  end

  def get_num_servers
    clusters = Array.new
    @state.each do |host|
      clusters << host[1].keys
    end
    return clusters.flatten.uniq.count
  end

  private
  def update_host(host, server, detail)
    if not @state.has_key?(host) then
      @state[host] = Hash.new
    end
    @state[host][server] = detail

    if not @server_state.has_key?(server) then
      @server_state[server] = 0
    end

    op = detail == "UP" ? -1 : 1
    @server_state[server] += op
    @server_state[server] = 0 if @server_state[server] < 0

  end

end

# create the state machine
sm = LBStateMachine.new

# record the start time
start = Time.now

# make use of logtail2 to get only new log entries
logtail2_test_mode = simulate_only ? "-t" : ""

LB_HOSTS.each do |lb_host|
  _debug("checking LB host: #{lb_host}")

  log_contents = `ssh #{lb_host} /usr/sbin/logtail2 -f#{log_path} -o#{offset_path} #{logtail2_test_mode} 2>/dev/null`
  log_entries = log_contents.split(/\r?\n/)

  # do not collect money, do not pass go if log is empty.
  next unless log_entries.count > 0

  _debug("found #{log_entries.count} new log entries")

  log_entries.each do |line|
    if data = regexp.match(line) then
      server, host, state, reason, code, info = $1, $2, $3, $4, $5, $6
      _debug("state changed to #{state} for host in #{server}")
      sm.map(server, host, state, reason, code, info)
    else
      _debug("no state change detected, skipping line")
    end
  end

  # done parsin, record the time
  inter = Time.now

  total_hosts = sm.get_num_hosts
  total_servers = sm.get_num_servers

  _debug("a total of #{total_hosts} hosts in #{total_servers} clusters changed state")
  # don't send anything if no hosts changed state
  exit unless total_hosts

  _debug("preparing to send data into Zabbix")

  # holds all zabbix data, hosts that changed to UP are pushed first
  zabbix_data = Array.new
  # this is used to hold hosts
  zabbix_down_data = Array.new
  # this is used to hold servers
  zabbix_sum_data = Array.new

  sm.get_state.each do |host_entry|
    host = host_entry[0]
    server_state = host_entry[1]
    compound_down_state = Array.new

    _debug("checking #{host}")
    server_state.each do |server, state|
      if state == "UP" then
        _debug("adding #{server} with state #{state}")
        zabbix_data << "#{host} #{zabbix_key} '#{state}'"
      else
        compound_down_state << "#{server}: #{state}"
      end
    end
    if compound_down_state.count > 0 then
      zabbix_down_data << "#{host} #{zabbix_key} '#{compound_down_state.join(', ')}'"
    end
  end

  sm.get_server_stats.each do |server, host_count|
    if host_count > 0
      server_status = "#{host_count} hosts reported as DOWN"
    else
      server_status = 'UP'
    end
    zabbix_sum_data << "#{server} #{zabbix_key} '#{server_status}'"
  end

  # prepare data
  zabbix_data.concat(zabbix_down_data)
  zabbix_batch_file = Tempfile.new('haproxy-errors')
  _debug("writing to temp file #{zabbix_batch_file.path}")
  zabbix_batch_file.write(zabbix_data.join("\n"))
  # deleting the temp is done by the GC later
  zabbix_batch_file.close

  # send to zabbix in batch mode
  _debug("sending to Zabbix")
  if simulate_only then
    _debug("Not sending: here are the contents of the batch file: #{zabbix_batch_file.path}")
    _debug("--- 8< ---")
    system("cat #{zabbix_batch_file.path}")
    _debug("\n--- 8< ---")
  else
    system("/usr/bin/zabbix_sender -z #{ZBX_SERVER} -p #{ZBX_PORT} -i #{zabbix_batch_file.path} 2>&1 /dev/null")
  end
end

_debug("done")
