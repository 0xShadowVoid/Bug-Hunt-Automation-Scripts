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

# Set to "true" in config.env to zip the target's result directory and
# send it to Discord/Telegram after each scan finishes (success or fail).
RESULTS_ZIP="${RESULTS_ZIP:-false}"

# SCANNER_CMD must be set as an array in config.env, e.g.:
#   SCANNER_CMD=(pegpon -d)
#   SCANNER_CMD=(nuclei -target)
#   SCANNER_CMD=(nmap -sV)
# The target domain is appended as the final argument at run time.
if [[ -z "${SCANNER_CMD+set}" ]] || [[ ${#SCANNER_CMD[@]} -eq 0 ]]; then
    SCANNER_CMD=(pegpon -d)
fi

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

Config (config.env):

  SCANNER_CMD=(pegpon -d)        # array; target is appended as last arg
  DISCORD_WEBHOOK_URL="..."      # optional
  TELEGRAM_BOT_TOKEN="..."       # optional
  TELEGRAM_CHAT_ID="..."         # optional
  RESULTS_ZIP="true"             # optional; zips target dir, sends as
                                  # file to Discord/Telegram after each
                                  # scan. Requires 'zip' installed.
                                  # Skips upload (text notice instead)
                                  # if zip exceeds 8MB (Discord) or
                                  # 50MB (Telegram).

EOF
}


# Validate domain-like input. Restrict to characters valid in a hostname
# to prevent path traversal, argument injection, and shell metacharacter
# abuse in any downstream scanner command.
validate_domain() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        echo "Error: target is required." >&2
        exit 1
    fi

    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,251}[a-zA-Z0-9])?$ ]]; then
        echo "Error: invalid target format: '$domain'" >&2
        echo "Allowed: letters, digits, dots, hyphens, underscores." >&2
        exit 1
    fi

    if [[ "$domain" == *".."* ]]; then
        echo "Error: invalid target format: '$domain'" >&2
        exit 1
    fi
}


safe_target() {
    echo "$1" | tr '/: ' '___'
}


# Minimal JSON string escaping: backslash, double quote, control chars.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}


