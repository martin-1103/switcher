#!/usr/bin/env bash
# PreToolUse hook for Claude Code — auto-switch on rate limit detection
# This script is called by Claude Code before each tool invocation.
#
# It takes a fast path when the usage cache is fresh and under threshold, and
# otherwise delegates to `ccs rate-check`, which refreshes the cache on demand
# (TTL-aware). This is what makes headless `claude -p` runs work: there's no
# statusline to keep the cache warm, so the hook must trigger a refresh itself.
#
# Design: fail open on ALL errors — never block the user due to our bugs.

set -uo pipefail  # No -e: we handle errors manually

# Claude/agent hooks can run with HOME unset; ccs state lives under root on this host.
if [[ -z "${HOME:-}" ]]; then
    if [[ "${USER:-}" == "root" || $(id -u) -eq 0 ]]; then
        export HOME=/root
    else
        export HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    fi
fi

# Consume stdin (required by hook protocol)
# shellcheck disable=SC2034  # INPUT consumed per hook protocol, not used in script
INPUT=$(cat)

HOOK_LOG_FILE="/tmp/ccs-rate-hook.log"
THRESHOLD=80
CACHE_TTL=60

# Cache filename must mirror ccswitch.sh's usage_cache_file() exactly — one
# cache file per account, so a stale/failed fetch for one account can never
# be read back as another account's usage after a switch.
usage_cache_file() {
    local email="$1"
    local safe
    safe=$(echo "$email" | tr -c 'A-Za-z0-9._-' '_')
    echo "/tmp/claude-usage-cache-${safe}.json"
}

hook_log() {
    local ts msg
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    msg="$1"
    printf '%s %s\n' "$ts" "$msg" >> "$HOOK_LOG_FILE" 2>/dev/null || true
    tail -n 200 "$HOOK_LOG_FILE" > "${HOOK_LOG_FILE}.tmp" 2>/dev/null && mv "${HOOK_LOG_FILE}.tmp" "$HOOK_LOG_FILE" 2>/dev/null || true
}

# Resolve ccs early so both the fast path and delegate path use the same binary.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCS="${CCS_PATH:-}"
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="${SCRIPT_DIR}/../ccswitch.sh"
[[ -x "$CCS" ]] || CCS=$(command -v ccs 2>/dev/null || echo "")
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="/usr/local/bin/ccs"

# Fail open: if anything goes wrong, allow the tool call
trap 'exit 0' ERR

# Read config: threshold, TTL, and the enabled toggle.
SEQ="$HOME/.claude-switch-backup/sequence.json"
if [[ -f "$SEQ" ]]; then
    cfg=$(jq -r '.rateLimit.threshold // empty' "$SEQ" 2>/dev/null || true)
    [[ -n "$cfg" ]] && THRESHOLD="$cfg"
    ttl=$(jq -r '.rateLimit.cacheTtl // empty' "$SEQ" 2>/dev/null || true)
    [[ -n "$ttl" ]] && CACHE_TTL="$ttl"
    enabled=$(jq -r '.rateLimit.enabled // true' "$SEQ" 2>/dev/null || echo "true")
    if [[ "$enabled" == "false" ]]; then
        hook_log "skip enabled=false"
        exit 0
    fi
fi

# Cache-only path: statusline owns usage refresh. Hook must not call rate-check,
# because invalid credentials make rate-check fail open and leave us stuck.
current_email=$("$CCS" status 2>/dev/null | sed -n 's/^Current account: //p' | head -n1)
CACHE_FILE=$(usage_cache_file "${current_email:-unknown}")

fast_ok=false
if [[ -f "$CACHE_FILE" ]]; then
    cached_at=$(jq -r '.cached_at // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
    [[ "$cached_at" =~ ^[0-9]+$ ]] || cached_at=0
    now=$(date +%s)
    age=$(( now - cached_at ))
    usage=$(jq -r '
        (
            [(.limits // [])[] | select((.is_active // false) == true) | .percent? | select(type == "number")] | max
        ) // (
            [(.five_hour.utilization // 0), (.seven_day.utilization // 0)] | max
        )
    ' "$CACHE_FILE" 2>/dev/null || echo "0")
    usage_int=$(printf "%.0f" "$usage" 2>/dev/null || echo "0")
    if [[ "$cached_at" -gt 0 && "$age" -lt "$CACHE_TTL" && "$usage_int" -lt "$THRESHOLD" ]]; then
        fast_ok=true
    fi
fi
if [[ "$fast_ok" == true ]]; then
    hook_log "fast-ok account=${current_email:-unknown} usage=${usage_int:-0} threshold=$THRESHOLD age=${age:-na}"
    exit 0
fi

if [[ ! -x "$CCS" ]]; then
    hook_log "skip ccs-missing"
    echo "ccs not found" >&2
    exit 0
fi

if [[ ! -f "$CACHE_FILE" ]]; then
    hook_log "skip cache-missing"
    exit 0
fi

if [[ "${cached_at:-0}" -le 0 || "${age:-999999}" -ge "$CACHE_TTL" ]]; then
    hook_log "skip cache-stale age=${age:-na} ttl=$CACHE_TTL"
    exit 0
fi

if [[ "${usage_int:-0}" -lt "$THRESHOLD" ]]; then
    hook_log "skip below-threshold usage=${usage_int:-0} threshold=$THRESHOLD"
    exit 0
fi

# Delegate the actual decision to rate-check --auto-switch, the single source
# of truth for switching. It holds the cross-process switch lock (serializes
# every session/hook/statusline on the host), skips candidates that are
# themselves over threshold, and emits the proper PreToolUse deny JSON when all
# accounts are limited. The old path called `ccs sw` — a blind round-robin that
# ignored threshold and bypassed all of that, so with every account limited the
# active account hopped one step per tool call, forever. rate-check owns its own
# lock, so no separate hook lock is needed here. The cache is already fresh and
# over-threshold at this point (checked above), so hook-mode reads it without a
# new API fetch.
hook_log "delegate rate-check account=${current_email:-unknown} usage=${usage_int:-0} threshold=$THRESHOLD"
result=$(CCS_SWITCH_REASON=auto CCS_SILENT=1 "$CCS" rate-check --auto-switch --hook-mode 2>>"$HOOK_LOG_FILE") || true

# rate-check emits the PreToolUse hook JSON (deny/allow) on stdout — pass it
# through to Claude Code verbatim so the deny actually blocks the tool call.
if [[ -n "$result" ]]; then
    printf '%s\n' "$result"
    hook_log "delegate-result $(printf '%s' "$result" | tr '\n' ' ' | cut -c1-180)"
else
    hook_log "delegate-empty"
fi
exit 0
