#!/bin/bash
# goAmnezia: единственная наша правка к upstream — правила iptables ставятся идемпотентно.
# Зачем: upstream делает `iptables -A` при каждом старте, а контейнер стартует не один раз
#        (--restart always, перезагрузка хоста, core-update), и цепочки iptables распухают
#        дублями одних и тех же правил iptables после каждого рестарта контейнера;
#        форма `iptables -C … 2>/dev/null || iptables -A …` добавляет правило, только если его нет.

# This scripts copied from Amnezia client to Docker container to /opt/amnezia and launched every time container starts

echo "Container startup"
#ifconfig eth0:0 $SERVER_IP_ADDRESS netmask 255.255.255.255 up

# kill daemons in case of restart
awg-quick down /opt/amnezia/awg/awg0.conf

# start daemons if configured
if [ -f /opt/amnezia/awg/awg0.conf ]; then (awg-quick up /opt/amnezia/awg/awg0.conf); fi

# Allow traffic on the TUN interface.
iptables -C INPUT -i awg0 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg0 -j ACCEPT
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C OUTPUT -o awg0 -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o awg0 -j ACCEPT

# Allow forwarding traffic only from the VPN.
iptables -C FORWARD -i awg0 -o eth0 -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o eth0 -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -j ACCEPT
iptables -C FORWARD -i awg0 -o eth1 -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o eth1 -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -j ACCEPT

iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -C POSTROUTING -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -o eth0 -j MASQUERADE
iptables -t nat -C POSTROUTING -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -o eth1 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $AWG_SUBNET_IP/$WIREGUARD_SUBNET_CIDR -o eth1 -j MASQUERADE

tail -f /dev/null
