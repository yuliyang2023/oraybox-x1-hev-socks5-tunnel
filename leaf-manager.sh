#!/bin/sh
# OpenWrt procd owns the process, so it survives SSH disconnection.
SERVICE=/etc/init.d/leaf
BIN=/root/leaf-oray-vmess-ws-upx
CONFIG=/root/leaf.json
LOCK=/var/lock/leaf-manager.lock

running() {
    ubus call service list '{"name":"leaf"}' 2>/dev/null |
        jsonfilter -e '@.leaf.instances.*.running' | grep -q '^true$'
}
status() {
    if running; then
        echo "Leaf running (procd; SOCKS5 127.0.0.1:1080)"
        ubus call service list '{"name":"leaf"}' |
            jsonfilter -e '@.leaf.instances.*.pid'
    else
        echo "Leaf stopped"
        return 1
    fi
}
check() {
    [ -x "$BIN" ] || { echo "Missing binary: $BIN" >&2; return 1; }
    [ -r "$CONFIG" ] || { echo "Missing config: $CONFIG" >&2; return 1; }
    "$BIN" -c "$CONFIG" -T
}
start() {
    if running; then status; return 0; fi
    check || return 1
    "$SERVICE" start || return 1
    for attempt in 1 2 3 4 5; do
        sleep 1
        if running; then status; return 0; fi
    done
    echo "Leaf did not start; use $0 logs" >&2
    return 1
}
stop() {
    "$SERVICE" stop || return 1
    for attempt in 1 2 3 4 5; do
        if ! running; then echo "Leaf stopped"; return 0; fi
        sleep 1
    done
    echo "Leaf is still running" >&2
    return 1
}

case "${1:-}" in
    start|stop|restart|enable|disable)
        mkdir -p /var/lock
        exec 9>"$LOCK"
        flock -x 9 || exit 1
        ;;
esac
case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) check && stop && start ;;
    status) status ;;
    check) check ;;
    logs) logread | grep -i leaf | tail -n 80 ;;
    enable) check && "$SERVICE" enable && echo "Leaf enabled at boot" ;;
    disable) "$SERVICE" disable && echo "Leaf disabled at boot (current process unchanged)" ;;
    *) echo "Usage: $0 {start|stop|restart|status|check|logs|enable|disable}"; exit 2 ;;
esac
