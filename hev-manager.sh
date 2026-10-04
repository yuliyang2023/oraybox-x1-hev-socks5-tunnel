#!/bin/sh
# OpenWrt/BusyBox: /root/hev-manager.sh start|stop|restart|status|check
# LAN and directly connected WAN clients use HEV; router management stays on WAN.
set -eu
umask 077
BIN=/root/hev-socks5-tunnel
CONFIG=/root/hev.yml
STATE=/tmp/hev-manager
LAN=br-lan
TUN=tun0
TABLE=180
DNS_MARK=18518
# Mapped DNS answers locally; SOCKS5 resolves names when TCP connects.
DNS_SERVER=198.18.0.2
FAKE_NET=198.19.0.0/16
RESOLV=/tmp/hev-manager-resolv.conf
DNS_PREF=18010
LAN_PREF=18020
WAN_PREF=18021

detect_network() {
    WAN=$(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1);exit}}')
    [ -n "$WAN" ] && [ "$WAN" != "$TUN" ] && [ "$WAN" != "$LAN" ] || {
        echo "Cannot determine a separate WAN from main default route" >&2; return 1;
    }
    WAN_IP=$(ip -4 route show table main default | awk -v dev="$WAN" '$0 ~ ("dev " dev " ") {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1);exit}}')
    if [ -z "$WAN_IP" ]; then
        WAN_IP=$(ip -4 addr show dev "$WAN" scope global | awk '$1=="inet" {split($2,a,"/");print a[1];exit}')
    fi
    WAN_NET=$(ip -4 route show table main dev "$WAN" | awk -v addr="$WAN_IP" '$1 ~ /\// && /scope link/ {for(i=1;i<=NF;i++) if($i=="src" && $(i+1)==addr) {print $1;exit}}')
    LAN_IP=$(ip -4 addr show dev "$LAN" scope global | awk '$1=="inet" {split($2,a,"/");print a[1];exit}')
    lan_net=$(ip -4 route show table main dev "$LAN" | awk '$1 ~ /\// && /scope link/ {print $1;exit}')
    [ -n "$WAN_IP" ] && [ -n "$WAN_NET" ] && [ -n "$LAN_IP" ] && [ -n "$lan_net" ] || {
        echo "Cannot determine directly connected WAN/LAN IPv4 subnet" >&2; return 1;
    }
    [ "$WAN_NET" != "$lan_net" ] || { echo "Overlapping WAN/LAN subnet" >&2; return 1; }
}

save_set() {
    path=$1
    value=$2
    printf '%s %s\n' "$path" "$(cat "/proc/sys/$path")" >> "$STATE/sysctl-save"
    printf '%s\n' "$value" > "/proc/sys/$path"
}