send_discord() {
    local message="$1"

    [[ -z "$DISCORD_WEBHOOK_URL" ]] && return 0

    local escaped
    escaped="$(json_escape "$message")"

    curl -fsS \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"$escaped\"}" \
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


# Discord hard-caps webhook uploads at 8MB (higher with server boosts,
# not assumed here). Telegram bot API caps at 50MB. Skip upload and
# fall back to a text notice if the zip exceeds either limit.
DISCORD_MAX_BYTES=8000000
TELEGRAM_MAX_BYTES=50000000

send_discord_file() {
    local filepath="$1"
    local caption="$2"

    [[ -z "$DISCORD_WEBHOOK_URL" ]] && return 0
    [[ -f "$filepath" ]] || return 0

    local size
    size="$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)"

    if (( size > DISCORD_MAX_BYTES )); then
        send_discord "$caption

⚠️ Results zip is $((size / 1000000))MB — exceeds Discord's 8MB webhook limit. Not uploaded. Retrieve it manually from the VPS."
        return 0
    fi

    curl -fsS \
        -F "payload_json={\"content\":\"$(json_escape "$caption")\"}" \
        -F "file1=@${filepath}" \
        "$DISCORD_WEBHOOK_URL" \
        >/dev/null 2>&1 || true
}

send_telegram_file() {
    local filepath="$1"
    local caption="$2"

    [[ -z "$TELEGRAM_BOT_TOKEN" ]] && return 0
    [[ -z "$TELEGRAM_CHAT_ID" ]] && return 0
    [[ -f "$filepath" ]] || return 0

    local size
    size="$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)"

    if (( size > TELEGRAM_MAX_BYTES )); then
        send_telegram "$caption

⚠️ Results zip is $((size / 1000000))MB — exceeds Telegram's 50MB bot upload limit. Not uploaded. Retrieve it manually from the VPS."
        return 0
    fi

    curl -fsS \
        -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "caption=${caption}" \
        -F "document=@${filepath}" \
        >/dev/null 2>&1 || true
}

notify_file() {
    local filepath="$1"
    local caption="$2"

    send_discord_file "$filepath" "$caption"
    send_telegram_file "$filepath" "$caption"
}


# Zips the target directory (log, done marker, and any output files the
# scanner wrote there — the worker cd's into target_dir before running
# the scanner, so tool output typically lands alongside scan.log).
# Returns the zip path on stdout, or nothing if zip is unavailable/fails.
make_results_zip() {
    local target_dir="$1"
    local target_name="$2"

    command -v zip >/dev/null 2>&1 || return 0

    local zip_path="${target_dir}/${target_name}_results.zip"
    rm -f "$zip_path"

    ( cd "$target_dir" && zip -rq "$zip_path" . -x "*.lock" -x "*.pid" ) \
        || return 0

    [[ -f "$zip_path" ]] && echo "$zip_path"
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

    local target_name
    target_name="$(basename "$target_dir")"

    local log_file="$target_dir/scan.log"
    local pid_file="$target_dir/scan.pid"
    local done_file="$target_dir/scan.done"
    local lock_file="$target_dir/.lock"

    mkdir -p "$target_dir"

    # Hold the lock for the lifetime of the worker so a concurrent
    # `start_scan` cannot race past the is_running check.
    exec 200>"$lock_file"
    if ! flock -n 200; then
        echo "Error: could not acquire lock for $domain (already running?)" >&2
        exit 1
    fi

    echo "$$" > "$pid_file"

    cleanup() {
        rm -f "$pid_file"
        flock -u 200 2>/dev/null || true
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
        echo "Command: ${SCANNER_CMD[*]} $domain"
        echo "PID    : $$"
        echo "Started: $start_time"
        echo "============================================================"
        echo
    } >> "$log_file"

    notify "🚀 Scan started

Target: $domain
Scanner: ${SCANNER_CMD[0]}
Time: $start_time
PID: $$"

    cd "$target_dir" || exit 1

    # Run the configured scanner. Array expansion avoids word-splitting
    # and quoting issues regardless of how many args SCANNER_CMD has.
    "${SCANNER_CMD[@]}" "$domain" >> "$log_file" 2>&1
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

        {
            echo "============================================================"
            echo "SCAN FINISHED SUCCESSFULLY"
            echo "Finished : $end_time"
            echo "Duration : $duration_text"
            echo "Exit code: 0"
            echo "============================================================"
        } >> "$log_file"

        cat > "$done_file" <<EOF
status=success
target=$domain
scanner=${SCANNER_CMD[0]}
started=$start_time
finished=$end_time
duration=$duration_text
exit_code=0
EOF

        notify "✅ Scan finished successfully

Target: $domain
Duration: $duration_text
Exit code: 0"

        if [[ "$RESULTS_ZIP" == "true" ]]; then
            local zip_path
            zip_path="$(make_results_zip "$target_dir" "$target_name")"
            if [[ -n "$zip_path" ]]; then
                notify_file "$zip_path" "📦 Results for $domain
Scanner: ${SCANNER_CMD[0]}
Duration: $duration_text"
            fi
        fi

    else

        {
            echo "============================================================"
            echo "SCAN FAILED"
            echo "Finished : $end_time"
            echo "Duration : $duration_text"
            echo "Exit code: $exit_code"
            echo "============================================================"
        } >> "$log_file"

        cat > "$done_file" <<EOF
status=failed
target=$domain
scanner=${SCANNER_CMD[0]}
started=$start_time
finished=$end_time
duration=$duration_text
exit_code=$exit_code
EOF

        notify "❌ Scan failed

Target: $domain
Duration: $duration_text
Exit code: $exit_code"

        if [[ "$RESULTS_ZIP" == "true" ]]; then
            local zip_path
            zip_path="$(make_results_zip "$target_dir" "$target_name")"
            if [[ -n "$zip_path" ]]; then
                notify_file "$zip_path" "📦 Log/partial results for $domain (failed)
Scanner: ${SCANNER_CMD[0]}
Exit code: $exit_code"
            fi
        fi

    fi

    # If the scanner printed a "SUMMARY:" block (e.g. pipeline.sh's
    # recon summary), forward it as its own notification — separate
    # from the plain success/fail message above, since it carries
    # actual findings rather than just process status.
    if grep -q "^SUMMARY:" "$log_file" 2>/dev/null; then
        local summary_block
        summary_block="$(awk '/^END_SUMMARY$/{exit} /^SUMMARY:/{flag=1} flag' "$log_file")"
        notify "🎯 Findings for $domain

$summary_block"
    fi

    return "$exit_code"
}


# ============================================================
# START
# ============================================================

start_scan() {

    local domain="$1"

    validate_domain "$domain"

    local target
    target="$(safe_target "$domain")"

    local target_dir="$SCAN_ROOT/$target"
    local pid_file="$target_dir/scan.pid"
    local lock_file="$target_dir/.lock"

    mkdir -p "$target_dir"

    # Atomic-ish guard: try to take the lock non-blocking here too, so a
    # second `start_scan` invoked at nearly the same instant fails fast
    # instead of racing the worker's own flock.
    exec 201>"$lock_file"
    if ! flock -n 201; then
        echo "Scan already running or starting for $domain."
        if is_running "$pid_file"; then
            echo "PID : $(cat "$pid_file")"
        fi
        echo "Logs: $target_dir/scan.log"
        exit 0
    fi
    flock -u 201

    if is_running "$pid_file"; then
        local pid
        pid="$(cat "$pid_file")"

        echo "Scan already running."
        echo "Target: $domain"
        echo "PID   : $pid"
        echo "Logs  : $target_dir/scan.log"

        exit 0
    fi

    rm -f "$pid_file"
    rm -f "$target_dir/scan.done"

    echo "Starting scan..."
    echo "Target : $domain"
    echo "Scanner: ${SCANNER_CMD[*]}"

    nohup "$0" --worker "$domain" "$target_dir" \
        >/dev/null 2>&1 &

    # Poll for PID file instead of a fixed sleep — handles slow-starting
    # scanners without an arbitrary race window. Also stop early if a
    # done_file appears: a scanner fast enough to finish before we ever
    # observe it "running" (e.g. all recon tools missing, near-instant
    # exit) still counts as started successfully, not failed.
    local target_done_file="$target_dir/scan.done"
    local waited=0
    while (( waited < 50 )); do
        if is_running "$pid_file"; then
            break
        fi
        if [[ -f "$target_done_file" ]]; then
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

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

    elif [[ -f "$target_done_file" ]]; then

        echo
        echo "✅ Scan started and finished already (very fast scanner)."
        echo
        echo "Target : $domain"
        echo "Log    : $target_dir/scan.log"
        echo
        echo "Check:"
        echo "  $0 status $domain"

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
    validate_domain "$domain"

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
    validate_domain "$domain"

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
    validate_domain "$domain"

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

    local waited=0
    while (( waited < 10 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
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

    shopt -s nullglob
    for dir in "$SCAN_ROOT"/*/; do

        [[ -d "$dir" ]] || continue

        local pid_file="${dir}scan.pid"

        if is_running "$pid_file"; then

            found=1

            local target
            target="$(basename "$dir")"

            local pid
            pid="$(cat "$pid_file")"

            printf "  %-35s PID: %s\n" "$target" "$pid"
        fi
    done
    shopt -u nullglob

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