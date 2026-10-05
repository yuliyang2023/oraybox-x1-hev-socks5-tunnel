#!/bin/sh
# OpenWrt: manage /root/easytier-mini independently of Leaf + HEV.
set -eu
umask 077
BIN=/root/easytier-mini
CONFIG=/root/easytier.conf
STATE=/tmp/easytier-manager
LOG=/tmp/easytier-mini.log
LEGACY_PID=/tmp/easytier-mini.pid
LOCK=/var/lock/easytier-manager.lock

# Read only simple scalar flags; this is not a complete TOML parser.
flag() {
    awk -v key="$1" '
        /^[[:space:]]*\[flags\][[:space:]]*(#.*)?$/ {inside=1; next}
        /^[[:space:]]*\[/ {inside=0}
        inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            sub(/[[:space:]]*$/, "")
            gsub(/^["\047]|["\047]$/, "")
            print
        }
    ' "$CONFIG"
}

process_matches() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$BIN" ] || return 1
    process_arg=$(tr '\000' '\n' < "/proc/$1/cmdline" 2>/dev/null |
        awk 'previous == "--config" || previous == "-c" {print; exit} {previous=$0}')
    case "$process_arg" in
        /*) process_path=$process_arg ;;
        '') return 1 ;;
        *) process_path="$(readlink "/proc/$1/cwd" 2>/dev/null)/$process_arg" ;;
    esac
    [ "$process_path" = "$CONFIG" ] && return 0
    process_path=$(readlink -f "$process_path" 2>/dev/null) || return 1
    config_path=$(readlink -f "$CONFIG" 2>/dev/null) || return 1
    [ -n "$process_path" ] && [ "$process_path" = "$config_path" ]
}

starttime() {
    # Strip pid and parenthesized comm first, since comm can contain spaces.
    awk '{sub(/^.*\) /, ""); print $20}' "/proc/$1/stat" 2>/dev/null
}

find_processes() {
    for process_dir in /proc/[0-9]*; do
        process_pid=${process_dir##*/}
        if process_matches "$process_pid"; then printf '%s\n' "$process_pid"; fi
    done
}

same_process() {
    process_matches "$1" && [ "$(starttime "$1")" = "$2" ]
}

record_process() {
    mkdir -p "$STATE"
    printf '%s\n' "$1" > "$STATE/pid"
    starttime "$1" > "$STATE/starttime"
    printf '%s\n' "$1" > "$LEGACY_PID"
}

clear_state() {
    rm -f "$STATE/pid" "$STATE/starttime" "$STATE/source.sha256" "$LEGACY_PID"
    if [ -d "$STATE" ]; then rmdir "$STATE" 2>/dev/null || :; fi
}

check() {
    [ "$(id -u)" = 0 ] || { echo "Run as root" >&2; return 1; }
    for command_name in ip awk readlink tr sha256sum flock nohup tail; do
        command -v "$command_name" >/dev/null || {
            echo "Missing command: $command_name" >&2; return 1;
        }
    done
    [ -x "$BIN" ] || { echo "Missing executable: $BIN" >&2; return 1; }
    [ -r "$CONFIG" ] || { echo "Missing config: $CONFIG" >&2; return 1; }
    [ -c /dev/net/tun ] || { echo "Missing /dev/net/tun" >&2; return 1; }
    TUN=$(flag dev_name)
    case "$TUN" in
        ''|tun0|*[!a-zA-Z0-9_.-]*)
            echo 'Set a separate [flags] dev_name, for example "et0" (not tun0)' >&2
            return 1 ;;
    esac
    [ "${#TUN}" -le 15 ] || { echo "TUN name is too long" >&2; return 1; }
    [ "$(flag no_tun)" != true ] || {
        echo "This manager expects TUN mode; no_tun=true is unsupported" >&2; return 1;
    }
    if [ "$(flag bind_device)" != false ]; then
        echo 'Warning: set [flags] bind_device=false when using HEV for WSS' >&2
    fi
    "$BIN" --version
    echo "Prerequisites OK; full TOML and peer connectivity are checked at runtime."
}

