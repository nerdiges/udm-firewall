#!/bin/bash

######################################################################################
#
# Description:
# ------------
#	If different corporate and guest networks are defined Unifi Network, these 
#   networks ar not separated in default configuaration, as a default allow
#   principle is implemented on UDM Pro. Thus, coporate LAN to corporate LAN 
#	and guest LAN to guest LAN traffic is allowed per default. In addition it is 
#	not possible to restrict inter corporate and guest IPv6 traffic via GUI. 
#   This script adds some rules to sepearte all defined LAN and Guest networks 
#	(see https://nerdig.es/udm-pro-netzwerktrennung-1/). 
#	As firewall rules may be reseted whenever ruleset is changed in GUI, this
#   file should be executed regularly (e.g. via systemd timer or cron) to ensure 
#	that firewall is permanently activated.
#
######################################################################################

######################################################################################
#
# Configuration
#

# Add rules to separate LAN interfaces
separate_lan=true

# Add rules to separate Guest interfaces
separate_guest=true

# interfaces listed in exclude will not be separted and can still access
# the other VLANs. Multiple interfaces are to be separated by spaces.
exclude="br20"

# Add rule to allow established and related network traffic coming in to LAN interface
allow_related_lan=true

# Add rule to allow established and related network traffic coming in to guest interface
allow_related_guest=true

# Remove predefined NAT rules 
disable_nat=true

# List of commands that should be executed before firewall rules are adopted (e.g. setup 
# wireguard interfaces, before adopting ruleset to ensure wireguard interfaces are 
# considerd when  separating VLANs).
# It is recommended to use absolute paths for the commands.
commands_before=(
    "[ -x /data/custom/wireguard/udm-wireguard.sh ] && /data/custom/wireguard/udm-wireguard.sh"
    ""
)

# List of commands that should be executed after firewall rules are adopted.
# It is recommended to use absolute paths for the commands.
commands_after=(
    "[ -x /data/custom/ipv6/udm-ipv6.sh ] && /data/custom/ipv6/udm-ipv6.sh"
    ""
)

#
# No further changes should be necessary beyond this line.
#
######################################################################################

# set scriptname
me=$(basename $0)

# include local configuration if available
[ -e "$(dirname $0)/${me%.*}.conf" ] && source "$(dirname $0)/${me%.*}.conf"

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Exectue Scripts defined in $commands_before
#
for cmd in "${commands_before[@]}"; do
    eval "$cmd"
done

