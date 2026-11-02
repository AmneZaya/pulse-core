#!/bin/bash
# goAmnezia: единственная наша правка к upstream — правила iptables ставятся идемпотентно.
# Зачем: upstream делает `iptables -A` при каждом старте, а контейнер стартует не один раз
#        (--restart always, перезагрузка хоста, core-update), и цепочки iptables распухают
#        дублями одних и тех же правил iptables после каждого рестарта контейнера;
#        форма `iptables -C … 2>/dev/null || iptables -A …` добавляет правило, только если его нет.

# This scripts copied from Amnezia client to Docker container to /opt/amnezia and launched every time container starts

echo "Container startup"
#ifconfig eth0:0 138.124.92.198 netmask 255.255.255.255 up

# kill daemons in case of restart
awg-quick down /opt/amnezia/awg/awg0.conf

# start daemons if configured
# --- goamnezia-engine BEGIN ---
# goAmnezia: движок AmneziaWG. /opt/amnezia/awg/engine = program — программа amneziawg-go, даже когда на хосте
# загружен модуль ядра (awg-quick выбрал бы его сам); иначе — awg-quick, как у приложения Amnezia.
if [ -f /opt/amnezia/awg/awg0.conf ]; then
  if [ "$(cat /opt/amnezia/awg/engine 2>/dev/null)" = program ]; then
    ip link del dev awg0 2>/dev/null
    amneziawg-go awg0
    awg-quick strip /opt/amnezia/awg/awg0.conf | awg setconf awg0 /dev/stdin
    for ga_a in $(sed -n 's/^[[:space:]]*Address[[:space:]]*=//p' /opt/amnezia/awg/awg0.conf | tr ',' ' '); do
      ip address add "$ga_a" dev awg0
    done
    ga_m=$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' /opt/amnezia/awg/awg0.conf | head -n 1)
    if [ -z "$ga_m" ]; then
      ga_d=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
      ga_m=$(( $(cat "/sys/class/net/${ga_d:-eth0}/mtu" 2>/dev/null || echo 1500) - 80 ))
    fi
    ip link set dev awg0 mtu "$ga_m" up
    awg show awg0 allowed-ips 2>/dev/null | while read -r ga_k ga_ips; do
      for ga_r in $ga_ips; do
        case "$ga_r" in */0|'(none)') continue ;; */*) ;; *) continue ;; esac
        case "$ga_r" in *:*) ga_f=-6 ;; *) ga_f=-4 ;; esac
        [ -n "$(ip $ga_f route show dev awg0 match "$ga_r" 2>/dev/null)" ] || ip $ga_f route add "$ga_r" dev awg0
      done
    done
  else
    (awg-quick up /opt/amnezia/awg/awg0.conf)
  fi
fi
# --- goamnezia-engine END ---

# Allow traffic on the TUN interface.
iptables -C FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null || iptables -I FORWARD 1 -i awg0 -o awg0 -j DROP # goamnezia-client-isolation
iptables -C INPUT -i awg0 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg0 -j ACCEPT
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C OUTPUT -o awg0 -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o awg0 -j ACCEPT

# Allow forwarding traffic only from the VPN.
iptables -C FORWARD -i awg0 -o eth0 -s 10.8.2.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o eth0 -s 10.8.2.0/24 -j ACCEPT
iptables -C FORWARD -i awg0 -o eth1 -s 10.8.2.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o eth1 -s 10.8.2.0/24 -j ACCEPT

iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -C POSTROUTING -s 10.8.2.0/24 -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.2.0/24 -o eth0 -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.8.2.0/24 -o eth1 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.2.0/24 -o eth1 -j MASQUERADE

# --- goamnezia-mss BEGIN ---
# goAmnezia: TCP MSS по MTU туннеля (TCPMSS) — за роутером-клиентом устройства с MTU 1500, без этого сайты «висят»
ga_mtu=$(ip -o link show dev awg0 2>/dev/null | sed -n 's/.* mtu \([0-9][0-9]*\).*/\1/p')
[ -n "$ga_mtu" ] || ga_mtu=1280
for ga_t in iptables:40 ip6tables:60; do
  ga_b=${ga_t%:*}; ga_v=$((ga_mtu - ${ga_t#*:}))
  command -v "$ga_b" >/dev/null 2>&1 || continue
  "$ga_b" -t mangle -S FORWARD 2>/dev/null | sed -n 's/^-A \(FORWARD -i awg0 .*-j TCPMSS --set-mss \)\([0-9][0-9]*\)$/\2 \1\2/p' | while read -r ga_o ga_r; do [ "$ga_o" = "$ga_v" ] || "$ga_b" -t mangle -D $ga_r; done
  "$ga_b" -t mangle -C FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$ga_v" 2>/dev/null || "$ga_b" -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$ga_v" 2>/dev/null
  "$ga_b" -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || "$ga_b" -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
done
# --- goamnezia-mss END ---
tail -f /dev/null