status() {
    pids=$(find_processes)
    if [ -z "$pids" ]; then
        echo "EasyTier stopped (stale PID files are not treated as running)."
        return 1
    fi
    echo "EasyTier running (PID: $(printf '%s' "$pids" | tr '\n' ' '))"
    echo "Config: $CONFIG; log: $LOG"
    if [ -f "$STATE/source.sha256" ] &&
        ! sha256sum -c "$STATE/source.sha256" >/dev/null 2>&1; then
        echo "Config changed; use restart."
    elif [ ! -f "$STATE/source.sha256" ]; then
        echo "Existing process found; its loaded config version is unknown."
    fi
    if [ -r "$CONFIG" ]; then
        TUN=$(flag dev_name)
        case "$TUN" in ''|*[!a-zA-Z0-9_.-]*) :;;
            *) ip -4 addr show dev "$TUN" 2>/dev/null || echo "TUN not ready: $TUN" ;;
        esac
    fi
    echo "Process/interface status does not prove a peer connection; inspect logs or ping a peer."
}

start() {
    check || return 1
    pids=$(find_processes)
    if [ -n "$pids" ]; then
        case "$pids" in *'
'*) echo "Multiple matching processes; stop them before starting" >&2; return 1;; esac
        if [ -f "$STATE/source.sha256" ] &&
            ! sha256sum -c "$STATE/source.sha256" >/dev/null 2>&1; then
            echo "Config changed; use restart" >&2; return 1
        fi
        record_process "$pids"
        echo "Already running; no duplicate process started."
        status
        return
    fi
    if ip link show dev "$TUN" >/dev/null 2>&1; then
        echo "Interface $TUN already exists without a matching Mini process; start cancelled" >&2
        return 1
    fi
    mkdir -p "$STATE"
    sha256sum "$CONFIG" > "$STATE/source.sha256"
    nohup "$BIN" --config "$CONFIG" </dev/null >"$LOG" 2>&1 9>&- &
    new_pid=$!
    record_process "$new_pid"
    birth=$(cat "$STATE/starttime")
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        if ! same_process "$new_pid" "$birth"; then
            clear_state
            echo "EasyTier exited during startup; inspect $LOG" >&2
            return 1
        fi
        if ip link show dev "$TUN" >/dev/null 2>&1; then
            echo "Started in background; SSH disconnection does not stop it."
            status
            return
        fi
    done
    echo "TUN not ready after 10 seconds; stopping the new process. Inspect $LOG" >&2
    stop
    return 1
}

stop() {
    # Discover by executable + config, never trust a stale PID file alone.
    pids=$(find_processes)
    for stop_pid in $pids; do
        birth=$(starttime "$stop_pid")
        if same_process "$stop_pid" "$birth"; then kill -INT "$stop_pid" || :; fi
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            if ! same_process "$stop_pid" "$birth"; then break; fi
            sleep 1
        done
        if same_process "$stop_pid" "$birth"; then
            echo "PID $stop_pid did not stop gracefully; sending TERM" >&2
            kill -TERM "$stop_pid" || :
            sleep 1
        fi
        if same_process "$stop_pid" "$birth"; then
            echo "PID $stop_pid is still running; state retained" >&2
            return 1
        fi
    done
    clear_state
    echo "EasyTier stopped; Leaf + HEV remain unchanged."
}

case "${1:-status}" in
    start|stop|restart)
        mkdir -p /var/lock
        exec 9>"$LOCK"
        flock -x 9 || exit 1
        ;;
esac
case "${1:-status}" in
    start) start ;;
    stop) stop ;;
    restart) check && stop && start ;;
    status) status ;;
    check) check ;;
    logs)
        if [ ! -f "$LOG" ]; then echo "No log yet: $LOG"; exit 0; fi
        if [ "${2:-}" = -f ]; then tail -n 80 -f "$LOG"; else tail -n 80 "$LOG"; fi
        ;;
    *) echo "Usage: $0 {start|stop|restart|status|check|logs [-f]}"; exit 2 ;;
esac
