#!/bin/bash
set -eu
# This script configures networking for the LXC container host.
# It configures the required interfaces via /etc/network/interfaces,
# sets the hostname,
# installs and configures lxc-net and ndppd if needed,
# and updates the default LXC config accordingly.

# Load required utils
. ./utils/log.sh


if [ -z "${1}" ]; then
	>&2 echo "Error: Need to supply configuration file as first parameter"
	exit 1
fi
LOG "Using network configuration file: ${1}"
. "${1}"


if [ "${ENABLE_NETWORK}" != true ]; then
	exit 0
fi



# setup hostname
LOG "Setting up hostname: ${HOSTNAME}.${DOMAINNAME}..."
hostnamectl set-hostname "${HOSTNAME}.${DOMAINNAME}"
echo "" >> /etc/hosts
echo "# FQDN:  ${HOSTNAME}.${DOMAINNAME}" >> /etc/hosts
echo "127.0.1.1 ${HOSTNAME}.${DOMAINNAME} ${HOSTNAME}" >> /etc/hosts
echo "${IPV4_ADDR} ${HOSTNAME}.${DOMAINNAME} ${HOSTNAME}" >> /etc/hosts
if [ "${IPV6_ENABLE}" = true ] ; then
	echo "${IPV6_HOST_ADDR} ${HOSTNAME}.${DOMAINNAME} ${HOSTNAME}" >> /etc/hosts
fi

# configure basic IPv4 networking
LOG "Setting up /etc/network/interfaces for IPv4..."
cp /etc/network/interfaces /etc/network/interfaces.orig
cat << EOF > /etc/network/interfaces
# For more information, see interfaces(5)
source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug ${WAN_INTERFACE}
iface ${WAN_INTERFACE} inet static
    address ${IPV4_ADDR}
    netmask ${IPV4_NETMASK}
    gateway ${IPV4_GATEWAY}
    ${IPV4_NS1}
    ${IPV4_NS2}
EOF

# setup sysctl's for IPv4
LOG "Setting up sysctl for IPv4..."
cat << EOF > /etc/sysctl.d/10-ipv4.conf
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.default.log_martians=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.log_martians=1
EOF
sysctl -p /etc/sysctl.d/10-ipv4.conf

# setup iptables for IPv4
LOG "Setting up /etc/iptables/rules.v4 for IPv4..."
mkdir -p /etc/iptables/
cat << EOF > /etc/iptables/rules.v4
*filter
# default is drop incomming/forward, allow rest
:INPUT DROP
:FORWARD DROP
:OUTPUT ACCEPT

# allow all traffic on the loopback interface
-A INPUT -i lo -j ACCEPT

# allow loopback addresses only via loopback interface
-A INPUT ! -i lo -s 127.0.0.0/8 -j DROP

# drop invalid packages
-A INPUT -i ${WAN_INTERFACE} -m state --state INVALID -j DROP
-A INPUT -i lxcbr0 -m state --state INVALID -j DROP

# allow already established connections
-A INPUT -i ${WAN_INTERFACE} -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i lxcbr0 -m state --state ESTABLISHED,RELATED -j ACCEPT

# allow ping
-A INPUT -i ${WAN_INTERFACE} -p icmp --icmp-type 8 -s 0/0 -m state --state NEW,ESTABLISHED,RELATED -m limit --limit 10/sec -j ACCEPT
-A INPUT -i lxcbr0 -p icmp --icmp-type 8 -s 10.0.3.0/24 -m state --state NEW,ESTABLISHED,RELATED -m limit --limit 10/sec -j ACCEPT

# allow SSH to host
-A INPUT -i ${WAN_INTERFACE} -p tcp --destination-port 22 -j ACCEPT


# allow apt updates via apt-cacher-ng
-A INPUT -i lxcbr0 -d 10.0.3.1 -p tcp -m tcp --dport 3142 -j ACCEPT

# allow systemd journal log forwarding
-A INPUT -i lxcbr0 -d 10.0.3.1 -p tcp -m tcp --dport 19532 -j ACCEPT

# allow ssh from container
-A INPUT -i lxcbr0 -s 10.0.3.0/24 -p tcp -m tcp --dport 22 -j ACCEPT

