#! /usr/bin/env ruby
require 'optparse'
require 'uri'
# need open-uri so we can open and read from URIs the same as from regular files
require 'open-uri'
require 'pp'
require 'ostruct'
require 'tempfile'

# Zabbix key prefix for each item, backends and frontends only
zabbix_frontend_and_backend_key_prefix = "haproxy."

# items to send
zabbix_frontend_and_backend_items =
[
  'req_rate',
  'hrsp_1xx',
  'hrsp_2xx',
  'hrsp_3xx',
  'hrsp_4xx',
  'hrsp_5xx',
  'rate',
  'wretr',
  'eresp',
  'econ',
  'ereq',
  'bin',
  'bout',
  'stot',
  'smax',
  'scur'
] # end items

# Zabbix key prefix for servers only
zabbix_server_key_prefix = "haproxy."

# items to send
zabbix_server_items =
[
  'status',
  'scur',
  'hrsp_1xx',
  'hrsp_2xx',
  'hrsp_3xx',
  'hrsp_4xx',
  'hrsp_5xx',
  'req_rate',
  'bin',
  'bout',
  'stot',
  'status'
] # end items

#
# CSV format
#
# The statistics may be consulted either from file or HTTP
# socket functionality was scraped as haproxy couldn't bind different sockets
# for each thread/process. dumb.
# Fields listed below.

columns = {
  :pxname => 'proxy name',
  :svname => 'service name (FRONTEND for frontend, BACKEND for backend any name for server/listener)',
  :qcur => 'current queued requests. For the backend this reports the number queued without a server assigned.',
  :qmax => 'max value of qcur',
  :scur => 'current sessions',
  :smax => 'max sessions',
  :slim => 'configured session limit',
  :stot => 'cumulative number of connections',
  :bin =>  'bytes in',
  :bout => 'bytes out',
  :dreq => 'requests denied because of security concerns.
  - For tcp this is because of a matched tcp-request content rule.
  - For http this is because of a matched http-request or tarpit rule.',
  :dresp => 'responses denied because of security concerns.
  - For http this is because of a matched http-request rule, or
  "option checkcache".',
  :ereq => 'request errors. Some of the possible causes are:
  - early termination from the client, before the request has been sent.
  - read error from the client
  - client timeout
  - client closed connection
  - various bad requests from the client.
  - request was tarpitted.',
  :econ => 'number of requests that encountered an error trying to
  connect to a backend server. The backend stat is the sum of the stat
  for all servers of that backend, plus any connection errors not
  associated with a particular server (such as the backend having no
  active servers).',
  :eresp => 'response errors. srv_abrt will be counted here also.
  Some other errors are:
  - write error on the client socket (won\'t be counted for the server stat)
  - failure applying filters to the response.',
  :wretr => 'number of times a connection to a server was retried.',
  :wredis => 'number of times a request was redispatched to another
  server. The server value counts the number of times that server was
  switched away from.',
  :status => ' status (UP/DOWN/NOLB/MAINT/MAINT(via)...)',
  :weight => 'server weight (server), total weight (backend)',
  :act => 'server is active (server), number of active servers (backend)',
  :bck => 'server is backup (server), number of backup servers (backend)',
  :chkfail => 'number of failed checks. (Only counts checks failed when
    the server is up.)',
  :chkdown => 'number of UP->DOWN transitions. The backend counter counts
    transitions to the whole backend being down, rather than the sum of the
    counters for each server.',
  :lastchg => 'number of seconds since the last UP<->DOWN transition',
  :downtime => 'total downtime (in seconds). The value for the backend
    is the downtime for the whole backend, not the sum of the server downtime.',
  :qlimit => 'configured maxqueue for the server, or nothing in the
    value is 0 (default, meaning no limit)',
  :pid => 'process id (0 for first instance, 1 for second, ...)',
  :iid => 'unique proxy id',
  :sid => 'server id (unique inside a proxy)',
  :throttle => 'current throttle percentage for the server, when
    slowstart is active, or no value if not in slowstart.',
  :lbtot => 'total number of times a server was selected, either for new
    sessions, or when re-dispatching. The server counter is the number
    of times that server was selected.',
  :tracked => 'id of proxy/server if tracking is enabled.',
  :type => '(0=frontend, 1=backend, 2=server, 3=socket/listener)',
  :rate => 'number of sessions per second over last elapsed second',
  :rate_lim => 'configured limit on new sessions per second',
  :rate_max => 'max number of new sessions per second',
  :check_status => 'status of last health check, one of:
    UNK     -> unknown
    INI     -> initializing
    SOCKERR -> socket error
    L4OK    -> check passed on layer 4, no upper layers testing enabled
    L4TMOUT -> layer 1-4 timeout
    L4CON   -> layer 1-4 connection problem, for example
    "Connection refused" (tcp rst) or "No route to host" (icmp)
    L6OK    -> check passed on layer 6
    L6TOUT  -> layer 6 (SSL) timeout
    L6RSP   -> layer 6 invalid response - protocol error
    L7OK    -> check passed on layer 7
    L7OKC   -> check conditionally passed on layer 7, for example 404 with
    disable-on-404
    L7TOUT  -> layer 7 (HTTP/SMTP) timeout
    L7RSP   -> layer 7 invalid response - protocol error
    L7STS   -> layer 7 response error, for example HTTP 5xx',
  :check_code => 'layer5-7 code, if available',
  :check_duration => 'time in ms took to finish last health check',
  :hrsp_1xx => 'http responses with 1xx code',
  :hrsp_2xx => 'http responses with 2xx code',
  :hrsp_3xx => 'http responses with 3xx code',
  :hrsp_4xx => 'http responses with 4xx code',
  :hrsp_5xx => 'http responses with 5xx code',
  :hrsp_other => 'http responses with other codes (protocol error)',
  :hanafail => 'failed health checks details',
  :req_rate => 'HTTP requests per second over last elapsed second',
  :req_rate_max => 'max number of HTTP requests per second observed',
  :req_tot => 'total number of HTTP requests received',
  :cli_abrt => 'number of data transfers aborted by the client',
  :srv_abrt => 'number of data transfers aborted by the server
    (inc. in eresp)',
  :comp_in => 'number of HTTP response bytes fed to the compressor',
  :comp_out => 'number of HTTP response bytes emitted by the compressor',
  :comp_byp => 'number of bytes that bypassed the HTTP compressor
    (CPU/BW limit)',
  :comp_rsp => 'number of HTTP responses that were compressed',
  :lastsess => 'number of seconds since last session assigned to server/backend',
  :last_chk => 'last health check contents or textual error',
  :last_agt => 'last agent check contents or textual error',
  :qtime => 'the average queue time in ms over the 1024 last requests',
  :ctime => 'the average connect time in ms over the 1024 last requests',
  :rtime => 'the average response time in ms over the 1024 last requests (0 for TCP)',
  :ttime => 'the average total session time in ms over the 1024 last requests'
}

