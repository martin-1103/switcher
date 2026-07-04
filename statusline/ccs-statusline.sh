#!/usr/bin/env bash
# Statusline script for Claude Code — shows the active account and 5-hour usage,
# and keeps the usage cache warm for the rate-limit auto-switch hook.
#
# Claude Code invokes this on each render with session JSON on stdin and uses the
# single line we print as the status line. To stay responsive we never block the
# render on the network: a TTL-aware cache refresh is kicked off in the
# background and we print whatever is currently cached.
#
# Design: fail open / never error — a broken statusline must not disrupt the UI.

set -uo pipefail

# Consume stdin (Claude Code passes session JSON; we don't need it).
# shellcheck disable=SC2034
INPUT=$(cat 2>/dev/null || true)

HOME="${HOME:-/root}"
CACHE_FILE="/tmp/claude-usage-cache.json"
SEQ="$HOME/.claude-switch-backup/sequence.json"

# Resolve ccs: 1) CCS_PATH env (set by statusline-setup), 2) sibling of this
# script's dir, 3) PATH, 4) common locations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"
CCS="${CCS_PATH:-}"
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="${SCRIPT_DIR}/../ccswitch.sh"
[[ -x "$CCS" ]] || CCS=$(command -v ccs 2>/dev/null || echo "")
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="/usr/local/bin/ccs"

# Kick a TTL-aware refresh + reclaim check in the background. The hook only
# fires on a tool call, so an idle session (Claude Code open, no tool calls)
# would never reclaim an account whose window has reset. The statusline is
# invoked periodically by Claude Code's own render loop regardless of tool
# activity, so piggyback the reclaim check here instead of adding a timer.
#
# Claude Code re-renders the statusline every few seconds with no coupling to
# how long our background call takes. Without a throttle, a slow API call
# (e.g. curl hanging on a 429) means each render spawns another rate-check
# before the last one even finished, piling up processes that all just skip
# on the switch-lock anyway. Only spawn once per RATE_CHECK_MIN_INTERVAL.
RATE_CHECK_MIN_INTERVAL=10
RATE_CHECK_STAMP="/tmp/claude-ratecheck-last-spawn"
last_spawn=$(stat -c %Y "$RATE_CHECK_STAMP" 2>/dev/null || echo 0)
now_ts=$(date +%s 2>/dev/null || echo 0)
if [[ -x "$CCS" && $(( now_ts - last_spawn )) -ge "$RATE_CHECK_MIN_INTERVAL" ]]; then
    touch "$RATE_CHECK_STAMP" 2>/dev/null || true
    ( CCS_SILENT=1 "$CCS" rate-check --auto-switch >/dev/null 2>&1 & ) 2>/dev/null || true
fi

# Print from whatever is currently cached.
if [[ -f "$CACHE_FILE" ]]; then
    acct=$(jq -r '.active_account // "?"' "$CACHE_FILE" 2>/dev/null || echo "?")
    util=$(jq -r '.five_hour.utilization // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
    util_int=$(printf "%.0f" "$util" 2>/dev/null || echo "0")
    weekly=$(jq -r '.seven_day.utilization // empty' "$CACHE_FILE" 2>/dev/null || true)
    weekly_int=""
    [[ -n "$weekly" ]] && weekly_int=$(printf "%.0f" "$weekly" 2>/dev/null || echo "")
    limit=$(jq -r '[(.limits // [])[] | select((.is_active // false) == true) | .percent? | select(type == "number")] | max // empty' "$CACHE_FILE" 2>/dev/null || true)
    limit_int=""
    [[ -n "$limit" ]] && limit_int=$(printf "%.0f" "$limit" 2>/dev/null || echo "")
    eval_int="$util_int"
    if [[ -n "$limit_int" ]]; then
        eval_int="$limit_int"
    elif [[ -n "$weekly_int" && "$weekly_int" -gt "$eval_int" ]]; then
        eval_int="$weekly_int"
    fi

    # Threshold marker: append "(!)" when at/over the configured threshold.
    threshold=80
    if [[ -f "$SEQ" ]]; then
        cfg=$(jq -r '.rateLimit.threshold // empty' "$SEQ" 2>/dev/null || true)
        [[ -n "$cfg" ]] && threshold="$cfg"
    fi
    marker=""
    [[ "$eval_int" -ge "$threshold" ]] && marker=" (!)"

    if [[ -n "$limit_int" ]]; then
        printf 'ccs %s · use %s%% · 5h %s%% · 7d %s%%%s\n' "$acct" "$eval_int" "$util_int" "${weekly_int:-0}" "$marker"
    elif [[ -n "$weekly_int" ]]; then
        printf 'ccs %s · use %s%% · 5h %s%% · 7d %s%%%s\n' "$acct" "$eval_int" "$util_int" "$weekly_int" "$marker"
    else
        printf 'ccs %s · use %s%%%s\n' "$acct" "$eval_int" "$marker"
    fi
else
    printf 'ccs (no usage data yet)\n'
fi

exit 0
