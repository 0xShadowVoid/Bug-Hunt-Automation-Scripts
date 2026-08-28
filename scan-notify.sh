#!/bin/bash

set -u

# ============================================================
# CONFIG
# ============================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$BASE_DIR/config.env"
SCAN_ROOT="$BASE_DIR/scans"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

mkdir -p "$SCAN_ROOT"


# ============================================================
# HELPERS
# ============================================================

usage() {
    cat <<EOF

Usage:

  Start scan:
    $0 <domain>

  Check status:
    $0 status <domain>

  Follow logs:
    $0 logs <domain>

  Stop scan:
    $0 stop <domain>

  List running scans:
    $0 list

  Show help:
    $0 help

EOF
}


safe_target() {
    echo "$1" | tr '/: ' '___'
}


send_discord() {
    local message="$1"

    [[ -z "$DISCORD_WEBHOOK_URL" ]] && return 0

    curl -fsS \
        -H "Content-Type: application/json" \
        --data-urlencode "payload_json={\"content\":\"$message\"}" \
        "$DISCORD_WEBHOOK_URL" \
        >/dev/null 2>&1 || true
}


send_telegram() {
    local message="$1"

    [[ -z "$TELEGRAM_BOT_TOKEN" ]] && return 0
    [[ -z "$TELEGRAM_CHAT_ID" ]] && return 0

    curl -fsS \
        -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        >/dev/null 2>&1 || true
}


notify() {
    local message="$1"

    send_discord "$message"
    send_telegram "$message"
}


is_running() {
    local pid_file="$1"

    [[ -f "$pid_file" ]] || return 1

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null
}


# ============================================================
# WORKER
# ============================================================

run_scan() {

    local domain="$1"
    local target_dir="$2"

    local log_file="$target_dir/scan.log"
    local pid_file="$target_dir/scan.pid"
    local done_file="$target_dir/scan.done"

    mkdir -p "$target_dir"

    # Save PID
    echo "$$" > "$pid_file"

    # Cleanup PID when worker exits
    cleanup() {
        rm -f "$pid_file"
    }

    trap cleanup EXIT

    local start_epoch
    start_epoch="$(date +%s)"

    local start_time
    start_time="$(date '+%Y-%m-%d %H:%M:%S')"

    {
        echo
        echo "============================================================"
        echo "SCAN STARTED"
        echo "Target : $domain"
        echo "PID    : $$"
        echo "Started: $start_time"
        echo "============================================================"
        echo
    } >> "$log_file"

    notify "🚀 Scan started

Target: $domain
Time: $start_time
PID: $$"

    # Run scan inside target directory
    cd "$target_dir" || exit 1

    # Run Pegpon
    pegpon -d "$domain" >> "$log_file" 2>&1
    local exit_code=$?

    local end_epoch
    end_epoch="$(date +%s)"

    local end_time
    end_time="$(date '+%Y-%m-%d %H:%M:%S')"

    local duration=$((end_epoch - start_epoch))

    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    local duration_text
    duration_text=$(printf "%02dh %02dm %02ds" \
        "$hours" "$minutes" "$seconds")

    if [[ "$exit_code" -eq 0 ]]; then

        echo "============================================================" >> "$log_file"
        echo "SCAN FINISHED SUCCESSFULLY" >> "$log_file"
        echo "Finished : $end_time" >> "$log_file"
        echo "Duration : $duration_text" >> "$log_file"
        echo "Exit code: 0" >> "$log_file"
        echo "============================================================" >> "$log_file"

        cat > "$done_file" <<EOF
status=success
target=$domain
started=$start_time
finished=$end_time
duration=$duration_text
exit_code=0
EOF

        notify "✅ Scan finished successfully

Target: $domain
Duration: $duration_text
Exit code: 0"

    else

        echo "============================================================" >> "$log_file"
        echo "SCAN FAILED" >> "$log_file"
        echo "Finished : $end_time" >> "$log_file"
        echo "Duration : $duration_text" >> "$log_file"
        echo "Exit code: $exit_code" >> "$log_file"
        echo "============================================================" >> "$log_file"

        cat > "$done_file" <<EOF
status=failed
target=$domain
started=$start_time
finished=$end_time
duration=$duration_text
exit_code=$exit_code
EOF

        notify "❌ Scan failed

Target: $domain
Duration: $duration_text
Exit code: $exit_code"

    fi

    return "$exit_code"
}


# ============================================================
# START
# ============================================================

