#!/bin/sh
# Runtime host pins keep VMess bootstrap DNS outside HEV mapped DNS.
set -e
umask 077
STATE=/tmp/hev-leaf-manager
LEAF=/root/leaf-manager.sh
HEV=/root/hev-manager.sh
BIN=/root/leaf-oray-vmess-ws-upx
leaf() { "$LEAF" "$@" 8>&-; }
hev() { "$HEV" "$@" 8>&-; }
leaf_running() { leaf status >/dev/null 2>&1; }
stop_leaf() { if leaf_running; then leaf stop; else echo "Leaf stopped"; fi; }
hev_running() {
    [ -f /tmp/hev-manager/pid ] || return 1
    p=$(cat /tmp/hev-manager/pid)
    case "$p" in ''|*[!0-9]*) return 1;; esac
    [ "$(readlink /proc/$p/exe 2>/dev/null)" = /root/hev-socks5-tunnel ]
}
check() {
    for c in flock jsonfilter nslookup awk sha256sum ubus; do
        command -v "$c" >/dev/null || { echo "Missing: $c" >&2; return 1; }
    done
    [ -r /usr/share/libubox/jshn.sh ] && [ -x "$LEAF" ] && [ -x "$HEV" ] || return 1
    grep -q 'HEV_CONFIG' "$HEV" || { echo "HEV runtime-config support missing" >&2; return 1; }
    grep -q 'LEAF_CONFIG' /etc/init.d/leaf || { echo "Leaf runtime-config support missing" >&2; return 1; }
    leaf check
    [ "$(jsonfilter -i /root/leaf.json -e '@.inbounds[@.protocol="socks"].address')" = 127.0.0.1 ] &&
    [ "$(jsonfilter -i /root/leaf.json -e '@.inbounds[@.protocol="socks"].port')" = 1080 ] || {
        echo "Require one local SOCKS5 inbound at 127.0.0.1:1080" >&2; return 1;
    }
    hev check
}
clear_state() {
    [ -d "$STATE" ] || return 0
    rm -f "$STATE/leaf.json" "$STATE/hev.yml" "$STATE/hosts" "$STATE/addresses" \
        "$STATE/dns-answer" "$STATE/active" "$STATE/source.sha256"
    rmdir "$STATE"
}
rollback() {
    trap - EXIT INT TERM
    echo "Combined start failed; restoring previous services." >&2
    hev stop || :
    stop_leaf || :
    clear_state || :
    if [ "$WAS_LEAF" = 1 ]; then leaf start || :; fi
    if [ "$WAS_HEV" = 1 ]; then hev start || :; fi
}
prepare_leaf() (
    # All edits are in /tmp; credentials and the server domain in the source stay intact.
    . /usr/share/libubox/jshn.sh
    json_load "$(cat /root/leaf.json)"
    jsonfilter -i /root/leaf.json -e '@.outbounds[@.protocol="vmess"].settings.address' > "$STATE/hosts"
    [ -s "$STATE/hosts" ] || { echo "No VMess server found" >&2; exit 1; }
    json_select dns 2>/dev/null || json_add_object dns
    json_select hosts 2>/dev/null || json_add_object hosts
    while IFS= read -r host; do
        case "$host" in ''|*[!a-zA-Z0-9._-]*) echo "Unsupported server address" >&2; exit 1;; esac
        case "$host" in
            *[!0-9.]* )
                nslookup "$host" > "$STATE/dns-answer" 2>/dev/null || {
                    echo "VMess bootstrap DNS failed" >&2; exit 1;
                }
                awk '
                    /^Name:/ {answer=1}
                    answer && /^Address/ {
                        for(i=2;i<=NF;i++) {
                            n=split($i,a,"."); ok=(n==4)
                            for(j=1;j<=n;j++) if(a[j] !~ /^[0-9]+$/ || a[j]>255) ok=0
                            if(ok && !(a[1]==198 && (a[2]==18 || a[2]==19)) && !seen[$i]++) print $i
                        }
                    }
                ' "$STATE/dns-answer" > "$STATE/addresses"
                [ -s "$STATE/addresses" ] || { echo "No real IPv4 bootstrap answer" >&2; exit 1; }
                json_add_array "$host"
                while IFS= read -r ip; do json_add_string '' "$ip"; done < "$STATE/addresses"
                json_close_array
                ;;
            198.18.*|198.19.* ) echo "VMess server is a synthetic address" >&2; exit 1;;
            *) : ;;
        esac
    done < "$STATE/hosts"
    json_select ''
    json_dump > "$STATE/leaf.json"
    "$BIN" -c "$STATE/leaf.json" -T
)
prepare_hev() {
    awk '
        /^socks5:/ {
            s=1
            print "socks5:"
            print "  address: 127.0.0.1"
            print "  port: 1080"
            next
        }
        /^[^ #]/ {s=0}
        s && ($1=="address:" || $1=="port:" || $1=="username:" || $1=="password:") {next}
        {print}
    ' /root/hev.yml > "$STATE/hev.yml"
    grep -q '^socks5:' "$STATE/hev.yml"
}
start() {
    check
    if [ -f "$STATE/active" ] && leaf_running && hev_running; then
        if ! sha256sum -c "$STATE/source.sha256" >/dev/null 2>&1; then
            echo "Source config changed; use restart." >&2; return 1
        fi
        echo "Leaf + HEV already running."
        return 0
    fi
    [ ! -d "$STATE" ] || { echo "Existing combined state; use restart." >&2; return 1; }
    WAS_HEV=0; WAS_LEAF=0
    if hev_running; then WAS_HEV=1; fi
    if leaf_running; then WAS_LEAF=1; fi
    mkdir "$STATE"
    trap rollback EXIT
    trap 'exit 1' INT TERM
    # Stop interception first so device DNS supplies real bootstrap addresses.
    hev stop
    prepare_leaf
    prepare_hev
    stop_leaf
    LEAF_CONFIG="$STATE/leaf.json" /etc/init.d/leaf start 8>&-
    sleep 2
    leaf_running || { echo "Leaf startup failed" >&2; return 1; }
    HEV_CONFIG="$STATE/hev.yml" "$HEV" start 8>&-
    hev_running || { echo "HEV startup failed" >&2; return 1; }
    sha256sum /root/leaf.json /root/hev.yml > "$STATE/source.sha256"
    touch "$STATE/active"
    trap - EXIT INT TERM
    echo "Started Leaf + HEV; upstream domains resolved before interception."
}
stop() {
    # Restores network access before stopping the local SOCKS5 backend.
    hev stop
    stop_leaf
    clear_state
    echo "Stopped Leaf + HEV; normal WAN routing restored."
}
status() {
    if [ -f "$STATE/active" ]; then echo "Combined runtime configuration active"; else echo "Combined runtime not active"; fi
    leaf status || :
    hev status
    if [ -f "$STATE/source.sha256" ] && ! sha256sum -c "$STATE/source.sha256" >/dev/null 2>&1; then
        echo "Source configuration changed; restart required."
    fi
}
exec 8>/tmp/hev-manager-with-leaf.lock
flock -x 8
case "${1:-status}" in
    start) start ;;
    stop) stop ;;
    restart) check; stop; start ;;
    status) status ;;
    check) check ;;
    logs) leaf logs; tail -n 80 /tmp/hev-manager.log 2>/dev/null || : ;;
    *) echo "Usage: $0 {start|stop|restart|status|check|logs}" >&2; exit 2 ;;
esac