# Buffer IPv4 ruleset
ipv4rules=$(/usr/sbin/iptables --list-rules)
function in_ip4rules () { [[ $ipv4rules =~ ${1// /\\ } ]] || return 1; }

# Buffer IPv6 ruleset
ipv6rules=$(/usr/sbin/ip6tables --list-rules)
function in_ip6rules () { [[ $ipv6rules =~ ${1// /\\ } ]] || return 1; }

# Get list of relevant LAN interfaces and total number of interfaces
lan_if=$(echo -e "$ipv4rules" | /usr/bin/awk '/^-A UBIOS_FORWARD_IN_USER.*-j UBIOS_LAN_IN_USER/ { print $4 }')
lan_if_count=$(echo $lan_if | /usr/bin/wc -w)

# Get list of relevant guest interfaces and total number of interfaces
guest_if=$(echo -e "$ipv4rules" | /usr/bin/awk '/^-A UBIOS_FORWARD_IN_USER.*-j UBIOS_GUEST_IN_USER/ { print $4 }')
guest_if_count=$(echo $guest_if | /usr/bin/wc -w)

# Get list of WAN interfacess 
wan_if=$(echo -e "$ipv4rules" | /usr/bin/awk '/^-A UBIOS_FORWARD_IN_USER.*-j UBIOS_WAN_IN_USER/ { print $4 }')


#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# add allow related/established to UBIOS_LAN_IN_USER if requested
#
if [ $allow_related_lan == "true" ]; then
    rule="-A UBIOS_LAN_IN_USER -m conntrack --ctstate RELATED,ESTABLISHED.*-j RETURN"
    in_ip4rules "$rule" || /usr/sbin/iptables -I UBIOS_LAN_IN_USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    in_ip6rules "$rule" || /usr/sbin/ip6tables -I UBIOS_LAN_IN_USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
fi


#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# LAN separation
#
if [ $separate_lan == "true" ]; then
    # prepare ip(6)tables chains lan_separation
    in_ip4rules "-N lan_separation" || (/usr/sbin/iptables -N lan_separation &> /dev/null  && /usr/bin/logger "$me: IPv4 chain created (lan_separation)")
    in_ip6rules "-N lan_separation" || (/usr/sbin/ip6tables -N lan_separation &> /dev/null && /usr/bin/logger "$me: IPv6 chain created (lan_separation)")

    # allow Outbound internet traffic to WAN
    for o in $wan_if; do
        # Reject Outbound RFC1918 to deny DMZ access
        rule="-A lan_separation -d 192.168.0.0/16 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        rule="-A lan_separation -d 172.16.0.0/12 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        rule="-A lan_separation -d 10.0.0.0/8 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        rule="-A lan_separation -d 169.254.0.0/16 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule

        # Reject Outbound ULA to deny DMZ access
        rule="-A lan_separation -d fc00::/7 -o $o -j REJECT"
        in_ip6rules "$rule" || /usr/sbin/ip6tables $rule

        # Allow all other traffic
        rule="-A lan_separation -o $o -j RETURN"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        in_ip6rules "$rule" || /usr/sbin/ip6tables $rule
    done

    # Add rules to separate LAN-VLANs to chain lan_separation
    for i in $lan_if; do
        case "$exclude " in 
            *"$i "*)
                /usr/bin/logger "$me: Excluding $i from LAN separation as requested in config."
            ;;

            *)
                rule="-A lan_separation -i $i -j REJECT"
                in_ip4rules "$rule" || /usr/sbin/iptables $rule
                in_ip6rules "$rule" || /usr/sbin/ip6tables $rule
            ;;
        esac
    done 

    # add IPv4 rule to include rules in chain lan_separation
    if ! in_ip4rules "-A UBIOS_LAN_IN_USER -j lan_separation" ; then
        rules=$(/usr/sbin/iptables -L UBIOS_LAN_IN_USER --line-numbers | /usr/bin/awk 'END { print $1 }')
        v4_idx=$(/usr/bin/expr $rules - $lan_if_count)
        /usr/sbin/iptables -I UBIOS_LAN_IN_USER $v4_idx -j lan_separation
    fi 

    # add IPv6 rule to include rules in chain lan_separation
    if ! in_ip6rules "-A UBIOS_LAN_IN_USER -j lan_separation" ; then
        v6_idx=$(/usr/sbin/ip6tables -L UBIOS_LAN_IN_USER --line-numbers | /usr/bin/awk '/match-set UBIOS_ALL_NETv6_br[0-9]+ src \/\*/{ print $1; exit}')
        /usr/sbin/ip6tables -I UBIOS_LAN_IN_USER $v6_idx -j lan_separation
    fi
else
    /usr/bin/logger "$me: Separation for guest VLANs deactivated. Starting clean up..."
            
    if in_ip4rules "-N lan_separation"; then
        /usr/sbin/iptables -F lan_separation && /usr/bin/logger "$me: Existing IPv4 chain lan_separation flushed."
        /usr/sbin/iptables -X lan_separation && /usr/bin/logger "$me: Existing IPv4 chain lan_separation deleted."
    fi

    if in_ip6rules "-N lan_separation"; then
        /usr/sbin/ip6tables -F lan_separation && /usr/bin/logger "$me: Existing IPv6 chain lan_separation flushed."
        /usr/sbin/ip6tables -X lan_separation && /usr/bin/logger "$me: Existing IPv6 chain lan_separation deleted."
    fi
fi


#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# add allow related/established to UBIOS_LAN_IN_USER if requested
#
if [ $allow_related_guest == "true" ]; then
    rule="-A UBIOS_GUEST_IN_USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    in_ip4rules "$rule" || /usr/sbin/iptables -I UBIOS_GUEST_IN_USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    in_ip6rules "$rule" || /usr/sbin/ip6tables -I UBIOS_GUEST_IN_USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
fi


#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Guest separation
#
if [ $separate_guest == "true" ]; then

    # prepare ip(6)tables chains guest_separation
    in_ip4rules "-N guest_separation" || (/usr/sbin/iptables -N guest_separation &> /dev/null && /usr/bin/logger "$me: IPv4 chain created (guest_separation)")
    in_ip6rules "-N guest_separation" || (/usr/sbin/ip6tables -N guest_separation &> /dev/null && /usr/bin/logger "$me: IPv6 chain created (guest_separation)")

    # allow Outbound internet traffic to WAN
    for o in $wan_if; do
        # Reject Outbound RFC1918 to deny DMZ access
        rule="-A guest_separation -d 192.168.0.0/16 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        rule="-A guest_separation -d 172.16.0.0/12 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        rule="-A guest_separation -d 10.0.0.0/8 -o $o -j REJECT"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule

        # Reject Outbound ULA to deny DMZ access
        rule="-A guest_separation -d fc00::/7 -o $o -j REJECT"
        in_ip6rules "$rule" || /usr/sbin/ip6tables $rule

        # Allow all other traffic
        rule="-A guest_separation -o $o -j RETURN"
        in_ip4rules "$rule" || /usr/sbin/iptables $rule
        in_ip6rules "$rule" || /usr/sbin/ip6tables $rule
    done

    # Add rules to chain guest_separation
    for i in $guest_if; do
        case "$exclude " in
            *"$i "*)
                /usr/bin/logger "$me: Excluding $i from guest VLAN separation as requested in config."
            ;;

            *)
                rule="-A guest_separation -i $i -j REJECT"
                in_ip4rules "$rule" || /usr/sbin/iptables $rule
                in_ip6rules "$rule" || /usr/sbin/ip6tables $rule
            ;;
        esac
    done

    if ! in_ip6rules "-A UBIOS_GUEST_IN_USER -j guest_separation" ; then
        # add IPv4 rule to include rules in chain guest_separation
        rules=$(/usr/sbin/iptables -L UBIOS_GUEST_IN_USER --line-numbers | /usr/bin/awk 'END { print $1 }')
        v4_idx=$(expr $rules - $guest_if_count)
        /usr/sbin/iptables -I UBIOS_GUEST_IN_USER $v4_idx -j guest_separation
    fi

    # add IPv6 rule to include rules in chain guest_separation
    if ! in_ip6rules "-A UBIOS_GUEST_IN_USER -j guest_separation" ; then
        v6_idx=$(/usr/sbin/ip6tables -L UBIOS_GUEST_IN_USER --line-numbers | /usr/bin/awk '/RETURN.*match-set UBIOS_ALL_NETv6_br[0-9]+ src \/\*/ { print $1; exit }')
        /usr/sbin/ip6tables -I UBIOS_GUEST_IN_USER $v6_idx -j guest_separation
    fi
else
    /usr/bin/logger "$me: Separation for guest VLANs deactivated. Starting clean up..."
            
    if in_ip4rules "-N guest_separation"; then
        /usr/sbin/iptables -F guest_separation && /usr/bin/logger "$me: Existing IPv4 chain guest_separation flushed."
        /usr/sbin/iptables -X guest_separation && /usr/bin/logger "$me: Existing IPv4 chain guest_separation deleted."
    fi

    if in_ip6rules "-N guest_separation"; then
        /usr/sbin/ip6tables -F guest_separation && /usr/bin/logger "$me: Existing IPv6 chain guest_separation flushed."
        /usr/sbin/ip6tables -X guest_separation && /usr/bin/logger "$me: Existing IPv6 chain guest_separation deleted."
    fi
fi

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# disable NAT if requested
#
if [ $disable_nat == "true" ]; then
    # identify MASQUERADE jump target in UBIOS_POSTROUTING_USER_HOOK chain
    # which will be added per default for UBIOS_ADDRv4_ethX (eth8/eth9) to
    # manage NAT throught WAN
    rules=$(/usr/sbin/iptables -t nat -L UBIOS_POSTROUTING_USER_HOOK --line-numbers | \
            /usr/bin/awk '/MASQUERADE .* UBIOS_.*ADDRv4_eth. src/ { print $1 }')

    # for each rule identified we issue a delete operation in reverse
    # order so that UBIOS_POSTROUTINE_USER_HOOK will really only contain
    # NAT rules a user manually defined in the Network UI.
    for rulenum in $(echo -e "${rules}" | /usr/bin/sort -r); do
        /usr/sbin/iptables -t nat -D UBIOS_POSTROUTING_USER_HOOK ${rulenum}
    done
fi

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Exectue Scripts defined in $commands_after
#
for cmd in "${commands_after[@]}"; do
    eval "$cmd"
done