start_scan() {

    local domain="$1"

    if [[ -z "$domain" ]]; then
        echo "Error: domain is required."
        exit 1
    fi

    local target
    target="$(safe_target "$domain")"

    local target_dir="$SCAN_ROOT/$target"
    local pid_file="$target_dir/scan.pid"

    mkdir -p "$target_dir"

    # Already running?
    if is_running "$pid_file"; then
        local pid
        pid="$(cat "$pid_file")"

        echo "Scan already running."
        echo "Target: $domain"
        echo "PID   : $pid"
        echo "Logs  : $target_dir/scan.log"

        exit 0
    fi

    # Remove stale PID
    rm -f "$pid_file"

    # Remove previous done marker
    rm -f "$target_dir/scan.done"

    echo "Starting scan..."
    echo "Target: $domain"

    # Start detached worker
    nohup "$0" --worker "$domain" "$target_dir" \
        >/dev/null 2>&1 &

    # Give the worker a moment to create PID
    sleep 0.5

    if is_running "$pid_file"; then

        local pid
        pid="$(cat "$pid_file")"

        echo
        echo "✅ Scan started successfully."
        echo
        echo "Target : $domain"
        echo "PID    : $pid"
        echo "Log    : $target_dir/scan.log"
        echo
        echo "Check:"
        echo "  $0 status $domain"
        echo
        echo "Live log:"
        echo "  $0 logs $domain"

    else

        echo "❌ Failed to start scan."
        echo "Check:"
        echo "  $target_dir/scan.log"

        exit 1
    fi
}


# ============================================================
# STATUS
# ============================================================

status_scan() {

    local domain="$1"
    local target
    target="$(safe_target "$domain")"

    local target_dir="$SCAN_ROOT/$target"
    local pid_file="$target_dir/scan.pid"
    local done_file="$target_dir/scan.done"

    echo "======================================"
    echo "Target: $domain"
    echo "======================================"

    if is_running "$pid_file"; then

        local pid
        pid="$(cat "$pid_file")"

        echo "Status: RUNNING"
        echo "PID   : $pid"
        echo "Log   : $target_dir/scan.log"

    else

        echo "Status: NOT RUNNING"

        if [[ -f "$done_file" ]]; then
            echo
            cat "$done_file"
        fi
    fi

    echo
}


# ============================================================
# LOGS
# ============================================================

logs_scan() {

    local domain="$1"

    local target
    target="$(safe_target "$domain")"

    local log_file="$SCAN_ROOT/$target/scan.log"

    if [[ ! -f "$log_file" ]]; then
        echo "No log file found for $domain"
        exit 1
    fi

    echo "Following logs for $domain..."
    echo "Press Ctrl+C to stop viewing logs."
    echo

    tail -f "$log_file"
}


# ============================================================
# STOP
# ============================================================

stop_scan() {

    local domain="$1"

    local target
    target="$(safe_target "$domain")"

    local target_dir="$SCAN_ROOT/$target"
    local pid_file="$target_dir/scan.pid"

    if ! is_running "$pid_file"; then
        echo "No running scan found for $domain."
        rm -f "$pid_file"
        exit 0
    fi

    local pid
    pid="$(cat "$pid_file")"

    echo "Stopping scan..."
    echo "Target: $domain"
    echo "PID   : $pid"

    kill "$pid" 2>/dev/null || true

    # Wait briefly
    for _ in {1..10}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "Process did not stop gracefully."
        echo "Sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$pid_file"

    notify "🛑 Scan stopped

Target: $domain
PID: $pid"

    echo "✅ Stopped."
}


# ============================================================
# LIST
# ============================================================

list_scans() {

    echo "Running scans:"
    echo

    local found=0

    for dir in "$SCAN_ROOT"/*; do

        [[ -d "$dir" ]] || continue

        local pid_file="$dir/scan.pid"

        if is_running "$pid_file"; then

            found=1

            local target
            target="$(basename "$dir")"

            local pid
            pid="$(cat "$pid_file")"

            printf "  %-35s PID: %s\n" "$target" "$pid"
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        echo "  No running scans."
    fi
}


# ============================================================
# MAIN
# ============================================================

case "${1:-}" in

    --worker)
        run_scan "$2" "$3"
        exit $?
        ;;

    status)
        [[ -n "${2:-}" ]] || {
            echo "Usage: $0 status <domain>"
            exit 1
        }

        status_scan "$2"
        ;;

    logs)
        [[ -n "${2:-}" ]] || {
            echo "Usage: $0 logs <domain>"
            exit 1
        }

        logs_scan "$2"
        ;;

    stop)
        [[ -n "${2:-}" ]] || {
            echo "Usage: $0 stop <domain>"
            exit 1
        }

        stop_scan "$2"
        ;;

    list)
        list_scans
        ;;

    help|-h|--help)
        usage
        ;;

    "")
        usage
        exit 1
        ;;

    *)
        start_scan "$1"
        ;;

esac