# generated by lxc-net:
#-A INPUT -i lxcbr0 -p tcp -m tcp --dport 53 -j ACCEPT
#-A INPUT -i lxcbr0 -p udp -m udp --dport 53 -j ACCEPT
#-A INPUT -i lxcbr0 -p tcp -m tcp --dport 67 -j ACCEPT
#-A INPUT -i lxcbr0 -p udp -m udp --dport 67 -j ACCEPT
#-A FORWARD -o lxcbr0 -j ACCEPT
#-A FORWARD -i lxcbr0 -j ACCEPT
COMMIT


*nat
:PREROUTING ACCEPT
:INPUT ACCEPT
:POSTROUTING ACCEPT
:OUTPUT ACCEPT

# generated by lxc-net:
#-A POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE
COMMIT


*mangle
:PREROUTING ACCEPT
:INPUT ACCEPT
:FORWARD ACCEPT
:OUTPUT ACCEPT
:POSTROUTING ACCEPT

# e.g. forward http and https to web container(10.0.3.19)
#-A PREROUTING -p tcp -i ${WAN_INTERFACE} -m tcp --dport 80 -j DNAT --to-destination 10.0.3.19:80
#-A PREROUTING -p tcp -i ${WAN_INTERFACE} -m tcp --dport 443 -j DNAT --to-destination 10.0.3.19:443

# generated by lxc-net:
#-A POSTROUTING -o lxcbr0 -p udp -m udp --dport 68 -j CHECKSUM --checksum-fill
COMMIT


EOF
iptables-restore < /etc/iptables/rules.v4




# (optionally) configure IPv6 networking
if [ "${IPV6_ENABLE}" = true ] ; then
	# append to /etc/network/interfaces

	LOG "Setting up /etc/network/interfaces for IPv6..."
	cat << EOF >> /etc/network/interfaces

iface ${WAN_INTERFACE} inet6 static
    address ${IPV6_HOST_ADDR}
    netmask ${IPV6_HOST_NETMASK}
    gateway ${IPV6_HOST_GATEWAY}
    ${IPV6_NS1}
    ${IPV6_NS2}

# for container IPv6
auto lxcbr0inet6
iface lxcbr0inet6 inet6 static
    address ${IPV6_BR_ADDR}
    netmask ${IPV6_BR_NETMASK}
    bridge_ports none
    bridge_stp off
    bridge_fd 0

EOF

	# enable forwarding
	LOG "Setting up sysctl for IPv6..."
	cat << EOF > /etc/sysctl.d/20-ipv6.conf
net.ipv6.conf.default.accept_ra=0
net.ipv6.conf.default.autoconf=0
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.accept_ra=0
net.ipv6.conf.all.autoconf=0
net.ipv6.conf.all.forwarding=1
EOF

	# configure ndppd to use advertise the container network
	LOG "Adding config for ${IPV6_BR_PREFIX} to /etc/ndppd.conf..."
	cat << EOF > /etc/ndppd.conf
route-ttl 30000
proxy ens3 {
    router no
    timeout 500
    ttl 30000
    rule ${IPV6_BR_PREFIX}/${IPV6_BR_NETMASK} {
        auto
    }
}
EOF

	LOG "Adding disabled lxcbr0inet6 network to /etc/lxc/default.conf..."
	cat << EOF >> /etc/lxc/default.conf
#lxc.net.1.type = veth
#lxc.net.1.link = lxcbr0inet6
#lxc.net.1.flags = up
#lxc.net.1.hwaddr = 00:16:3e:xx:xx:xx
#lxc.net.1.ipv6.address = ${IPV6_BR_PREFIX}/${IPV6_BR_NETMASK}
#lxc.net.1.ipv6.gateway = ${IPV6_BR_ADDR}
EOF

	# install and autostart ndppd
	LOG "Installing pre-configured ndppd..."
	apt-get update -y
	apt-get install -y ndppd
	systemctl enable ndppd
	systemctl restart ndppd
fi


LOG
LOG "Host network setup ok!"
LOG
LOG "Host network IPv4: ${IPV4_ADDR}/${IPV4_NETMASK}"
if [ "${IPV6_ENABLE}" = true ] ; then
	LOG "Host network IPv6: ${IPV6_HOST_ADDR}/${IPV6_HOST_NETMASK}"
	LOG "Container bridge(lxcbr0inet6): ${IPV6_BR_ADDR}/${IPV6_BR_NETMASK}"
fi
LOG "Rebooting recommended!"
LOG

#LOG "Restaring networking"
#systemctl restart networking
