#!/bin/bash
DHCP_LEASE_TIME="12h"
IPTABLES=iptables
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
    PORTS_VAR="${PREFIX}__$1__ports"
    PUBLIC_VAR="${PREFIX}__$1__public"
    ONLY_DNS_VAR="${PREFIX}__$1__only_dns"
    NAME=${!NAME_VAR}
    ADDRESS=${!ADDRESS_VAR}
    MAC=${!MAC_VAR}
    PORTS=${!PORTS_VAR%\]} 
    PORTS=(${PORTS#\[})
    PUBLIC=${!PUBLIC_VAR}
    ONLY_DNS=${!ONLY_DNS_VAR}
}

add_to_hosts() {
    STR="$ADDRESS $NAME $NAME.$DOMAIN"
    append_if_not_present "$STR" "$HOSTS_FILE"

    if [ $DEBUG == "1" ]; then
        echo "$STR"
    fi

    if [ $PUBLIC == "1" ]; then
        STR="$PUBLIC_IP $NAME.$DOMAIN"
        append_if_not_present "$STR" "$HOSTS_FILE"
        if [ $DEBUG == "1" ]; then
            echo "$STR"
        fi
    fi
}

add_dhcp_host() {
    STR="$MAC,$NAME,$ADDRESS,$DHCP_LEASE_TIME"
    append_if_not_present "$STR" "$DHCP_HOSTS_FILE"
    if [ $DEBUG == "1" ]; then
        echo "$STR"
    fi
}

add_iprule() {
    ARG="$@"
    TCP_ARG="${ARG//-p PROTO/-p tcp}"
    UDP_ARG="${ARG//-p PROTO/-p udp}"
    if [ "$TCP_ARG" == "$UDP_ARG" ]; then
        $IPTABLES $ARG
    else
        $IPTABLES $TCP_ARG
        $IPTABLES $UDP_ARG
    fi
}

generate_iptable_portforward_rules() {
    for PORT in "${PORTS[@]}"
    do
        # Allow incoming connections on the port
        add_iprule -A INPUT -p PROTO --dport $PORT -j ACCEPT

        # Allow responses on the port. for the public network it needs to be a established connection.
        # Locally also new connection requests are allowed (for when someone uses the internal IP instead of
        # public)
        add_iprule -A OUTPUT -o $PUB_IF -p PROTO --dport $PORT -m state --state ESTABLISHED -j ACCEPT
        add_iprule -A OUTPUT -o $PRI_IF -p PROTO --dport $PORT -m state --state NEW,ESTABLISHED -j ACCEPT
        
        # Forward the packets internally when the input has accepted them
        # This applies both for packets from the outside as internal.
        add_iprule -A FORWARD -p PROTO --dport $PORT -d $ADDRESS -j ACCEPT

        # Reroute packates from the outside world to the respective ip & port if they are going to that port on routers' port
        add_iprule -t nat -A PREROUTING -i $PUB_IF -p PROTO --dport $PORT -j DNAT --to-destination $ADDRESS:$PORT
        
        # Hairpin NAT part 1.
        # If the destination is ourselfs but using the public IP then do an immediate destination rewrite.
        add_iprule -t nat -A PREROUTING -i $PRI_IF -p PROTO -d $PUBLIC_IP --dport $PORT -j DNAT --to-destination $ADDRESS:$PORT
        
        # Hairpin NAT part 2.
        # When the packet has been rerouted to correct local IP then if the source IP was also a local IP then masquarade the 
        # source IP otherwise the original sender gets confused because the src ip would be different than the one send.
        add_iprule -t nat -A POSTROUTING -s $LOCAL_NETWORK -o $PRI_IF -p PROTO --dport $PORT -j MASQUERADE
    done
}

set_default_iptables_rules() {
    configure_self_instatiated_connections() {
        # Allow new outgoing connections
        add_iprule -A OUTPUT -o $PUB_IF -p PROTO -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT

        # Allow incoming connections that we initiated.
        add_iprule -A INPUT -i $PUB_IF -p PROTO -m state --state ESTABLISHED,RELATED -j ACCEPT
    
        # If the packet is from the local network allow anything. We assume that our local network is kind of safe
        # and because we don't know yet if this is a packet that we have to route (NAT) to the outside or not.
        $IPTABLES -A INPUT -i $PRI_IF -j ACCEPT
    }
    
    configure_icmp_ping_pong_request() {
        # Allow outgoing echo requests and incoming echo replies.
        # This prevents others from pinging us.
        $IPTABLES -A OUTPUT -o $PUB_IF -p icmp --icmp-type echo-request -j ACCEPT
        $IPTABLES -A INPUT -i $PUB_IF -p icmp --icmp-type echo-reply -j ACCEPT
        
        # Allow everyone on the local interface to ping us, unlike on the WAN interface.
        # We kinda trust our local network and while not strictly needed it does help with 
        # debugging issues quite a lot.
        $IPTABLES -A OUTPUT -o $PRI_IF -p icmp -j ACCEPT
        $IPTABLES -A INPUT -i $PRI_IF -p icmp -j ACCEPT
    }

    configure_dhcp_protocol() {
        # Accept DHCP requests and allow send response on the pri_if
        $IPTABLES -A INPUT -i $PRI_IF -p udp --dport 67 -j ACCEPT
        $IPTABLES -A OUTPUT -o $PRI_IF -p udp --dport 68 -j ACCEPT
    }

    configure_dns_protocol() {
        # Accept DNS requests on priv_if
        add_iprule -A INPUT -i $PRI_IF -p PROTO --dport 53 -j ACCEPT

        # Allow DNS responses on priv_if
        add_iprule -A OUTPUT -o $PRI_IF -p PROTO --sport 53 -j ACCEPT

        # Accept DNS requests on public if
        add_iprule -A INPUT -i $PUB_IF -p PROTO --dport 53 -j ACCEPT

        # Allow DNS responses on public if
        add_iprule -A OUTPUT -o $PUB_IF -p PROTO --sport 53 -j ACCEPT
    }

    configure_nat() {
        # If the packet is from the local network and the destination is the outside world then
        # masquerade the IP (ie do NAT).
        $IPTABLES -t nat -A POSTROUTING -s $LOCAL_NETWORK -o eth0 -j MASQUERADE

        # Internally forward packets from the local network that (might) need to 
        # be routed to the outside world.
        $IPTABLES -A FORWARD -i $PRI_IF -j ACCEPT

        # Because the default policy is drop we need to explicity accept 
        # traffic that was routed through NAT to the local network.
        $IPTABLES -A FORWARD -o $PRI_IF -j ACCEPT
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
        echo N: $NAME
        echo A: $ADDRESS
        echo M: $MAC
        echo P: $PORTS
    fi

    add_to_hosts

    if [[ "$ONLY_DNS" == "0" || "$ONLY_DNS" == "" ]]; then
        add_dhcp_host
        generate_iptable_portforward_rules
    fi
done

set_default_iptables_rules
