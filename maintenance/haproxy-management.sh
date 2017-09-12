#!/bin/bash

# Change these before running the script
export PATH=/path/to/ansible/bin:$PATH
export PYTHONPATH=/path/to/ansible/lib:
export ANSIBLE_LIBRARY=/path/to/ansible/library
export MANPATH=/path/to/ansible/docs/man:
export ANSIBLE_HOSTS=/path/to/ansible/hosts
# The name of the ansible host list
ANSIBLE_HOST_LIST="load-balancers"
# The number of haproxy processes
PROCESSES=3
STATSPATH=/var/lib/haproxy/stats


usage()
{
cat << EOF
usage: $0 options

This script will enable/disable a server in a specific backend.

$0 -d web-server-01 -b backend_name
$0 -l

OPTIONS:
 -h  Show this message
 -d  Disable a backend host
 -e  Enable a backend host
 -b  Backend name (from haproxy.cfg)

EOF
}

while getopts "hd:e:b:t:l" OPTION
do
	case $OPTION in
	h)
		usage
		exit 1
		;;
	d)
		DISABLE=$OPTARG
		;;
	e)
		ENABLE=$OPTARG
		;;
	b)
		BACKEND=$OPTARG
		;;
	?)
		usage
		exit
		;;
	esac
done

if [[ -z "$DISABLE" ]] && [[ -z "$ENABLE" ]]
then
  echo "One of the -d or -e flags need to be specified together with a hostname"
	usage
	exit 1
fi

if [[ -n "$DISABLE" ]]
then
  HOSTN=${DISABLE}
fi

if [[ -n "$ENABLE" ]]
then
  HOSTN=${ENABLE}
fi

ACTIVELB=`ansible ${ANSIBLE_HOST_LIST} -m shell -a "/sbin/service haproxy status | grep -c stopped" | egrep -B 1 ^0 | head -n 1 | awk '{print $1}'`

echo "=================================="
echo "Active Load Balancer is: $ACTIVELB"
echo "=================================="

if [[ -n "$DISABLE" ]]
then
  for thread in `seq 1 ${PROCESSES}`;
    do
      echo "echo \"### Disabling host $HOSTN on thread #${thread} ###\""
      echo "ansible $ACTIVELB -s -m /usr/sbin/haproxy -a \"host=$HOSTN socket='$STATSPATH$thread' backend=$BACKEND state=disabled\""
    done | parallel -j ${PROCESSES}
fi

if [[ -n "$ENABLE" ]]
then
  for thread in `seq 1 $PROCESSES`;
    do
      echo "echo \"### Enabling host $HOSTN on thread #${thread} ###\""
      echo "ansible $ACTIVELB -s -m /usr/sbin/haproxy -a \"host=$HOSTN socket='$STATSPATH$thread' backend=$BACKEND state=enabled\""
    done | parallel -j ${PROCESSES}
fi