def is_haproxy_running?
  num_processes = `/usr/bin/pgrep haproxy | wc -l`
  if Integer(num_processes) > 0
    return true
  end
  false
end

# create an array of arrays with 3 columns like this:
# [
#  [zabbix host name, zabbix key, value],
#  ...
# ]
def prepare_data(input_data, columns, header, prefix)
  # prepare an array of data for backends and frontends
  result = Array.new
  input_data.each do |item|
    zabbix_host = item[0]
    columns.each do |haproxy_item|
      value = item[1][header.find_index(haproxy_item)]
      value = 0 if value =="" # so we don't have blank field
      result << [zabbix_host, prefix + haproxy_item, value]
    end
  end
  # return the array we created
  result
end

def prepare_zabbix_data(data)
  result=""
  data.each do |line|
    result += line.join(" ") + "\n"
  end
  result
end

# verifies if str is a number, so we can later add safely
def is_num?(str)
  begin
    !!Integer(str)
  rescue ArgumentError, TypeError
    false
  end
end

# simple array printing function
def print_list(data)
  data.uniq.each do |name|
    puts "\t #{name}"
  end
  puts ""
end

# parse command line options
o = OpenStruct.new
optparser = OptionParser.new do |opts|
  # parse command line
  opts.banner = "Usage: haproxy-stats.rb [arguments]"
  opts.separator "This programms gets data from haproxy and sends it into zabbix."
  opts.separator ""
  opts.separator "Example:"
  opts.separator "    haproxy-stats.rb -w http://localhost:12001,http://localhost:12002 -u admin_username -p admin_password"
  opts.separator ""
  opts.separator "Options are:"

  o.verbose = false
  opts.on( '-v', '--verbose', 'Be verbose') do
    o.verbose = true
  end

  o.debug = false
  opts.on( '-d', '--debug', 'Show debug info') do
    o.debug = true
  end

  o.check_for_running_haproxy = false
  opts.on( '-r', '--check-haproxy', 'Exit if haproxy is not found running. Useful for running in failover clusters.') do
    o.check_for_running_haproxy = true
  end

  o.list_backends = false
  opts.on('--list-backends', 'List all backends and exit') do
    o.list_backends = true
  end

  o.list_frontends = false
  opts.on('--list-frontends', 'List all frontends and exit') do
    o.list_frontends = true
  end

  o.list_servers = false
  opts.on( '--list-servers', 'List all servers and exit') do
    o.list_servers = true
  end

  o.list_columns = false
  opts.on( '-c', '--list-columns', 'List CSV column names and exit') do
    o.list_columns = true
  end

  o.explain = false
  opts.on( '-x', '--explain COLUMN_NAME', 'Show info about this column') do |column|
    o.explain = column
  end

  o.zabbix_server = nil
  opts.on( '-z', '--zabbbix-server SERVER', 'Hostname or IP for Zabbix server') do |server|
    o.zabbix_server = server
  end

  o.zabbix_port = nil
  opts.on( '-t', '--zabbbix-port PORT', 'Trapper port on the Zabbix server') do |port|
    o.zabbix_port = port
  end

  o.zabbix_sender = nil
  opts.on( '-e', '--zabbbix-sender-path PATH', 'Optional, full path to zabbix_sender') do |sender|
    o.zabbix_sender = sender
  end

  opts.separator ""
  opts.separator "Where to get stats from. You can mix sources but it's not recommended."
  o.stats_url = nil
  opts.on( '-w', '--url URL|FILE', Array, 'Comma separated URLs or files, URLs should be without "/haproxy?stats;csv" part') do |url|
    o.stats_url = url
  end

  o.auth_user = nil
  opts.on( '-u', '--user USER', String, 'Username for HTTP authentication') do |user|
    o.auth_user = user
  end

  o.auth_passwd = nil
  opts.on( '-p', '--password USER', String, 'Password for HTTP authentication') do |passwd|
    o.auth_passwd = passwd
  end

  opts.separator ""
  #opts.separator "Output options:"

  opts.separator "Help:"
  opts.on_tail( '-h', '--help', 'Shows usage') do
    puts opts
    exit
  end
