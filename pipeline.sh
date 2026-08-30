#!/bin/bash
#
# pipeline.sh — recon chain: subfinder -> dnsx -> httpx -> nuclei
#
# Designed to be launched by scan.sh as SCANNER_CMD, e.g. in config.env:
#   SCANNER_CMD=(/root/scanner/pipeline.sh)
#
# scan.sh handles: background execution, PID tracking, logging,
# start/stop/status, and Discord/Telegram notification on exit.
# This script handles: the actual recon chain, status-code filtering,
# and keyword matching. It prints a "SUMMARY:" block to stdout that
# scan.sh's worker forwards as its own notification.
#
# All tunables (status codes, keyword lists) are defaults defined in
# this file below — nothing is read from config.env. Edit the
# variables in the CONFIG section to change behavior.

set -u

domain="${1:-}"

if [[ -z "$domain" ]]; then
    echo "Usage: $0 <domain>" >&2
    exit 1
fi

# ============================================================
# CONFIG — edit these to change status codes / keyword lists
# ============================================================

# HTTP status codes worth reporting.
# 200: live. 301/302/307/308: redirects. 401: exists, needs auth
# (strong signal). 403: exists, blocked. 405: exists, wrong verb
# (common on API routes). 404 deliberately excluded — dead link.
STATUS_CODES="200,301,302,307,308,401,403,405"

# Keyword categories. Each is an ERE alternation used with grep -Ei.
# Set any of these to an empty string "" to disable that category.

KEYWORDS_AUTH="admin|administrator|login|signin|sign-in|signup|sign-up|register|dashboard|portal|panel|cpanel|console"

KEYWORDS_API="api|apikey|api-key|api_key|secret|token|auth|oauth|credentials|key|access-key|private-key"

KEYWORDS_USER="profile|settings|account|user|users|config|configuration|preferences"

KEYWORDS_BACKUP="backup|backups|\.env|\.git|\.sql|dump|db|database|old|bak|tmp|temp"

KEYWORDS_DEV="dev|staging|test|uat|internal|debug|beta|sandbox"

KEYWORDS_CLOUD="s3|bucket|storage|cloud|aws"

KEYWORDS_MISC="upload|uploads|download|export|import|logs|log|monitor|health|status|actuator|swagger|graphql"

# ============================================================
# SETUP
# ============================================================

WORKDIR="$(pwd)"
SUBS_FILE="$WORKDIR/subdomains.txt"
RESOLVED_FILE="$WORKDIR/resolved.txt"
HTTPX_JSON="$WORKDIR/httpx_output.json"
NUCLEI_OUT="$WORKDIR/nuclei_output.txt"
KEYWORD_MATCHES="$WORKDIR/keyword_matches.txt"

# Build the combined keyword regex from enabled categories only.
build_keyword_regex() {
    local parts=()
    [[ -n "$KEYWORDS_AUTH" ]] && parts+=("$KEYWORDS_AUTH")
    [[ -n "$KEYWORDS_API" ]] && parts+=("$KEYWORDS_API")
    [[ -n "$KEYWORDS_USER" ]] && parts+=("$KEYWORDS_USER")
    [[ -n "$KEYWORDS_BACKUP" ]] && parts+=("$KEYWORDS_BACKUP")
    [[ -n "$KEYWORDS_DEV" ]] && parts+=("$KEYWORDS_DEV")
    [[ -n "$KEYWORDS_CLOUD" ]] && parts+=("$KEYWORDS_CLOUD")
    [[ -n "$KEYWORDS_MISC" ]] && parts+=("$KEYWORDS_MISC")

    local IFS='|'
    echo "${parts[*]}"
}

KEYWORD_REGEX="$(build_keyword_regex)"

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "⚠️  '$tool' not found — skipping stage that depends on it." >&2
        return 1
    fi
    return 0
}

# ============================================================
# STAGE 1 — subfinder: passive subdomain enumeration
# ============================================================

echo "== Stage 1: subfinder =="

if require_tool subfinder; then
    subfinder -d "$domain" -silent > "$SUBS_FILE" 2>/dev/null
else
    # No subfinder available — fall back to scanning the bare domain
    # so the rest of the pipeline still runs.
    echo "$domain" > "$SUBS_FILE"
