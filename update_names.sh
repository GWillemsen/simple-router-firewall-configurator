#!/bin/bash
DHCP_LEASE_TIME="12h"
IPTABLES=iptables
LOCAL_IP="192.168.1.0/24"
PUB_IF=eth0
PRI_IF=eth1
set -e

# Include init parser
INI_NAME=${1:-example.ini}

# PA=$(dirname $0)/read_ini.sh
export PA=read_ini.sh

source config.sh
source read_ini.sh
PREFIX=INI

set +e
read_ini $INI_NAME --prefix $PREFIX -b 1
set -e

INI__ALL_SECTIONS=($INI__ALL_SECTIONS)

get_node_config() {
    NAME_VAR="${PREFIX}__$1__name"
    ADDRESS_VAR="${PREFIX}__$1__address"
    MAC_VAR="${PREFIX}__$1__mac"
    INTERNET_VAR="${PREFIX}__$1__internet"
    PORTS_VAR="${PREFIX}__$1__ports"
    NAME=${!NAME_VAR}
    ADDRESS=${!ADDRESS_VAR}
    MAC=${!MAC_VAR}
    INTERNET=${!INTERNET_VAR}
    PORTS=${!PORTS_VAR%\]} 
    PORTS=(${PORTS#\[})
}

add_to_hosts() {
    STR="$ADDRESS $NAME $NAME.$DOMAIN"
    append_if_not_present "$STR" "$HOSTS_FILE"

    if [ $DEBUG == "1" ]; then
        echo "$STR"
    fi
}

add_dhcp_host() {
    STR="$MAC,$NAME,$ADDRESS,$DHCP_LEASE_TIME"
    append_if_not_present "$STR" "$DHCP_HOSTS_FILE"
    if [ $DEBUG == "1" ]; then
        echo "$STR"
    fi
}

generate_iptable_rules() {
    for PORT in "${PORTS[@]}"
    do
        # Allow incoming connections on the port
        $IPTABLES -A INPUT -i ${PUB_IF} -p tcp --dport $PORT -m state --state NEW,ESTABLISHED -j ACCEPT
        # Allow responses on the port
        $IPTABLES -A OUTPUT -o ${PUB_IF} -p tcp --dport $PORT -m state --state ESTABLISHED -j ACCEPT
        
        $IPTABLES -A FORWARD -p tcp --dport $PORT -d $ADDRESS -j ACCEPT
        # If only from external then add -i ${PUB_IF}, if allow access for both public and private through router then just leave it out.
        $IPTABLES -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to $ADDRESS:$PORT
        # Hairpin NAT
        $IPTABLES -t nat -A POSTROUTING -s $LOCAL_IP -o ${PRI_IF} -p tcp --dport $PORT -j MASQUERADE

        #TODO Hashlimit?
    done
}

set_default_iptables_rules() {
    configure_self_instatiated_connections() {
        # Allow new outgoing connections
        $IPTABLES -A OUTPUT -o ${PUB_IF} -p tcp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
        $IPTABLES -A OUTPUT -o ${PUB_IF} -p udp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT

        # Allow incoming connections that we initiated.
        $IPTABLES -A INPUT -i ${PUB_IF} -p tcp -m state --state ESTABLISHED,RELATED -j ACCEPT
        $IPTABLES -A INPUT -i ${PUB_IF} -p udp -m state --state ESTABLISHED,RELATED -j ACCEPT
    
        # $IPTABLES -A INPUT -i ${PUB_IF} -j ACCEPT
        # $IPTABLES -A OUTPUT -o ${PRI_IF} -j ACCEPT
    }
    
    configure_icmp_ping_pong_request() {
        # Allow outgoing echo requests and incoming echo replies.
        # This prevents others from pinging us.
        $IPTABLES -A OUTPUT -o ${PUB_IF} -p icmp --icmp-type echo-request -j ACCEPT
        $IPTABLES -A INPUT -i ${PUB_IF} -p icmp --icmp-type echo-reply -j ACCEPT
        
        # Allow everyone on the local interface to ping us, unlike on the WAN interface.
        $IPTABLES -A OUTPUT -o ${PRI_IF} -p icmp -j ACCEPT
        $IPTABLES -A INPUT -i ${PRI_IF} -p icmp -j ACCEPT
    }

    configure_dhcp_protocol() {
        # Accept DHCP requests and allow send response on the pri_if
        $IPTABLES -A INPUT -i ${PRI_IF} -p udp --dport 67 -j ACCEPT
        $IPTABLES -A OUTPUT -o ${PRI_IF} -p udp --dport 68 -j ACCEPT
    }

    configure_dns_protocol() {
        # Accept DNS requests on priv_if
        $IPTABLES -A INPUT -i ${PRI_IF} -p udp --dport 53 -j ACCEPT
        $IPTABLES -A INPUT -i ${PRI_IF} -p tcp --dport 53 -j ACCEPT

        # Allow DNS responses on priv_if
        $IPTABLES -A OUTPUT -o ${PRI_IF} -p udp --sport 53 -j ACCEPT
        $IPTABLES -A OUTPUT -o ${PRI_IF} -p tcp --sport 53 -j ACCEPT
    }

    configure_nat() {
        $IPTABLES -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        $IPTABLES -A FORWARD -i ${PRI_IF} -j ACCEPT

        # Because the default policy is drop we need to explicity accept 
        # traffic that was routed through NAT to the local network.
        $IPTABLES -A FORWARD -o ${PRI_IF} -j ACCEPT
    }

    configure_self_instatiated_connections
    configure_icmp_ping_pong_request
    configure_dhcp_protocol
    configure_dns_protocol
    configure_nat


    $IPTABLES -P INPUT DROP
    $IPTABLES -P OUTPUT DROP
    $IPTABLES -P FORWARD DROP
}

rm -f $DHCP_HOSTS_FILE
rm -f $HOSTS_FILE

# Drop all current rules
$IPTABLES -F
$IPTABLES -F -t nat

# Cleanup non-default chains
$IPTABLES --delete-chain
$IPTABLES -t nat --delete-chain

for i in "${INI__ALL_SECTIONS[@]}"
do
    get_node_config $i
    if [ $DEBUG == "1" ]; then
        echo N: ${NAME}
        echo A: ${ADDRESS}
        echo M: ${MAC}
        echo I: ${INTERNET}
        echo P: ${PORTS}
    fi

    add_to_hosts
    add_dhcp_host
    generate_iptable_rules
done

set_default_iptables_rules