end

# load command line options
puts optparser if ARGV.empty?
begin
  optparser.parse!
rescue OptionParser::MissingArgument, OptionParser::InvalidOption
  puts "\nError: #{$!.to_s}\n\n"
  puts optparser
  exit
end

# verify if we need to check if haproxy is running
if o.check_for_running_haproxy and not is_haproxy_running?
  puts "Executed with --check-haproxy and no haproxy process found running. Bailing out." if o.verbose
  exit
end

# Show columns
if o.list_columns then
  puts "Listing columns"
  columns.each_pair do |column,text|
    puts "#{column}: #{text}"
  end
  exit
end

# Explain a column name
if o.explain then
  c = o.explain
  puts "'#{c}': #{columns[c.to_sym]}"
  exit
end

# Read stats from URL or file
if o.stats_url then
  puts "Starting..." if o.verbose

  raw_stats = Hash.new
  o.stats_url.each do |url|

    # check if this is an URL
    if url =~ URI::regexp then
      # ask for CSV stats if HTTP
      o.is_url = true
      work_url = url + '/haproxy?stats;csv'
    else
      # assume file
      o.is_url = false
      work_url = url
    end

    printf "Getting stats from: #{work_url}" if o.verbose
    # read the stat into an array
    begin
      if o.is_url and (o.auth_user and o.auth_passwd) then
        # use authentication
        raw_stats[url] = open(work_url, :http_basic_authentication => [o.auth_user, o.auth_passwd]) { |u| u.read() }
      else
        raw_stats[url] = open(work_url) { |u| u.read() }
      end
    rescue Exception => e
      printf "\nERROR: Could not read from #{work_url}: #{e.to_s}\n"
      exit
    end

    puts " ... done." if o.verbose

  end

  printf "Converting data into something usable" if o.verbose

  # convert raw stats to arrays and get rid of first line, which is a header
  parsed_stats = Hash.new
  header_line = nil
  raw_stats.each_with_index do |stats,index|
    temp = Array.new
    stats[1].chomp.split("\n").each do |line|
      if not header_line and line =~ /^# .*/
        header_line = line
        next
      end
      temp << line.split(",", -1) unless line =~ /^# .*/# -1 so NULL fields aren't skipped, we want same array size
    end
    parsed_stats[index] = temp
  end

  # create a header array, useful for finding column names indices later
  header = header_line.gsub("# ", "").split(',')

  puts " ... done." if o.verbose

  printf "Validating and summing up data" if o.verbose

  # take first read as initial data, just the big table (0 -> key, 1 -> value)
  data = parsed_stats.shift[1]

  # add what's left to the initial data
  parsed_stats.each do |stats|
    stats[1].each_with_index do |line,i|
      line.each_with_index do |value,j|
        initial_value = data[i][j]
        if is_num?(initial_value) and is_num?(value)
          data[i][j] = initial_value.to_i + value.to_i
          puts "Adding for #{data[i][0]} at #{i},#{j}: #{initial_value} + #{value} = #{data[i][j]}" if o.debug
        end
      end
    end
  end # sum is done here

  puts " ... done." if o.verbose

  puts "Looking for frontends, backends and servers (will ignore admin_page).\n\n" if o.verbose

  backends = Hash.new
  backends_list = Array.new

  frontends = Hash.new
  frontends_list = Array.new

  servers = Hash.new
  servers_list = Array.new

  pxname_index = header.find_index('pxname')
  svname_index = header.find_index('svname')

  data.each do |line|
    if line[svname_index] =~ /BACKEND/
      puts "- backend: #{line[0]}" if o.verbose
      backends_list << line[pxname_index]
      backends[line[pxname_index]] = line unless line[pxname_index] =~ /admin_page/
    elsif line[svname_index] =~ /FRONTEND/
      puts "- frontend: #{line[0]}" if o.verbose
      frontends_list << line[pxname_index]
      frontends[line[pxname_index]] = line unless line[pxname_index] =~ /admin_page/
    else
      # server
      puts "- server: #{line[1]}" if o.verbose
      servers_list << line[svname_index]
      servers[line[svname_index]] = line
    end
  end

  if o.list_backends
    puts "Listing all backends:\n\n"
    print_list(backends_list)
    exit
  elsif o.list_frontends
    puts "Listing all frontends:\n\n"
    print_list(frontends_list)
    exit
  elsif o.list_servers
    puts "Listing all servers:\n\n"
    print_list(servers_list)
    exit
  end

  if o.verbose
    puts ""
    puts "Total backends: #{backends.count}"
    puts "Total frontends: #{frontends.count}"
    puts "Total servers: #{servers.count}"
  end


  # check for required parameters
  if not o.zabbix_server or not o.zabbix_port
    puts "#{o.zabbix_server}, #{o.zabbix_port}"
    puts "Zabbix server and port are required paraments."
    exit
  end


  # prepare data for backends, frontends and servers
  bulk_data = Array.new
  bulk_data.concat(prepare_data(backends,
                                zabbix_frontend_and_backend_items,
                                header,
                                zabbix_frontend_and_backend_key_prefix))
  bulk_data.concat(prepare_data(frontends,
                                zabbix_frontend_and_backend_items,
                                header,
                                zabbix_frontend_and_backend_key_prefix))
  bulk_data.concat(prepare_data(servers,
                                zabbix_server_items,
                                header,
                                zabbix_server_key_prefix))

  # send data to Zabbix.
  # we'll use the bulk send feature by passing '-i' together with a file to zabbix_sender
  begin
    # first, create a temp file
    temp_file = Tempfile.new("haproxy-stats")
    # prepare data
    zabbix_data = prepare_zabbix_data(bulk_data)
    # write data to file
    temp_file.write(zabbix_data)
    # close file so buffers get flushed
    temp_file.close

    # try to exec zabbix_sender
    zabbix_sender_cmd_line = "-z #{o.zabbix_server} -p #{o.zabbix_port} -i #{temp_file.path}"
    if o.verbose
      zabbix_sender_cmd_line += " -vv"
    else
      zabbix_sender_cmd_line += " > /dev/null"
    end
    puts "Executing: zabbix_sender #{zabbix_sender_cmd_line}" if o.verbose
    system("cat #{temp_file.path}") if o.debug

    # send data to zabbix
    system("zabbix_sender #{zabbix_sender_cmd_line}")
  rescue Exception => e
    puts "ERROR: " + e.to_s
  ensure
    # finally erase the temporary file
    temp_file.unlink
  end
end
