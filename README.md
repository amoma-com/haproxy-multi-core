# haproxy-multi-core

Configuration and monitoring for multi core haproxy configuration, using ruby, ansible and zabbix.

The issue with the haproxy multi core setup is summed up in the haproxy documentation:

> Note : Consider not using this feature in multi-process mode (nbproc > 1) unless you know what you do : memory is not shared between the processes, which can result in random behaviours.

This essentially means that each process operates independently, so to monitor the server you will need to contact each process independently, and to disable a server you would need to disable it on each process.

The scripts below solve both of these issues.

## Configuration

The configuration example below shows configuration on a 4 core server.   
We leave the first core empty for the OS, and bind the three processes to cores 2,3 and 4.

This configuration is within the "global" section:

~~~
global
    ...
    # 3 processes
    nbproc 3
    cpu-map 1 2
    cpu-map 2 3
    cpu-map 3 4
~~~   

And then set up the haproxy statistics interface, so that each process is running on a separate port:

~~~
#---------------------------------------------------------------------
# HAPROXY ADMIN WEB INTERFACE
#---------------------------------------------------------------------
# statistics admin level depends on the authenticated user
    userlist stats-auth
    group adminusergroup users admin_username
    user  admin_username  insecure-password admin_password

listen admin_page
   bind :12001 process 1
   bind :12002 process 2
   bind :12003 process 3

   mode http
   stats uri /
   stats realm haproxy_stats
   stats auth admin_username:admin_password
   stats show-legends
   stats show-node
   acl AUTH       http_auth(stats-auth)
   acl AUTH_ADMIN http_auth_group(stats-auth) adminusergroup
   stats admin if AUTH
   timeout server 25s
   timeout client 20s
   timeout connect 25s
~~~

## Maintenance

Maintenance is performed by running a shell script which runs commands over ansible on the haproxy servers - maintenance/haproxy-maintenance.sh

### Prerequisites

* You will need to install:
** parallel
** ansible
* Grant ansible access to the haproxy servers
* Ensure you have updated the list of constants at the top of the file
* Ensure that you have a hosts list called "load-balancers" in your ansible hosts file

The script is run as follows:

~~~
 usage: ./haproxy-management.sh options

 This script will enable/disable a server in a specific backend.

 ./haproxy-management.sh -d web-server-01 -b backend_name

 OPTIONS:
  -h  Show this message
  -d  Disable a backend host
  -e  Enable a backend host
  -b  Backend name (from haproxy.cfg)
~~~

## Monitoring

### Monitoring haproxy statistics

The script which does the monitoring is monitoring/scripts/haproxy-stats.rb

It needs Ruby 1.8.7 or later installed.

How it works:
* It runs from cron every minute
* If run with '--check-haproxy' then it verifies for running haproxy process with 'pgrep'. Exits if no processes are found.
* The above behaviour is suited for running on each node in a failover cluster
* Accepts URLs as params and gets data from each URL: Each process's stats are retrieved individually, summarised and then pushed to zabbix.
* Ignores a frontend/backend named 'admin_page'
* Creates a temp file from the data gathered and sends it in bulk with 'zabbix_sender -i', so it's very fast.

#### Sample crontab entry:

~~~~
* * * * * /usr/bin/ruby /path/to/haproxy-stats.rb -w 'http://localhost:12001,http://localhost:12002/,http://localhost:12003/' -u admin_username -p admin_password -z 10.0.0.10 -t 10051 --check-haproxy
~~~~

#### Zabbix Templates

Zabbix has 3 templates associated with hosts and backends:
* Template: HAProxy Frontend - associated with the frontends
* Template: HAProxy Backend - associated with the backends
* Template: HAProxy Server - associated with servers

#### Associating an haproxy frontend with zabbix host

In order to associate the frontend with a host name in zabbix, you will need to decorate the frontend statement in haproxy.cfg as follows:

~~~
frontend fe_ext_test.com # @zabbix_frontend(test.com)
~~~

This frontend would then be associated with the test.com host in Zabbix, which should have the "HAProxy Frontend" zabbix template associated with it.

#### Associating an haproxy backend with zabbix host

For backends:

~~~
backend be_web_servers    # @zabbix_backend(web-server-pool)
~~~

This would be associated with the web-server-pool host in zabbix, which should have the "HAProxy Backend" zabbix template associated with it.

#### Associating an haproxy server with zabbix host

For servers, the script extracts the name after the "server" directive.

~~~
    server web-server-01 10.10.0.11:80 maxconn 8000 check inter 10000
~~~ 

This would be associated with the web-server-01 host in zabbix, which should have the "HAProxy Server" zabbix template associated with it.

### Monitoring haproxy log file for host state changes and errors

The script which does the monitoring is monitoring/scripts/haproxy-log-monitor.rb

How it works:
* It runs from cron every minute on a central server.  The user that it runs as must be able to SSH into the haproxy servers
* uses logtail2 to get new entries from /var/log/haproxy.log
* creates state machine internally and converts states to a Zabbix batch file
* calls zabbix_sender to batch send to Zabbix

Zabbix item is of type string, trigger clears on value 'UP' and fires on anything else

Before you run the script for the first time, you will need to customise the following values:
~~~
# Set these before running
ZBX_SERVER = '10.10.0.10'
ZBX_PORT = 10051
LB_HOSTS = ['load-balancer-01','load-balancer-02']
~~~

#### Sample crontab entry:

~~~~
# Haproxy log monitor
* * * * * /usr/bin/ruby /path/to/haproxy-log-monitor.rb 2>&1 >/dev/null
~~~~


#### Zabbix Template

The template "HAProxy Log Monitor" should be associated with each server configured in haproxy.
For instance, from the haproxy.cfg:

~~~
    server web-server-01 10.10.0.11:80 maxconn 8000 check inter 10000
~~~

This would be associated with the web-server-01 host in zabbix, which should have the "HAProxy Log Monitor" zabbix template associated with it.

