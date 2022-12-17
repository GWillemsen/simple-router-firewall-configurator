#!/bin/sh
export HOSTS_FILE=./hosts
export DHCP_HOSTS_FILE=./hosts.dhcp
export DOMAIN=internal
export DEBUG=0

append_if_not_present() {
    APP=0
    if [ -e "$2" ]; then
        set +e
        grep -e "$1" "$2"
        APP=$0
    else
        APP=1
    fi
    if [ $APP == "1" ]; then
        echo "$1" >> $2
        if [ $DEBUG == 1 ]; then
            echo "Appending $1 to $2"
        fi
    else
        if [ $DEBUG == 1 ]; then
            echo "$1 already in $2"
        fi
    fi

    return 0;
}