fi

sub_count=$(wc -l < "$SUBS_FILE" 2>/dev/null || echo 0)
echo "Subdomains found: $sub_count"

# ============================================================
# STAGE 2 — dnsx: resolve subdomains, drop dead DNS entries
# ============================================================

echo "== Stage 2: dnsx =="

if require_tool dnsx; then
    dnsx -silent -l "$SUBS_FILE" > "$RESOLVED_FILE" 2>/dev/null
else
    cp "$SUBS_FILE" "$RESOLVED_FILE"
fi

resolved_count=$(wc -l < "$RESOLVED_FILE" 2>/dev/null || echo 0)
echo "Resolved hosts: $resolved_count"

# ============================================================
# STAGE 3 — httpx: live host check, filtered by STATUS_CODES
# ============================================================

echo "== Stage 3: httpx (status codes: $STATUS_CODES) =="

if require_tool httpx; then
    httpx -silent -l "$RESOLVED_FILE" -mc "$STATUS_CODES" -title -status-code -json \
        > "$HTTPX_JSON" 2>/dev/null
else
    : > "$HTTPX_JSON"
    echo "⚠️  httpx unavailable — no live-host data collected." >&2
fi

live_count=$(wc -l < "$HTTPX_JSON" 2>/dev/null || echo 0)
echo "Live hosts matching status codes: $live_count"

# ============================================================
# STAGE 4 — keyword matching against URLs + page titles
# ============================================================

echo "== Stage 4: keyword matching =="

: > "$KEYWORD_MATCHES"

if [[ -s "$HTTPX_JSON" ]] && [[ -n "$KEYWORD_REGEX" ]] && require_tool jq; then
    # \b word boundaries prevent false positives from keywords that are
    # substrings of the domain itself (e.g. "test" inside "testcorp.example"
    # would otherwise match KEYWORDS_DEV on every subdomain of that domain).
    jq -r '(.url // "") + " [" + (.status_code|tostring) + "] " + (.title // "")' \
        "$HTTPX_JSON" 2>/dev/null \
        | grep -Ei "\b($KEYWORD_REGEX)\b" \
        > "$KEYWORD_MATCHES" || true
fi

keyword_count=$(wc -l < "$KEYWORD_MATCHES" 2>/dev/null || echo 0)
echo "Keyword matches: $keyword_count"

# ============================================================
# STAGE 5 — nuclei: template-based vuln scan against live hosts
# ============================================================

echo "== Stage 5: nuclei =="

if [[ -s "$HTTPX_JSON" ]] && require_tool nuclei && require_tool jq; then
    jq -r '.url // empty' "$HTTPX_JSON" 2>/dev/null \
        | nuclei -silent -o "$NUCLEI_OUT" 2>/dev/null
else
    : > "$NUCLEI_OUT"
    echo "⚠️  nuclei stage skipped (nuclei/jq unavailable or no live hosts)." >&2
fi

nuclei_count=$(wc -l < "$NUCLEI_OUT" 2>/dev/null || echo 0)
echo "Nuclei findings: $nuclei_count"

# ============================================================
# SUMMARY — scan.sh's worker greps for this block and forwards it
# as a Discord/Telegram notification.
# ============================================================

echo
echo "SUMMARY:"
echo "Target: $domain"
echo "Subdomains: $sub_count | Resolved: $resolved_count | Live ($STATUS_CODES): $live_count"
echo "Keyword matches: $keyword_count | Nuclei findings: $nuclei_count"

if [[ "$keyword_count" -gt 0 ]]; then
    echo
    echo "Keyword hits:"
    head -n 20 "$KEYWORD_MATCHES"
    if [[ "$keyword_count" -gt 20 ]]; then
        echo "... ($((keyword_count - 20)) more, see keyword_matches.txt)"
    fi
fi

if [[ "$nuclei_count" -gt 0 ]]; then
    echo
    echo "Nuclei hits:"
    head -n 20 "$NUCLEI_OUT"
    if [[ "$nuclei_count" -gt 20 ]]; then
        echo "... ($((nuclei_count - 20)) more, see nuclei_output.txt)"
    fi
fi

echo "END_SUMMARY"

exit 0