alive() {
    [ -f "$STATE/pid" ] || return 1
    pid=$(cat "$STATE/pid")
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$pid" 2>/dev/null &&
        [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$BIN" ]
}
remove_rules() {
    iptables -D FORWARD -j HEV_LAN 2>/dev/null || :
    ip6tables -D FORWARD -j HEV_LAN6 2>/dev/null || :
    iptables -D OUTPUT -j HEV_DNS_GUARD 2>/dev/null || :
    ip6tables -D OUTPUT -j HEV_DNS6 2>/dev/null || :
    iptables -t nat -D OUTPUT -j HEV_DNS_NAT 2>/dev/null || :
    iptables -t nat -D PREROUTING -j HEV_CLIENT_DNS 2>/dev/null || :
    iptables -t mangle -D OUTPUT -j HEV_DNS_MARK 2>/dev/null || :
    for c in HEV_LAN HEV_DNS_GUARD; do
        iptables -F "$c" 2>/dev/null || :
        iptables -X "$c" 2>/dev/null || :
    done
    for c in HEV_LAN6 HEV_DNS6; do
        ip6tables -F "$c" 2>/dev/null || :
        ip6tables -X "$c" 2>/dev/null || :
    done
    iptables -t nat -F HEV_DNS_NAT 2>/dev/null || :
    iptables -t nat -X HEV_DNS_NAT 2>/dev/null || :
    iptables -t nat -F HEV_CLIENT_DNS 2>/dev/null || :
    iptables -t nat -X HEV_CLIENT_DNS 2>/dev/null || :
    iptables -t mangle -F HEV_DNS_MARK 2>/dev/null || :
    iptables -t mangle -X HEV_DNS_MARK 2>/dev/null || :
    ip rule del pref "$DNS_PREF" fwmark "$DNS_MARK" lookup "$TABLE" 2>/dev/null || :
    ip rule del pref "$LAN_PREF" iif "$LAN" lookup "$TABLE" 2>/dev/null || :
    ip rule del pref "$WAN_PREF" lookup "$TABLE" 2>/dev/null || :
    ip route flush table "$TABLE" 2>/dev/null || :
    if [ -f "$STATE/mapped-routes" ]; then
        ip route del "$DNS_SERVER/32" dev "$TUN" table main 2>/dev/null || :
        ip route del "$FAKE_NET" dev "$TUN" table main 2>/dev/null || :
    fi
}
stop_internal() {
    [ -d "$STATE" ] || { echo "Not managed/running."; return; }
    # Remove interception before stopping HEV; explicit stop restores direct access.
    remove_rules
    if [ -f "$STATE/dns-resolvfile" ]; then
        if [ "$(uci -q get 'dhcp.@dnsmasq[0].resolvfile' || :)" = "$RESOLV" ]; then
            old_resolv=$(cat "$STATE/dns-resolvfile")
            if [ -n "$old_resolv" ]; then
                uci set "dhcp.@dnsmasq[0].resolvfile=$old_resolv"
            else
                uci -q delete 'dhcp.@dnsmasq[0].resolvfile' || :
            fi
            /etc/init.d/dnsmasq restart
        fi
        rm -f "$RESOLV"
    fi
    if alive; then
        kill "$pid"
        n=0
        while alive && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
        if alive; then kill -9 "$pid"; fi
    fi
    if [ -f "$STATE/rp_filter" ]; then
        sysctl -w "net.ipv4.conf.all.rp_filter=$(cat "$STATE/rp_filter")" >/dev/null
    fi
    if [ -f "$STATE/sysctl-save" ]; then
        while read -r path value; do
            [ ! -f "/proc/sys/$path" ] || printf '%s\n' "$value" > "/proc/sys/$path"
        done < "$STATE/sysctl-save"
    fi
    rm -f "$STATE/pid" "$STATE/config.yml" "$STATE/rp_filter" "$STATE/active" "$STATE/sysctl-save" "$STATE/network" "$STATE/mapped-routes" "$STATE/dns-resolvfile" "$STATE/resolv.conf"
    rmdir "$STATE" 2>/dev/null || :
    echo "Stopped; normal WAN routing restored."
}
check() {
    for c in ip iptables ip6tables nslookup sysctl awk readlink flock nohup uci; do
        command -v "$c" >/dev/null || { echo "Missing command: $c" >&2; return 1; }
    done
    [ -x "$BIN" ] && [ -r "$CONFIG" ] && [ -c /dev/net/tun ] || {
        echo "Missing executable, config or /dev/net/tun" >&2; return 1;
    }
    ip link show "$LAN" >/dev/null
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || {
        echo "IPv4 forwarding must be enabled" >&2; return 1;
    }
    detect_network
    [ -x /etc/init.d/dnsmasq ] || { echo "Missing dnsmasq service" >&2; return 1; }
    [ "$(uci -q get 'dhcp.@dnsmasq[0].noresolv' || :)" != 1 ] || {
        echo "dnsmasq noresolv=1 is incompatible with managed resolver" >&2; return 1;
    }
    echo "Detected WAN: $WAN, address: $WAN_IP, subnet: $WAN_NET"
    echo "Detected LAN: $LAN, address: $LAN_IP, subnet: $lan_net"
    echo "Basic prerequisites OK (no network changes)."
}
start() {
    check
    if [ -d "$STATE" ]; then
        echo "Managed state exists; use status, or restart to rebuild rules." >&2
        return 1
    fi
    if [ -e "$RESOLV" ] || [ -L "$RESOLV" ]; then
        echo "Managed resolver file already exists" >&2; return 1
    fi
    if ip link show "$TUN" >/dev/null 2>&1; then
        echo "$TUN already exists; refusing to take over it." >&2; return 1
    fi
    if [ -n "$(ip route show table "$TABLE" 2>/dev/null)" ] ||
       ip rule show | awk -v a="$DNS_PREF:" -v b="$LAN_PREF:" -v c="$WAN_PREF:" '$1==a || $1==b || $1==c {found=1} END {exit !found}'; then
        echo "Routing table/priorities already in use." >&2; return 1
    fi
    for c in HEV_LAN HEV_DNS_GUARD; do
        if iptables -S "$c" >/dev/null 2>&1; then echo "Chain $c already exists" >&2; return 1; fi
    done
    if [ -n "$(ip -4 route show table main exact "$DNS_SERVER/32")" ] ||
       [ -n "$(ip -4 route show table main exact "$FAKE_NET")" ]; then
        echo "Mapped DNS routes already in use" >&2; return 1
    fi
    case "$WAN_NET $lan_net" in
        *198.18.*|*198.19.*) echo "Connected subnet conflicts with mapped DNS address pool" >&2; return 1;;
    esac
    for c in HEV_LAN6 HEV_DNS6; do
        if ip6tables -S "$c" >/dev/null 2>&1; then echo "Chain $c already exists" >&2; return 1; fi
    done
    if iptables -t nat -S HEV_DNS_NAT >/dev/null 2>&1 ||
       iptables -t nat -S HEV_CLIENT_DNS >/dev/null 2>&1 ||
       iptables -t mangle -S HEV_DNS_MARK >/dev/null 2>&1; then
        echo "DNS chain already exists" >&2; return 1
    fi
    # Read only endpoint; never print credentials. Resolve before DNS interception.
    host=$(awk '/^socks5:/ {s=1;next} /^[^ #]/ {s=0} s && $1=="address:" {v=$2;gsub(/[\047\042]/,"",v);print v;exit}' "$CONFIG")
    [ -n "$host" ] || { echo "Missing socks5.address" >&2; return 1; }
    case "$host" in
        *[!0-9.]*|*:* )
            endpoint=$(nslookup "$host" 2>/dev/null | awk '/^Name:/ {s=1} s && /^Address/ {for(i=2;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i;exit}}')
            [ -n "$endpoint" ] || { echo "Cannot resolve proxy to IPv4" >&2; return 1; };;
        *) endpoint=$host;;
    esac
    mkdir "$STATE"
    trap 'echo "Start failed; rolling back." >&2; stop_internal' EXIT
    trap 'exit 1' INT TERM
    # Runtime config forces tun0 and pins resolved proxy IP; original remains intact.
    awk -v endpoint="$endpoint" -v tun="$TUN" '
        /^tunnel:/ {section="tunnel"}
        /^socks5:/ {section="socks5"}
        /^mapdns:/ {section="mapdns"}
        /^[^ #]/ && !/^tunnel:/ && !/^socks5:/ && !/^mapdns:/ {section=""}
        section=="mapdns" {next}
        section=="tunnel" && $1=="name:" {print "  name: " tun;next}
        section=="socks5" && $1=="address:" {print "  address: \042" endpoint "\042";next}
        $1=="pid-file:" {next}
        {print}
    ' "$CONFIG" > "$STATE/config.yml"
    cat >> "$STATE/config.yml" <<MAPDNS

mapdns:
  address: $DNS_SERVER
  port: 53
  network: 198.19.0.0
  netmask: 255.255.0.0
  cache-size: 4096
MAPDNS
    printf 'WAN=%s IP=%s subnet=%s\nLAN=%s IP=%s subnet=%s\n' "$WAN" "$WAN_IP" "$WAN_NET" "$LAN" "$LAN_IP" "$lan_net" > "$STATE/network"
    save_set net/ipv4/conf/all/rp_filter 0
    save_set "net/ipv4/conf/$WAN/rp_filter" 0
    save_set net/ipv4/conf/all/send_redirects 0
    save_set net/ipv4/conf/default/send_redirects 0
    save_set "net/ipv4/conf/$WAN/send_redirects" 0
    # Close lock FD in child so stop/restart never blocks behind the daemon.
    nohup "$BIN" "$STATE/config.yml" </dev/null 9>&- >> /tmp/hev-manager.log 2>&1 &
    echo "$!" > "$STATE/pid"
    n=0
    until ip link show "$TUN" >/dev/null 2>&1; do
        alive || { echo "HEV exited; inspect /tmp/hev-manager.log" >&2; exit 1; }
        n=$((n + 1)); [ "$n" -lt 10 ] || { echo "TUN startup timeout" >&2; exit 1; }
        sleep 1
    done
    alive || { echo "HEV exited during startup" >&2; exit 1; }
    sysctl -w "net.ipv4.conf.$TUN.rp_filter=0" >/dev/null
    ip route add "$lan_net" dev "$LAN" table "$TABLE"
    ip route add "$WAN_NET" dev "$WAN" table "$TABLE"
    ip route add unreachable default metric 32760 table "$TABLE"
    ip route add default dev "$TUN" metric 1 table "$TABLE"
    touch "$STATE/mapped-routes"
    ip route add "$DNS_SERVER/32" dev "$TUN" table main
    ip route add "$FAKE_NET" dev "$TUN" table main

    iptables -N HEV_LAN
    iptables -A HEV_LAN -i "$TUN" -o "$LAN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A HEV_LAN -i "$LAN" -o "$LAN" -j RETURN
    iptables -A HEV_LAN -i "$LAN" -o "$TUN" -p tcp -j ACCEPT
    iptables -A HEV_LAN -i "$LAN" -o "$TUN" -p udp -j ACCEPT
    iptables -A HEV_LAN -i "$LAN" -j REJECT
    iptables -A HEV_LAN -i "$TUN" -o "$WAN" -d "$WAN_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A HEV_LAN -i "$WAN" -s "$WAN_NET" -o "$WAN" -d "$WAN_NET" -j RETURN
    iptables -A HEV_LAN -i "$WAN" -s "$WAN_NET" -o "$LAN" -d "$lan_net" -j RETURN
    iptables -A HEV_LAN -i "$WAN" -s "$WAN_NET" -o "$TUN" -p tcp -j ACCEPT
    iptables -A HEV_LAN -i "$WAN" -s "$WAN_NET" -o "$TUN" -p udp -j ACCEPT
    iptables -A HEV_LAN -i "$WAN" -s "$WAN_NET" -j REJECT
    iptables -I FORWARD 1 -j HEV_LAN
    ip6tables -N HEV_LAN6
    ip6tables -A HEV_LAN6 -i "$LAN" -o "$LAN" -j RETURN
    ip6tables -A HEV_LAN6 -i "$LAN" -j REJECT
    # For WAN-side clients, IPv6 forwarded back out WAN is blocked.
    # Clients must also disable IPv6 or use this device as their IPv6 gateway;
    # an IPv6 path through a different router never reaches this firewall.
    ip6tables -A HEV_LAN6 -i "$WAN" -o "$WAN" -j REJECT
    ip6tables -I FORWARD 1 -j HEV_LAN6

    # Router DNS is translated to HEV's mapped DNS inside TUN.
    iptables -t mangle -N HEV_DNS_MARK
    iptables -t nat -N HEV_DNS_NAT
    iptables -t nat -N HEV_CLIENT_DNS
    # Include client DNS sent to this router, bypassing dnsmasq's WAN-bound sockets.
    iptables -N HEV_DNS_GUARD
    ip6tables -N HEV_DNS6
    for proto in udp tcp; do
        # Redirect client DNS even when it targets the upstream router on WAN.
        iptables -t nat -A HEV_CLIENT_DNS -i "$LAN" -p "$proto" --dport 53 -j DNAT --to-destination "$DNS_SERVER"
        iptables -t nat -A HEV_CLIENT_DNS -i "$WAN" -s "$WAN_NET" -p "$proto" --dport 53 -j DNAT --to-destination "$DNS_SERVER"
        iptables -t mangle -A HEV_DNS_MARK ! -d 127.0.0.0/8 -p "$proto" --dport 53 -j MARK --set-mark "$DNS_MARK"
        iptables -t nat -A HEV_DNS_NAT ! -d 127.0.0.0/8 -p "$proto" --dport 53 -j DNAT --to-destination "$DNS_SERVER"
        iptables -A HEV_DNS_GUARD ! -d 127.0.0.0/8 ! -o "$TUN" -p "$proto" --dport 53 -j REJECT
        ip6tables -A HEV_DNS6 ! -d ::1/128 -p "$proto" --dport 53 -j REJECT
    done
    iptables -I OUTPUT 1 -j HEV_DNS_GUARD
    ip6tables -I OUTPUT 1 -j HEV_DNS6
    ip rule add pref "$DNS_PREF" fwmark "$DNS_MARK" lookup "$TABLE"
    ip rule add pref "$LAN_PREF" iif "$LAN" lookup "$TABLE"
    ip rule add pref "$WAN_PREF" from "$WAN_NET" iif "$WAN" lookup "$TABLE"
    iptables -t mangle -I OUTPUT 1 -j HEV_DNS_MARK
    iptables -t nat -I OUTPUT 1 -j HEV_DNS_NAT
    iptables -t nat -I PREROUTING 1 -j HEV_CLIENT_DNS
    # DNSmasq binds sockets to the resolver's interface. Point it directly to
    # mapped DNS on TUN, instead of relying on OUTPUT NAT of WAN-bound sockets.
    uci -q get 'dhcp.@dnsmasq[0].resolvfile' > "$STATE/dns-resolvfile" || :
    printf 'nameserver %s\n' "$DNS_SERVER" > "$RESOLV"
    chmod 644 "$RESOLV"
    uci set "dhcp.@dnsmasq[0].resolvfile=$RESOLV"
    /etc/init.d/dnsmasq restart
    touch "$STATE/active"
    trap - EXIT INT TERM
    echo "Started. LAN and WAN-side $WAN_NET client IPv4 TCP/UDP uses $TUN."
    echo "WAN clients: set IPv4 gateway and DNS to $WAN_IP; disable other IPv6 paths."
    echo "UDP requires SOCKS5 UDP support. Firewall reload requires restart."
}
status() {
    if alive; then echo "HEV running (PID $pid)"; else echo "HEV not running"; fi
    if [ -f "$STATE/active" ]; then echo "Managed interception installed; verify rules below."; fi
    ip link show "$TUN" 2>/dev/null || :
    [ ! -f "$STATE/network" ] || cat "$STATE/network"
    ip rule show | awk -v a="$DNS_PREF:" -v b="$LAN_PREF:" -v c="$WAN_PREF:" '$1==a || $1==b || $1==c'
    ip route show table "$TABLE" 2>/dev/null || :
    iptables -S HEV_LAN 2>/dev/null || :
    iptables -C FORWARD -j HEV_LAN 2>/dev/null || echo "LAN forwarding guard absent"
    ip6tables -C FORWARD -j HEV_LAN6 2>/dev/null || echo "IPv6 forwarding guard absent"
    iptables -C OUTPUT -j HEV_DNS_GUARD 2>/dev/null || echo "DNS guard absent"
    iptables -t nat -C PREROUTING -j HEV_CLIENT_DNS 2>/dev/null || echo "Client DNS interception absent"
}
exec 9>/tmp/hev-manager.lock
flock -x 9
case "${1:-status}" in
    start) start;;
    stop) stop_internal;;
    restart) stop_internal; start;;
    status) status;;
    check) check;;
    *) echo "Usage: $0 {start|stop|restart|status|check}" >&2; exit 2;;
esac
