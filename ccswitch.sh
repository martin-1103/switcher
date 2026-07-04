#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Some hook/agent environments launch with HOME unset. Keep root installs usable under nounset.
if [[ -z "${HOME:-}" ]]; then
    if [[ "${USER:-}" == "root" || $(id -u) -eq 0 ]]; then
        export HOME=/root
    else
        export HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    fi
fi

# Version
readonly VERSION="0.3.2"

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly DIR_ACCOUNTS_FILE="$BACKUP_DIR/dir-accounts.json"
# Directory used as an exclusive lock for credential switches. mkdir is atomic on
# every POSIX filesystem (macOS has no flock), so it serializes concurrent switches.
readonly LOCK_DIR="$BACKUP_DIR/.switch.lock"
# How long a cached usage reading stays "fresh" (seconds). Past this the rate-limit
# check re-fetches from the usage API so headless (`claude -p`) runs aren't stale.
# Override per-install with .rateLimit.cacheTtl in sequence.json.
readonly DEFAULT_CACHE_TTL=60
readonly DEFAULT_COORD_LEASE_TTL=150
readonly DEFAULT_CURL_CONNECT_TIMEOUT=3
readonly DEFAULT_CURL_MAX_TIME=10

# Global flags (set during argument parsing)
DRY_RUN=false
RESTART_FLAG=""  # "", "restart", or "no-restart"
# Allow running as root. Defaults from CCSWITCH_ALLOW_ROOT (1/true to enable),
# can also be set with the --allow-root flag.
if [[ "${CCSWITCH_ALLOW_ROOT:-}" == "1" || "${CCSWITCH_ALLOW_ROOT:-}" == "true" ]]; then
    ALLOW_ROOT=true
else
    ALLOW_ROOT=false
fi

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi

    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi

    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi

    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi

    return 1
}

# Decide whether root execution should be blocked.
# Args: <euid> <allow_root (true|false)>
# Returns 0 (block) when running as root without an explicit opt-out, else 1.
should_block_root() {
    local euid="$1"
    local allow_root="$2"

    [[ "$euid" -eq 0 ]] || return 1            # not root -> never block
    [[ "$allow_root" == "true" ]] && return 1   # explicitly allowed via flag/env
    is_running_in_container && return 1         # containers are allowed by default
    return 0                                     # otherwise: block
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    local primary_valid=false
    local fallback_valid=false

    if [[ -f "$primary_config" ]] && jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
        primary_valid=true
    fi
    if [[ -f "$fallback_config" ]] && jq -e '.oauthAccount' "$fallback_config" >/dev/null 2>&1; then
        fallback_valid=true
    fi

    if [[ "$primary_valid" == true && "$fallback_valid" == true ]]; then
        local primary_mtime fallback_mtime
        primary_mtime=$(stat -c '%Y' "$primary_config" 2>/dev/null || stat -f '%m' "$primary_config" 2>/dev/null || echo 0)
        fallback_mtime=$(stat -c '%Y' "$fallback_config" 2>/dev/null || stat -f '%m' "$fallback_config" 2>/dev/null || echo 0)
        if [[ "$fallback_mtime" -gt "$primary_mtime" ]]; then
            echo "$fallback_config"
        else
            echo "$primary_config"
        fi
        return
    fi

    if [[ "$primary_valid" == true ]]; then
        echo "$primary_config"
        return
    fi

    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier resolution function
# Accepts: account number, email, or profile name
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Try email first
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
            return
        fi
        # Try profile name
        account_num=$(jq -r --arg profile "$identifier" '.accounts | to_entries[] | select(.value.profile == $profile) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
        else
            echo ""
        fi
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")

    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi

    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check dependencies
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: Required command 'jq' not found"
        echo "Install with: apt install jq (Linux) or brew install jq (macOS)"
        exit 1
    fi
}

coord_enabled() {
    [[ -f "$SEQUENCE_FILE" ]] || return 1
    [[ "$(jq -r '.coordination.mode // empty' "$SEQUENCE_FILE" 2>/dev/null || true)" != "" ]]
}

coord_config_value() {
    local path="$1"
    [[ -f "$SEQUENCE_FILE" ]] || return 1
    jq -r "$path // empty" "$SEQUENCE_FILE" 2>/dev/null
}

coord_mode() {
    coord_config_value '.coordination.mode'
}

coord_server_id() {
    local configured
    configured=$(coord_config_value '.coordination.serverId' 2>/dev/null || true)
    if [[ -n "$configured" ]]; then
        printf '%s\n' "$configured"
        return 0
    fi

    # No serverId configured: derive a stable, collision-resistant one.
    # Prefer public IP (unique per host even when hostnames collide), fall
    # back to hostname. Cache the result into config so this resolves once.
    local resolved
    local connect_timeout="${CCS_CURL_CONNECT_TIMEOUT:-$DEFAULT_CURL_CONNECT_TIMEOUT}"
    resolved=$(curl -sS --connect-timeout "$connect_timeout" --max-time "$connect_timeout" \
        "https://api.ipify.org" 2>/dev/null || true)
    if [[ ! "$resolved" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        resolved=$(hostname 2>/dev/null || echo "unknown-server")
    fi

    # Persist so subsequent publishes skip the network call. Best effort:
    # if the config isn't writable yet, still return the resolved value.
    if [[ -f "$SEQUENCE_FILE" ]]; then
        local updated
        updated=$(jq --arg sid "$resolved" '.coordination.serverId = $sid' "$SEQUENCE_FILE" 2>/dev/null || true)
        [[ -n "$updated" ]] && write_json "$SEQUENCE_FILE" "$updated" >/dev/null 2>&1 || true
    fi

    printf '%s\n' "$resolved"
}

coord_lease_ttl() {
    local ttl
    ttl=$(coord_config_value '.coordination.leaseTtlSeconds' 2>/dev/null || true)
    if [[ "$ttl" =~ ^[0-9]+$ ]] && [[ "$ttl" -gt 0 ]]; then
        printf '%s\n' "$ttl"
    else
        printf '%s\n' "$DEFAULT_COORD_LEASE_TTL"
    fi
}

coord_http_ready() {
    [[ "$(coord_mode)" == "http" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    local url token
    url=$(coord_config_value '.coordination.http.url')
    token=$(coord_config_value '.coordination.http.token')
    [[ -n "$url" && -n "$token" ]]
}

coord_http_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    coord_http_ready || return 1
    local url token response http_code payload
    url="$(coord_config_value '.coordination.http.url')$path"
    token=$(coord_config_value '.coordination.http.token')
    local connect_timeout="${CCS_CURL_CONNECT_TIMEOUT:-$DEFAULT_CURL_CONNECT_TIMEOUT}"
    local max_time="${CCS_CURL_MAX_TIME:-$DEFAULT_CURL_MAX_TIME}"

    if [[ -n "$body" ]]; then
        response=$(curl -sS -w "\n%{http_code}" \
            --connect-timeout "$connect_timeout" \
            --max-time "$max_time" \
            -X "$method" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            --data "$body" \
            "$url" 2>/dev/null) || return 1
    else
        response=$(curl -sS -w "\n%{http_code}" \
            --connect-timeout "$connect_timeout" \
            --max-time "$max_time" \
            -X "$method" \
            -H "Authorization: Bearer $token" \
            "$url" 2>/dev/null) || return 1
    fi

    http_code=$(echo "$response" | tail -n1)
    payload=$(echo "$response" | sed '$d')
    [[ "$http_code" =~ ^2 ]] || return 1
    printf '%s\n' "$payload"
}

coord_mysql_ready() {
    [[ "$(coord_mode)" == "mysql" ]] || return 1
    command -v mysql >/dev/null 2>&1 || return 1
    local host port db user password
    host=$(coord_config_value '.coordination.mysql.host')
    port=$(coord_config_value '.coordination.mysql.port')
    db=$(coord_config_value '.coordination.mysql.database')
    user=$(coord_config_value '.coordination.mysql.user')
    password=$(coord_config_value '.coordination.mysql.password')
    [[ -n "$host" && -n "$port" && -n "$db" && -n "$user" && -n "$password" ]]
}

coord_mysql_exec() {
    local sql="$1"
    coord_mysql_ready || return 1
    local host port db user password
    host=$(coord_config_value '.coordination.mysql.host')
    port=$(coord_config_value '.coordination.mysql.port')
    db=$(coord_config_value '.coordination.mysql.database')
    user=$(coord_config_value '.coordination.mysql.user')
    password=$(coord_config_value '.coordination.mysql.password')
    MYSQL_PWD="$password" mysql --batch --raw --skip-column-names \
        -h "$host" -P "$port" -u "$user" "$db" -e "$sql"
}

coord_mysql_exec_no_db() {
    local sql="$1"
    coord_mysql_ready || return 1
    local host port user password
    host=$(coord_config_value '.coordination.mysql.host')
    port=$(coord_config_value '.coordination.mysql.port')
    user=$(coord_config_value '.coordination.mysql.user')
    password=$(coord_config_value '.coordination.mysql.password')
    MYSQL_PWD="$password" mysql --batch --raw --skip-column-names \
        -h "$host" -P "$port" -u "$user" -e "$sql"
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

coord_ensure_schema() {
    coord_mysql_ready || return 1
    local db
    db=$(coord_config_value '.coordination.mysql.database')
    coord_mysql_exec_no_db "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null
    coord_mysql_exec "
CREATE TABLE IF NOT EXISTS account_leases (
    email VARCHAR(255) NOT NULL PRIMARY KEY,
    server_id VARCHAR(191) NOT NULL,
    account_number INT NULL,
    account_type VARCHAR(32) NULL,
    active_limit INT NULL,
    five_hour INT NULL,
    seven_day INT NULL,
    reset_at_5h VARCHAR(64) NULL,
    reset_at_7d VARCHAR(64) NULL,
    observed_at BIGINT NULL,
    lease_expires_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
" >/dev/null
}

coord_publish_account_state() {
    local account_num="$1"
    local email="$2"
    local account_type five_hour seven_day active_limit reset_at_5h reset_at_7d observed_at
    account_type=$(jq -r --arg num "$account_num" '.accounts[$num].accountType // ""' "$SEQUENCE_FILE" 2>/dev/null || true)
    five_hour=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.fiveHour // 0' "$SEQUENCE_FILE" 2>/dev/null || echo 0)
    seven_day=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.sevenDay // 0' "$SEQUENCE_FILE" 2>/dev/null || echo 0)
    active_limit=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.activeLimit // 0' "$SEQUENCE_FILE" 2>/dev/null || echo 0)
    reset_at_5h=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.resetAt5h // ""' "$SEQUENCE_FILE" 2>/dev/null || true)
    reset_at_7d=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.resetAt7d // ""' "$SEQUENCE_FILE" 2>/dev/null || true)
    observed_at=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.observedAt // 0' "$SEQUENCE_FILE" 2>/dev/null || echo 0)

    local now lease_expires server_id
    now=$(date +%s)
    lease_expires=$((now + $(coord_lease_ttl)))
    server_id=$(coord_server_id)

    if coord_http_ready; then
        local payload
        payload=$(jq -n \
            --arg email "$email" \
            --arg serverId "$server_id" \
            --argjson accountNumber "${account_num:-0}" \
            --arg accountType "$account_type" \
            --argjson activeLimit "${active_limit:-0}" \
            --argjson fiveHour "${five_hour:-0}" \
            --argjson sevenDay "${seven_day:-0}" \
            --arg resetAt5h "$reset_at_5h" \
            --arg resetAt7d "$reset_at_7d" \
            --argjson observedAt "${observed_at:-0}" \
            --argjson leaseTtlSeconds "$(coord_lease_ttl)" \
            '
            {
              email: $email,
              serverId: $serverId,
              accountNumber: $accountNumber,
              accountType: (if $accountType == "" then null else $accountType end),
              activeLimit: $activeLimit,
              fiveHour: $fiveHour,
              sevenDay: $sevenDay,
              resetAt5h: (if $resetAt5h == "" then null else $resetAt5h end),
              resetAt7d: (if $resetAt7d == "" then null else $resetAt7d end),
              observedAt: $observedAt,
              leaseTtlSeconds: $leaseTtlSeconds
            }
            ')
        coord_http_request POST "/v1/leases/claim" "$payload" >/dev/null 2>&1 || true
        return 0
    fi

    coord_mysql_ready || return 0
    coord_ensure_schema >/dev/null 2>&1 || return 0
    coord_mysql_exec "
REPLACE INTO account_leases (
    email, server_id, account_number, account_type,
    active_limit, five_hour, seven_day,
    reset_at_5h, reset_at_7d, observed_at,
    lease_expires_at, updated_at
) VALUES (
    '$(sql_escape "$email")',
    '$(sql_escape "$server_id")',
    ${account_num:-NULL},
    $(if [[ -n "$account_type" ]]; then printf "'%s'" "$(sql_escape "$account_type")"; else printf "NULL"; fi),
    ${active_limit:-0},
    ${five_hour:-0},
    ${seven_day:-0},
    $(if [[ -n "$reset_at_5h" ]]; then printf "'%s'" "$(sql_escape "$reset_at_5h")"; else printf "NULL"; fi),
    $(if [[ -n "$reset_at_7d" ]]; then printf "'%s'" "$(sql_escape "$reset_at_7d")"; else printf "NULL"; fi),
    ${observed_at:-0},
    ${lease_expires},
    ${now}
);
" >/dev/null 2>&1 || true
}

# Try to atomically claim an account before switching to it, so two servers can
# never converge on the same account (closes the TOCTOU race between reading
# lease state and switching). Talks to the coordinator directly instead of
# coord_http_request because that helper collapses every non-2xx into return 1,
# and here we must tell a 409 conflict apart from a network failure.
# Exit codes: 0 = claimed (safe to switch), 2 = conflict (another server holds
# it), 1 = coordinator unavailable / non-HTTP mode (caller decides fallback).
coord_try_claim_exclusive() {
    local account_num="$1"
    local email="$2"
    coord_http_ready || return 1

    local url token payload response http_code
    url="$(coord_config_value '.coordination.http.url')/v1/leases/claim"
    token=$(coord_config_value '.coordination.http.token')
    local connect_timeout="${CCS_CURL_CONNECT_TIMEOUT:-$DEFAULT_CURL_CONNECT_TIMEOUT}"
    local max_time="${CCS_CURL_MAX_TIME:-$DEFAULT_CURL_MAX_TIME}"

    payload=$(jq -n \
        --arg email "$email" \
        --arg serverId "$(coord_server_id)" \
        --argjson accountNumber "${account_num:-0}" \
        --argjson leaseTtlSeconds "$(coord_lease_ttl)" \
        '{email: $email, serverId: $serverId, accountNumber: $accountNumber, leaseTtlSeconds: $leaseTtlSeconds, exclusive: true}')

    response=$(curl -sS -w "\n%{http_code}" \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$url" 2>/dev/null) || return 1

    http_code=$(printf '%s' "$response" | tail -n1)
    case "$http_code" in
        2*) return 0 ;;
        409) return 2 ;;
        *) return 1 ;;
    esac
}

coord_publish_active_state() {
    coord_enabled || return 0
    [[ -f "$SEQUENCE_FILE" ]] || return 0
    local active_num active_email
    active_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    [[ -n "$active_num" && "$active_num" != "null" ]] || return 0
    active_email=$(jq -r --arg num "$active_num" '.accounts[$num].email // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    [[ -n "$active_email" ]] || return 0
    coord_publish_account_state "$active_num" "$active_email"
}

coord_remote_lease_owner() {
    local email="$1"
    if coord_http_ready; then
        local encoded
        encoded=$(printf '%s' "$email" | jq -sRr @uri)
        coord_http_request GET "/v1/leases/owner?email=${encoded}&serverId=$(printf '%s' "$(coord_server_id)" | jq -sRr @uri)" 2>/dev/null \
            | jq -r '.owner.serverId // empty' 2>/dev/null
        return 0
    fi

    coord_mysql_ready || return 1
    coord_ensure_schema >/dev/null 2>&1 || return 1
    local server_id
    server_id=$(coord_server_id)
    coord_mysql_exec "
SELECT server_id
FROM account_leases
WHERE email = '$(sql_escape "$email")'
  AND lease_expires_at > UNIX_TIMESTAMP()
  AND server_id <> '$(sql_escape "$server_id")'
LIMIT 1;
" 2>/dev/null | head -n1
}

coord_remote_lease_count() {
    local email="$1"
    if coord_http_ready; then
        local encoded
        encoded=$(printf '%s' "$email" | jq -sRr @uri)
        coord_http_request GET "/v1/leases/owner?email=${encoded}&serverId=$(printf '%s' "$(coord_server_id)" | jq -sRr @uri)" 2>/dev/null \
            | jq -r '.holderCount // 0' 2>/dev/null
        return 0
    fi

    local owner
    owner=$(coord_remote_lease_owner "$email" 2>/dev/null || true)
    if [[ -n "$owner" ]]; then
        echo "1"
    else
        echo "0"
    fi
}

# Single coordinator read returning
# "holderCount|activeLimit|fiveHour|sevenDay|observedAt|resetAt5h|resetAt7d" for
# an email. Fields come from the freshest OTHER holder (owner list already
# excludes our serverId, ordered most-recent). Raw per-window values (not a
# pre-maxed "usage") let the caller apply its own reset-expiry zeroing per
# window, same as account_snapshot_usage does for local snapshots. Non-HTTP
# (mysql) mode has no usage in the owner query, so it returns just the count
# with empty usage fields and the caller keeps its local snapshot.
coord_remote_owner_state() {
    local email="$1"
    if coord_http_ready; then
        local encoded
        encoded=$(printf '%s' "$email" | jq -sRr @uri)
        coord_http_request GET "/v1/leases/owner?email=${encoded}&serverId=$(printf '%s' "$(coord_server_id)" | jq -sRr @uri)" 2>/dev/null \
            | jq -r '
                (.holderCount // 0) as $c |
                (.owner // null) as $o |
                if $o == null then "\($c)||||||"
                else
                    "\($c)|\($o.activeLimit // 0)|\($o.fiveHour // 0)|\($o.sevenDay // 0)|\($o.observedAt // 0)|\($o.resetAt5h // "")|\($o.resetAt7d // "")"
                end
            ' 2>/dev/null
        return 0
    fi
    printf '%s||||||\n' "$(coord_remote_lease_count "$email" 2>/dev/null || echo 0)"
}

coord_release_account_state() {
    local email="$1"
    [[ -n "$email" ]] || return 0
    local server_id
    server_id=$(coord_server_id)

    if coord_http_ready; then
        local payload
        payload=$(jq -n --arg email "$email" --arg serverId "$server_id" '{email: $email, serverId: $serverId}')
        coord_http_request POST "/v1/leases/release" "$payload" >/dev/null 2>&1 || true
        return 0
    fi

    if coord_mysql_ready; then
        coord_ensure_schema >/dev/null 2>&1 || return 0
        coord_mysql_exec "
DELETE FROM account_leases
WHERE email = '$(sql_escape "$email")'
  AND server_id = '$(sql_escape "$server_id")';
" >/dev/null 2>&1 || true
    fi
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Acquire an exclusive lock around a credential switch so concurrent agents
# (e.g. orchestrator heartbeats crossing the threshold at once) can't race the
# non-atomic read-modify-write of the credential store + sequence.json.
# mkdir is atomic everywhere; macOS lacks flock. Steals a lock whose owner PID
# is gone. Returns 0 on success, 1 on timeout.
acquire_switch_lock() {
    # Reentrant when a caller up the stack (cmd_rate_check) already holds the
    # lock for the whole decision loop — skip re-acquiring so perform_switch
    # calls inside that loop don't deadlock waiting on their own parent's lock.
    [[ "${CCS_LOCK_HELD:-}" == "1" ]] && return 0
    local timeout_s="${1:-10}"
    local max_iters=$(( timeout_s * 5 ))   # 0.2s per iteration
    local i=0
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        # Stale-lock recovery: if the recorded owner is dead, reclaim the lock.
        local owner=""
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            continue
        fi
        i=$(( i + 1 ))
        if [[ "$i" -ge "$max_iters" ]]; then
            return 1
        fi
        sleep 0.2
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    return 0
}

# Release the switch lock. Idempotent (safe to call when not held).
release_switch_lock() {
    [[ "${CCS_LOCK_HELD:-}" == "1" ]] && return 0
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# Is the usage cache missing, account-mismatched, or older than the TTL?
# Echoes "stale" or "fresh". Used by both rate-check and the statusline.
cache_freshness() {
    local cache_file="$1"
    local ttl="$2"
    local expected_account="${3:-}"
    [[ -f "$cache_file" ]] || { echo "stale"; return; }
    local cached_at now age
    cached_at=$(jq -r '.cached_at // 0' "$cache_file" 2>/dev/null || echo 0)
    [[ "$cached_at" =~ ^[0-9]+$ ]] || cached_at=0
    now=$(date +%s)
    age=$(( now - cached_at ))
    if [[ "$cached_at" -le 0 || "$age" -ge "$ttl" ]]; then
        echo "stale"; return
    fi
    if [[ -n "$expected_account" ]]; then
        local cached_account
        cached_account=$(jq -r '.active_account // empty' "$cache_file" 2>/dev/null || true)
        if [[ -n "$cached_account" && "$cached_account" != "$expected_account" ]]; then
            echo "stale"; return
        fi
    fi
    echo "fresh"
}

usage_window_percent() {
    local cache_file="$1"
    local key="$2"
    jq -r --arg key "$key" '.[$key].utilization // empty' "$cache_file" 2>/dev/null
}

highest_limit_percent() {
    local cache_file="$1"
    jq -r '
        [
            (.limits // [])[] |
            select((.is_active // false) == true) |
            .percent? |
            select(type == "number" and . > 0)
        ] | max // empty
    ' "$cache_file" 2>/dev/null
}

effective_limit_source() {
    local cache_file="$1"
    jq -r '
        [
            (.limits // [])[] |
            select((.is_active // false) == true) |
            select((.percent? | type) == "number") |
            {
                percent: .percent,
                label: "limit"
            }
        ] |
        sort_by(.percent) |
        last |
        if . then "\(.percent)|\(.label)" else empty end
    ' "$cache_file" 2>/dev/null
}

effective_usage_percent() {
    local cache_file="$1"
    local active_limit active_percent five_hour seven_day
    active_limit=$(effective_limit_source "$cache_file")
    if [[ -n "$active_limit" ]]; then
        printf '%s\n' "${active_limit%%|*}"
        return
    fi

    five_hour=$(usage_window_percent "$cache_file" "five_hour")
    seven_day=$(usage_window_percent "$cache_file" "seven_day")

    jq -nr \
        --arg five "${five_hour:-0}" \
        --arg seven "${seven_day:-0}" '
        [
            ($five | tonumber? // 0),
            ($seven | tonumber? // 0)
        ] | max
    ' 2>/dev/null
}

effective_usage_source() {
    local cache_file="$1"
    local active_limit
    active_limit=$(effective_limit_source "$cache_file")
    if [[ -n "$active_limit" ]]; then
        printf '%s\n' "${active_limit#*|}"
    else
        local seven_day seven_day_int
        seven_day=$(usage_window_percent "$cache_file" "seven_day")
        seven_day_int=$(printf "%.0f" "${seven_day:-0}" 2>/dev/null || echo "0")
        if [[ "$seven_day_int" -gt 0 ]]; then
            printf 'seven_day\n'
        else
            printf 'five_hour\n'
        fi
    fi
}

usage_window_reset() {
    local cache_file="$1"
    local key="$2"
    jq -r --arg key "$key" '.[$key].resets_at // empty' "$cache_file" 2>/dev/null
}

format_usage_windows() {
    local cache_file="$1"
    local five_hour seven_day highest_limit five_hour_int seven_day_int highest_limit_int
    five_hour=$(usage_window_percent "$cache_file" "five_hour")
    seven_day=$(usage_window_percent "$cache_file" "seven_day")
    highest_limit=$(highest_limit_percent "$cache_file")

    [[ -n "$five_hour" ]] && five_hour_int=$(printf "%.0f" "$five_hour" 2>/dev/null || echo "")
    [[ -n "$seven_day" ]] && seven_day_int=$(printf "%.0f" "$seven_day" 2>/dev/null || echo "")
    [[ -n "$highest_limit" ]] && highest_limit_int=$(printf "%.0f" "$highest_limit" 2>/dev/null || echo "")

    local parts=()
    [[ -n "${five_hour_int:-}" ]] && parts+=("5h ${five_hour_int}%")
    [[ -n "${seven_day_int:-}" ]] && parts+=("7d ${seven_day_int}%")
    [[ -n "${highest_limit_int:-}" ]] && parts+=("limit ${highest_limit_int}%")

    if [[ ${#parts[@]} -eq 0 ]]; then
        echo "no usage data"
    else
        printf '%s' "${parts[0]}"
        local i
        for ((i = 1; i < ${#parts[@]}; i++)); do
            printf ' | %s' "${parts[i]}"
        done
        printf '\n'
    fi
}

format_usage_snapshot() {
    local account_num="$1"
    local email="$2"
    local line observed_at age now_epoch reset_5h reset_7d five_expired=0 seven_expired=0
    local usage_json local_observed remote_state remote_count remote_limit remote_5h remote_7d remote_observed remote_reset_5h remote_reset_7d remote_note=""
    now_epoch=$(date +%s)

    usage_json=$(jq -c --arg num "$account_num" '.accounts[$num].lastKnownUsage // {}' "$SEQUENCE_FILE" 2>/dev/null || echo '{}')
    local_observed=$(printf '%s' "$usage_json" | jq -r '.observedAt // 0' 2>/dev/null || echo 0)
    [[ "$local_observed" =~ ^[0-9]+$ ]] || local_observed=0

    # Cross-check the coordinator: another server may hold a fresher snapshot
    # for this account than what we last observed locally (see coord_remote_owner_state).
    if [[ -n "$email" ]]; then
        remote_state=$(coord_remote_owner_state "$email" 2>/dev/null || echo "0||||||")
        remote_count=$(printf '%s' "$remote_state" | cut -d'|' -f1)
        remote_limit=$(printf '%s' "$remote_state" | cut -d'|' -f2)
        remote_5h=$(printf '%s' "$remote_state" | cut -d'|' -f3)
        remote_7d=$(printf '%s' "$remote_state" | cut -d'|' -f4)
        remote_observed=$(printf '%s' "$remote_state" | cut -d'|' -f5)
        remote_reset_5h=$(printf '%s' "$remote_state" | cut -d'|' -f6)
        remote_reset_7d=$(printf '%s' "$remote_state" | cut -d'|' -f7)
        [[ "$remote_observed" =~ ^[0-9]+$ ]] || remote_observed=0
        if [[ -n "$remote_5h$remote_7d$remote_limit" && "$remote_observed" -gt "$local_observed" ]]; then
            usage_json=$(jq -cn --arg five "${remote_5h:-0}" --arg seven "${remote_7d:-0}" --arg limit "${remote_limit:-0}" \
                --arg r5 "$remote_reset_5h" --arg r7 "$remote_reset_7d" --arg obs "$remote_observed" '
                {
                    fiveHour: ($five|tonumber? // 0),
                    sevenDay: ($seven|tonumber? // 0),
                    activeLimit: ($limit|tonumber? // 0),
                    resetAt5h: (if $r5 == "" then null else $r5 end),
                    resetAt7d: (if $r7 == "" then null else $r7 end),
                    observedAt: ($obs|tonumber? // 0)
                }')
            remote_note=" [remote]"
        fi
    fi

    reset_5h=$(printf '%s' "$usage_json" | jq -r '.resetAt5h // empty' 2>/dev/null || true)
    if [[ -n "$reset_5h" ]]; then
        local r5_epoch
        r5_epoch=$(iso_to_epoch "$reset_5h")
        [[ "$r5_epoch" -gt 0 && "$r5_epoch" -le "$now_epoch" ]] && five_expired=1
    fi
    reset_7d=$(printf '%s' "$usage_json" | jq -r '.resetAt7d // empty' 2>/dev/null || true)
    if [[ -n "$reset_7d" ]]; then
        local r7_epoch
        r7_epoch=$(iso_to_epoch "$reset_7d")
        [[ "$r7_epoch" -gt 0 && "$r7_epoch" -le "$now_epoch" ]] && seven_expired=1
    fi

    line=$(printf '%s' "$usage_json" | jq -r --argjson fiveExpired "$five_expired" --argjson sevenExpired "$seven_expired" '
        . as $u |
        (if $fiveExpired == 1 then 0 else $u.fiveHour end) as $five |
        (if $sevenExpired == 1 then 0 else $u.sevenDay end) as $seven |
        (if ($fiveExpired == 1 or $sevenExpired == 1) then null else $u.activeLimit end) as $limit |
        [
            (if ($five != null) then "5h \($five | round)%" else empty end),
            (if ($seven != null) then "7d \($seven | round)%" else empty end),
            (if ($limit != null) then "limit \($limit | round)%" else empty end)
        ] | map(select(length > 0)) | join(" | ")
    ' 2>/dev/null)
    [[ -z "$line" ]] && return
    line="${line}${remote_note}"
    observed_at=$(printf '%s' "$usage_json" | jq -r '.observedAt // empty' 2>/dev/null)
    if [[ "$observed_at" =~ ^[0-9]+$ ]]; then
        age=$(( $(date +%s) - observed_at ))
        line="${line} (updated $(format_relative_age "$age") lalu)"
    fi
    printf '%s' "$line"
}

format_usage_resets_snapshot() {
    local account_num="$1"
    local reset_5h reset_7d now_epoch reset_epoch delta parts=()
    now_epoch=$(date +%s)
    reset_5h=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.resetAt5h // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    reset_7d=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.resetAt7d // empty' "$SEQUENCE_FILE" 2>/dev/null || true)

    if [[ -n "$reset_5h" ]]; then
        reset_epoch=$(iso_to_epoch "$reset_5h")
        delta=$((reset_epoch - now_epoch))
        parts+=("5h:$(format_relative_duration "$delta")")
    fi

    if [[ -n "$reset_7d" ]]; then
        reset_epoch=$(iso_to_epoch "$reset_7d")
        delta=$((reset_epoch - now_epoch))
        parts+=("7d:$(format_relative_duration "$delta")")
    fi

    if [[ ${#parts[@]} -gt 0 ]]; then
        printf '%s' "${parts[0]}"
        local i
        for ((i = 1; i < ${#parts[@]}; i++)); do
            printf ' | %s' "${parts[i]}"
        done
    fi
}

update_account_usage_snapshot() {
    local email="$1"
    local cache_file="$2"
    [[ -f "$SEQUENCE_FILE" && -f "$cache_file" ]] || return 0

    local account_num
    account_num=$(jq -r --arg email "$email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null || true)
    [[ -n "$account_num" ]] || return 0

    local updated
    updated=$(jq \
        --arg num "$account_num" \
        --slurpfile cache "$cache_file" \
        '
        .accounts[$num].lastKnownUsage = {
            fiveHour: ($cache[0].five_hour.utilization // 0),
            sevenDay: ($cache[0].seven_day.utilization // 0),
            activeLimit: (
                [($cache[0].limits // [])[] | select((.is_active // false) == true) | .percent? | select(type == "number")] | max // 0
            ),
            resetAt5h: ($cache[0].five_hour.resets_at // null),
            resetAt7d: ($cache[0].seven_day.resets_at // null),
            observedAt: ($cache[0].cached_at // 0)
        }
        ' "$SEQUENCE_FILE" 2>/dev/null) || return 0

    [[ -n "$updated" ]] || return 0
    write_json "$SEQUENCE_FILE" "$updated" >/dev/null 2>&1 || true
    coord_publish_account_state "$account_num" "$email"
}

iso_to_epoch() {
    local iso="$1"
    [[ -n "$iso" && "$iso" != "null" ]] || { echo 0; return; }
    date -d "$iso" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null || echo 0
}

format_relative_duration() {
    local seconds="$1"
    if [[ -z "$seconds" || "$seconds" -le 0 ]]; then
        echo "ready"
        return
    fi

    local days hours mins
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    mins=$(((seconds % 3600) / 60))

    if [[ "$days" -gt 0 ]]; then
        echo "${days}d"
    elif [[ "$hours" -gt 0 ]]; then
        echo "${hours}j"
    elif [[ "$mins" -gt 0 ]]; then
        echo "${mins}m"
    else
        echo "<1m"
    fi
}

format_relative_age() {
    local seconds="$1"
    if [[ -z "$seconds" || "$seconds" -lt 0 ]]; then
        echo "0m"
        return
    fi

    local days hours mins
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    mins=$(((seconds % 3600) / 60))

    if [[ "$days" -gt 0 ]]; then
        echo "${days}d"
    elif [[ "$hours" -gt 0 ]]; then
        echo "${hours}j"
    elif [[ "$mins" -gt 0 ]]; then
        echo "${mins}m"
    else
        echo "<1m"
    fi
}

write_account_credentials_if_active() {
    local email="$1"
    local creds="$2"
    local current_email
    current_email=$(get_current_account)
    if [[ "$email" == "$current_email" ]]; then
        write_credentials "$creds" >/dev/null 2>&1 || true
    fi
}

fetch_usage_for_account() {
    local account_num="$1"
    local email="$2"
    local creds="$3"
    local cache_file="$4"
    local persist_backup="${5:-true}"

    [[ -n "$creds" ]] || return 1

    local access_token
    access_token=$(credential_access_token "$creds")
    [[ -n "$access_token" ]] || return 1

    local response http_code body
    local connect_timeout="${CCS_CURL_CONNECT_TIMEOUT:-$DEFAULT_CURL_CONNECT_TIMEOUT}"
    local max_time="${CCS_CURL_MAX_TIME:-$DEFAULT_CURL_MAX_TIME}"

    response=$(curl -sS -w "\n%{http_code}" \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        -H "Authorization: Bearer $access_token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "401" ]]; then
        local refresh_token client_id refresh_response refresh_code refresh_body new_access new_refresh updated_creds
        refresh_token=$(credential_refresh_token "$creds")
        client_id="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        [[ -n "$refresh_token" ]] || return 1

        refresh_response=$(curl -sS -w "\n%{http_code}" \
            --connect-timeout "$connect_timeout" \
            --max-time "$max_time" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$refresh_token\",\"client_id\":\"$client_id\"}" \
            "https://console.anthropic.com/v1/oauth/token" 2>/dev/null) || return 1
        refresh_code=$(echo "$refresh_response" | tail -n1)
        refresh_body=$(echo "$refresh_response" | sed '$d')
        [[ "$refresh_code" == "200" ]] || return 1

        new_access=$(echo "$refresh_body" | jq -r '.access_token // empty' 2>/dev/null)
        new_refresh=$(echo "$refresh_body" | jq -r '.refresh_token // empty' 2>/dev/null)
        [[ -n "$new_access" ]] || return 1

        updated_creds=$(update_credential_tokens "$creds" "$new_access" "${new_refresh:-$refresh_token}")
        if [[ "$persist_backup" == "true" ]]; then
            write_account_credentials "$account_num" "$email" "$updated_creds" >/dev/null 2>&1 || true
        fi
        write_account_credentials_if_active "$email" "$updated_creds"

        response=$(curl -sS -w "\n%{http_code}" \
            --connect-timeout "$connect_timeout" \
            --max-time "$max_time" \
            -H "Authorization: Bearer $new_access" \
            -H "anthropic-beta: oauth-2025-04-20" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
    fi

    [[ "$http_code" == "200" ]] || return 1
    echo "$body" | jq . >/dev/null 2>&1 || return 1

    local cache_content
    cache_content=$(echo "$body" | jq \
        --arg email "$email" \
        --arg ts "$(date +%s)" \
        '. + {active_account: $email, cached_at: ($ts | tonumber)}' 2>/dev/null) || return 1

    printf '%s' "$cache_content" > "$cache_file"
    update_account_usage_snapshot "$email" "$cache_file"
    return 0
}

send_warm_ping() {
    local access_token="$1"
    local model="${CCS_PING_MODEL:-claude-3-5-haiku-latest}"
    local response_code
    local connect_timeout="${CCS_CURL_CONNECT_TIMEOUT:-$DEFAULT_CURL_CONNECT_TIMEOUT}"
    local max_time="${CCS_CURL_MAX_TIME:-$DEFAULT_CURL_MAX_TIME}"
    response_code=$(curl -sS -o /dev/null -w "%{http_code}" \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        -X POST \
        -H "Authorization: Bearer $access_token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "content-type: application/json" \
        "https://api.anthropic.com/v1/messages?beta=true" \
        -d "{\"model\":\"${model}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null) || return 1
    [[ "$response_code" =~ ^2 ]] || return 1
}

mark_account_pinged() {
    local account_num="$1"
    local reset_at="$2"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local updated
    updated=$(jq \
        --arg num "$account_num" \
        --arg reset "$reset_at" \
        --arg now "$now" \
        '
        .accounts[$num].lastPingedResetAt = $reset |
        .accounts[$num].lastPingAt = $now
        ' "$SEQUENCE_FILE" 2>/dev/null) || return 1
    write_json "$SEQUENCE_FILE" "$updated"
}

cmd_warm_check() {
    local lead_seconds=5
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lead-seconds)
                lead_seconds="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    [[ -f "$SEQUENCE_FILE" ]] || { echo "Error: No accounts configured"; exit 1; }

    local now_epoch
    now_epoch=$(date +%s)
    local active_num active_email creds cache_file reset_at reset_epoch last_pinged access_token usage_line
    active_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    [[ -n "$active_num" && "$active_num" != "null" ]] || { echo "No active account."; return 0; }
    active_email=$(jq -r --arg num "$active_num" '.accounts[$num].email // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    [[ -n "$active_email" ]] || { echo "No active account email."; return 0; }

    creds=$(read_credentials)
    [[ -n "$creds" ]] || { echo "No active credentials."; return 0; }

    cache_file=$(mktemp "/tmp/ccs-warm-${active_num}-XXXXXX.json")
    if ! fetch_usage_for_account "$active_num" "$active_email" "$creds" "$cache_file"; then
        rm -f "$cache_file"
        echo "Active account usage refresh failed."
        return 0
    fi

    reset_at=$(jq -r '.five_hour.resets_at // empty' "$cache_file" 2>/dev/null || true)
    usage_line=$(format_usage_windows "$cache_file" 2>/dev/null | tr -d '\n')
    rm -f "$cache_file"
    [[ -n "$reset_at" ]] || { echo "No account needed warm ping."; return 0; }

    reset_epoch=$(iso_to_epoch "$reset_at")
    [[ "$reset_epoch" -gt 0 ]] || { echo "No account needed warm ping."; return 0; }
    last_pinged=$(jq -r --arg num "$active_num" '.accounts[$num].lastPingedResetAt // empty' "$SEQUENCE_FILE" 2>/dev/null || true)

    if [[ "$now_epoch" -ge $((reset_epoch - lead_seconds)) && "$last_pinged" != "$reset_at" ]]; then
        access_token=$(credential_access_token "$creds")
        if [[ -n "$access_token" ]] && send_warm_ping "$access_token"; then
            mark_account_pinged "$active_num" "$reset_at" >/dev/null 2>&1 || true
            echo "Pinged Account-$active_num ($active_email) after resetAt=$reset_at [$usage_line]"
            return 0
        fi
    fi

    echo "No account needed warm ping."
}

cmd_warm_loop() {
    local interval=60
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval)
                interval="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo "Starting warm loop (interval=${interval}s). Ctrl-C to stop."
    while true; do
        cmd_warm_check
        sleep "$interval"
    done
}

account_snapshot_usage() {
    local account_num="$1"
    local now_epoch reset_5h reset_7d five_expired=0 seven_expired=0
    now_epoch=$(date +%s)

    reset_5h=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.resetAt5h // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ -n "$reset_5h" ]]; then
        local reset_5h_epoch
        reset_5h_epoch=$(iso_to_epoch "$reset_5h")
        [[ "$reset_5h_epoch" -gt 0 && "$reset_5h_epoch" -le "$now_epoch" ]] && five_expired=1
    fi

    reset_7d=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.resetAt7d // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ -n "$reset_7d" ]]; then
        local reset_7d_epoch
        reset_7d_epoch=$(iso_to_epoch "$reset_7d")
        [[ "$reset_7d_epoch" -gt 0 && "$reset_7d_epoch" -le "$now_epoch" ]] && seven_expired=1
    fi

    jq -r --arg num "$account_num" --argjson fiveExpired "$five_expired" --argjson sevenExpired "$seven_expired" '
        (.accounts[$num].lastKnownUsage // {}) as $u |
        (if $fiveExpired == 1 then 0 else ($u.fiveHour // 0) end) as $five |
        (if $sevenExpired == 1 then 0 else ($u.sevenDay // 0) end) as $seven |
        (if (($u.activeLimit // 0) > 0 and $fiveExpired == 0 and $sevenExpired == 0) then ($u.activeLimit // 0) else $five end) as $primary |
        if ($primary >= 100 or $seven >= 100) then
            100000 + ([$primary, $seven] | max)
        else
            $primary * 1000 + $seven
        end
    ' "$SEQUENCE_FILE" 2>/dev/null || echo "0"
}

account_group_type() {
    local account_num="$1"
    jq -r --arg num "$account_num" '.accounts[$num].accountType // "other"' "$SEQUENCE_FILE" 2>/dev/null || echo "other"
}

account_usage_known() {
    local account_num="$1"
    local observed
    observed=$(jq -r --arg num "$account_num" '.accounts[$num].lastKnownUsage.observedAt // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    [[ -n "$observed" && "$observed" != "null" ]]
}

account_type_priority() {
    local account_num="$1"
    local type priority
    type=$(account_group_type "$account_num")
    priority=$(jq -r --arg type "$type" '.accountTypePolicy[$type].priority // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ -n "$priority" && "$priority" != "null" ]]; then
        echo "$priority"
        return
    fi
    case "$type" in
        team) echo "100" ;;
        max20) echo "50" ;;
        *) echo "10" ;;
    esac
}

collect_switch_candidates() {
    local active_account="$1"
    local ord=0 num usage known priority email remote_count
    while IFS= read -r num; do
        [[ -n "$num" ]] || continue
        if [[ "$num" == "$active_account" ]]; then
            ord=$((ord + 1))
            continue
        fi
        email=$(jq -r --arg num "$num" '.accounts[$num].email // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
        usage=$(account_snapshot_usage "$num")
        if account_usage_known "$num"; then
            known=1
        else
            known=0
        fi
        priority=$(account_type_priority "$num")
        remote_count=0
        if [[ -n "$email" ]]; then
            # Fetch coordinator state once: holder count + freshest other server's
            # usage. Prefer remote usage only when it was observed more recently
            # than our local snapshot, so a stale local number can't override a
            # fresh fleet-wide one (and vice versa).
            local remote_state remote_limit remote_5h remote_7d remote_observed remote_reset_5h remote_reset_7d local_observed
            remote_state=$(coord_remote_owner_state "$email" 2>/dev/null || echo "0||||||")
            remote_count=$(printf '%s' "$remote_state" | cut -d'|' -f1)
            [[ "$remote_count" =~ ^[0-9]+$ ]] || remote_count=0
            remote_limit=$(printf '%s' "$remote_state" | cut -d'|' -f2)
            remote_5h=$(printf '%s' "$remote_state" | cut -d'|' -f3)
            remote_7d=$(printf '%s' "$remote_state" | cut -d'|' -f4)
            remote_observed=$(printf '%s' "$remote_state" | cut -d'|' -f5)
            remote_reset_5h=$(printf '%s' "$remote_state" | cut -d'|' -f6)
            remote_reset_7d=$(printf '%s' "$remote_state" | cut -d'|' -f7)
            local_observed=$(jq -r --arg num "$num" '.accounts[$num].lastKnownUsage.observedAt // 0' "$SEQUENCE_FILE" 2>/dev/null || echo 0)
            [[ "$local_observed" =~ ^[0-9]+$ ]] || local_observed=0
            [[ "$remote_observed" =~ ^[0-9]+$ ]] || remote_observed=0
            if [[ -n "$remote_5h$remote_7d$remote_limit" && "$remote_observed" -gt "$local_observed" ]]; then
                # Apply the same reset-expiry rule account_snapshot_usage uses:
                # a passed reset means that window is clear, usage is 0 — checked
                # per-window (5h and 7d independently) rather than zeroing both.
                local now_epoch five_expired=0 seven_expired=0
                now_epoch=$(date +%s)
                if [[ -n "$remote_reset_5h" ]]; then
                    local r5_epoch
                    r5_epoch=$(iso_to_epoch "$remote_reset_5h")
                    [[ "$r5_epoch" -gt 0 && "$r5_epoch" -le "$now_epoch" ]] && five_expired=1
                fi
                if [[ -n "$remote_reset_7d" ]]; then
                    local r7_epoch
                    r7_epoch=$(iso_to_epoch "$remote_reset_7d")
                    [[ "$r7_epoch" -gt 0 && "$r7_epoch" -le "$now_epoch" ]] && seven_expired=1
                fi
                [[ "$five_expired" -eq 1 ]] && remote_5h=0
                [[ "$seven_expired" -eq 1 ]] && remote_7d=0
                local remote_usage
                if [[ -n "$remote_limit" && "$remote_limit" != "0" && "$five_expired" -eq 0 && "$seven_expired" -eq 0 ]]; then
                    remote_usage="$remote_limit"
                else
                    remote_usage=$(jq -nr --arg five "${remote_5h:-0}" --arg seven "${remote_7d:-0}" '
                        ($five|tonumber? // 0) as $five |
                        ($seven|tonumber? // 0) as $seven |
                        if ($five >= 100 or $seven >= 100) then 100000 + ([$five, $seven] | max)
                        else $five * 1000 + $seven
                        end
                    ')
                fi
                usage="$remote_usage"
                known=1
            fi
        fi
        printf '%s|%s|%s|%s|%s\n' "$num" "$usage" "$known" "$priority" "$remote_count"
        ord=$((ord + 1))
    done < <(jq -r '.sequence[]' "$SEQUENCE_FILE" 2>/dev/null)
}

auto_switch_candidates() {
    local active_account="$1"
    local healthy_threshold="${2:-95}"
    local candidates
    candidates=$(collect_switch_candidates "$active_account")
    [[ -n "$candidates" ]] || return 0

    local exclusive
    exclusive=$(printf '%s\n' "$candidates" | awk -F'|' '$5 == 0')

    local exclusive_healthy=""
    if [[ -n "$exclusive" ]]; then
        # Field 2 is the composite score (five*1000+seven, or 100000+ if either
        # window is hard-blocked at >=100). "Healthy" means the 5h window
        # (the primary usability gate) is below the threshold — extract it back
        # out of the composite instead of comparing the raw score to a percent.
        exclusive_healthy=$(printf '%s\n' "$exclusive" | awk -F'|' -v t="$healthy_threshold" '{five = ($2 >= 100000) ? 100 : int($2 / 1000); if (five < t) print}')
    fi

    if [[ -n "$exclusive_healthy" ]]; then
        printf '%s\n' "$exclusive_healthy" \
            | sort -t'|' -k4,4nr -k3,3nr -k2,2n -k1,1n \
            | cut -d'|' -f1
        return 0
    fi

    printf '%s\n' "$candidates" \
        | sort -t'|' -k3,3nr -k2,2n -k4,4nr -k5,5n -k1,1n \
        | cut -d'|' -f1
}

should_reclaim_to_preferred_account() {
    local active_account="$1"
    [[ -f "$SEQUENCE_FILE" ]] || return 1

    local best_account
    best_account=$(auto_switch_candidates "$active_account" "${2:-95}" | head -n1)
    [[ -n "$best_account" ]] || return 1

    local active_priority best_priority active_usage best_usage
    active_priority=$(account_type_priority "$active_account")
    best_priority=$(account_type_priority "$best_account")
    active_usage=$(account_snapshot_usage "$active_account")
    best_usage=$(account_snapshot_usage "$best_account")

    if (( best_priority > active_priority )) && (( best_usage < active_usage )); then
        echo "$best_account"
        return 0
    fi

    # Same-priority accounts don't reclaim on any usage edge (that would
    # thrash between two team accounts a few percent apart). But when the
    # active account's 5h usage is at least double the candidate's, the gap
    # is big enough that riding it out to the 95% hard-switch threshold
    # wastes a mostly-empty sibling account for no reason — pull the primary
    # (5h, or activeLimit) window back out of the composite score to compare.
    if (( best_priority == active_priority )); then
        local active_five best_five
        active_five=$(( active_usage >= 100000 ? 100 : active_usage / 1000 ))
        best_five=$(( best_usage >= 100000 ? 100 : best_usage / 1000 ))
        if (( active_five > 0 && best_five * 2 < active_five )); then
            echo "$best_account"
            return 0
        fi
    fi

    return 1
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi

    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."

    while is_claude_running; do
        sleep 1
    done

    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi

    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi

    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Extract access token from credentials in either legacy flat format or the
# current Claude Code nested format.
credential_access_token() {
    local creds="$1"
    echo "$creds" | jq -r '
        .access_token //
        .token //
        .claudeAiOauth.accessToken //
        empty
    ' 2>/dev/null
}

# Extract refresh token from credentials in either legacy flat format or the
# current Claude Code nested format.
credential_refresh_token() {
    local creds="$1"
    echo "$creds" | jq -r '
        .refresh_token //
        .claudeAiOauth.refreshToken //
        empty
    ' 2>/dev/null
}

# Append a timestamped line to a persistent credential-event log, so a
# corrupted/emptied credential file can be traced after the fact (bash
# subshells and background hook calls otherwise drop stderr warnings).
log_credential_event() {
    local msg="$1"
    local log_file="${BACKUP_DIR}/credential-events.log"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$msg" >> "$log_file" 2>/dev/null || true
}

# Append a timestamped line to a persistent auto-switch decision log, so
# rate-check/reclaim behavior (which mostly runs silently via hook/statusline
# background calls) can be traced after the fact instead of guessed from
# sequence.json's final state.
log_switch_event() {
    local msg="$1"
    local log_file="${BACKUP_DIR}/autoswitch.log"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$msg" >> "$log_file" 2>/dev/null || true
}

credential_is_usable() {
    local creds="$1"
    local access refresh expires now
    access=$(credential_access_token "$creds")
    refresh=$(credential_refresh_token "$creds")
    expires=$(echo "$creds" | jq -r '.expires_at // .claudeAiOauth.expiresAt // 0' 2>/dev/null || echo 0)
    [[ -n "$access" && -n "$refresh" ]] || return 1
    [[ "$expires" =~ ^[0-9]+$ ]] || expires=0
    now=$(date +%s)
    if [[ "$expires" -gt 1000000000000 ]]; then
        expires=$((expires / 1000))
    fi
    [[ "$expires" -eq 0 || "$expires" -gt "$now" ]]
}

mark_account_auth_invalid() {
    local account_num="$1"
    local reason="$2"
    local now updated
    [[ -f "$SEQUENCE_FILE" ]] || return 0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    updated=$(jq \
        --arg num "$account_num" \
        --arg reason "$reason" \
        --arg now "$now" '
        .accounts[$num].authState = "invalid" |
        .accounts[$num].lastAuthError = $reason |
        .accounts[$num].lastAuthErrorAt = $now
    ' "$SEQUENCE_FILE" 2>/dev/null) || return 0
    write_json "$SEQUENCE_FILE" "$updated" >/dev/null 2>&1 || true
}

clear_account_auth_invalid() {
    local account_num="$1"
    local updated
    [[ -f "$SEQUENCE_FILE" ]] || return 0
    updated=$(jq --arg num "$account_num" '
        del(.accounts[$num].authState) |
        del(.accounts[$num].lastAuthError) |
        del(.accounts[$num].lastAuthErrorAt)
    ' "$SEQUENCE_FILE" 2>/dev/null) || return 0
    write_json "$SEQUENCE_FILE" "$updated" >/dev/null 2>&1 || true
}

headless_auth_smoke() {
    local out rc
    command -v claude >/dev/null 2>&1 || return 0
    out=$(claude -p 'Reply exactly: HEADLESS_OK' 2>&1)
    rc=$?
    [[ "$rc" -eq 0 && "$out" == *"HEADLESS_OK"* ]]
}

# Update tokens while preserving the credential JSON shape Claude Code expects.
update_credential_tokens() {
    local creds="$1"
    local access_token="$2"
    local refresh_token="$3"

    echo "$creds" | jq \
        --arg at "$access_token" \
        --arg rt "$refresh_token" '
        if has("claudeAiOauth") then
            .claudeAiOauth.accessToken = $at |
            .claudeAiOauth.refreshToken = $rt
        else
            .access_token = $at |
            .refresh_token = $rt
        end
    ' 2>/dev/null
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)

    if ! credential_is_usable "$credentials"; then
        log_credential_event "write_credentials writing EMPTY/EXPIRED credentials to live session"
    fi

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform

    if ! credential_is_usable "$credentials"; then
        local existing
        existing=$(read_account_credentials "$account_num" "$email")
        if credential_is_usable "$existing"; then
            log_credential_event "refused to overwrite valid backup for Account-$account_num ($email) with empty/expired credentials (caller=${FUNCNAME[1]:-unknown})"
            echo "Warning: refusing to overwrite valid backup for Account-$account_num ($email) with empty/expired credentials" >&2
            return 0
        fi
        log_credential_event "writing EMPTY/EXPIRED credentials for Account-$account_num ($email) — existing backup was already unusable (caller=${FUNCNAME[1]:-unknown})"
    fi

    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content
        init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

cmd_coord_setup() {
    local mode="http"
    local api_url=""
    local api_token=""
    local host="127.0.0.1"
    local port="3306"
    local database="ccs"
    local user="ccs"
    local password=""
    local server_id=""
    local lease_ttl="$DEFAULT_COORD_LEASE_TTL"
    local disable=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                mode="$2"
                shift 2
                ;;
            --api-url)
                api_url="$2"
                shift 2
                ;;
            --api-token)
                api_token="$2"
                shift 2
                ;;
            --host)
                host="$2"
                shift 2
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            --database)
                database="$2"
                shift 2
                ;;
            --user)
                user="$2"
                shift 2
                ;;
            --password)
                password="$2"
                shift 2
                ;;
            --server-id)
                server_id="$2"
                shift 2
                ;;
            --lease-ttl)
                lease_ttl="$2"
                shift 2
                ;;
            --disable)
                disable=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    setup_directories
    init_sequence_file

    if [[ "$disable" == "true" ]]; then
        local disabled
        disabled=$(jq '
            .coordination = {}
        ' "$SEQUENCE_FILE")
        write_json "$SEQUENCE_FILE" "$disabled"
        echo "Coordination disabled."
        return 0
    fi

    [[ "$lease_ttl" =~ ^[0-9]+$ ]] || { echo "Error: --lease-ttl must be numeric"; exit 1; }
    [[ -n "$server_id" ]] || server_id=$(hostname 2>/dev/null || echo "unknown-server")

    local updated
    if [[ "$mode" == "http" ]]; then
        [[ -n "$api_url" ]] || { echo "Error: --api-url is required for http mode"; exit 1; }
        [[ -n "$api_token" ]] || { echo "Error: --api-token is required for http mode"; exit 1; }
        updated=$(jq \
            --arg sid "$server_id" \
            --arg url "$api_url" \
            --arg token "$api_token" \
            --argjson ttl "$lease_ttl" \
            '
            .coordination = {
                mode: "http",
                serverId: $sid,
                leaseTtlSeconds: $ttl,
                http: {
                    url: $url,
                    token: $token
                }
            }
            ' "$SEQUENCE_FILE")
        write_json "$SEQUENCE_FILE" "$updated"
        coord_publish_active_state
        echo "Coordination enabled."
        echo "  Mode: http"
        echo "  Server ID: $server_id"
        echo "  API: $api_url"
        echo "  Lease TTL: ${lease_ttl}s"
        return 0
    fi

    [[ "$mode" == "mysql" ]] || { echo "Error: --mode must be http or mysql"; exit 1; }
    [[ -n "$password" ]] || { echo "Error: --password is required for mysql mode"; exit 1; }
    updated=$(jq \
        --arg host "$host" \
        --arg port "$port" \
        --arg db "$database" \
        --arg user "$user" \
        --arg pass "$password" \
        --arg sid "$server_id" \
        --argjson ttl "$lease_ttl" \
        '
        .coordination = {
            mode: "mysql",
            serverId: $sid,
            leaseTtlSeconds: $ttl,
            mysql: {
                host: $host,
                port: $port,
                database: $db,
                user: $user,
                password: $pass
            }
        }
        ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated"

    if ! coord_ensure_schema; then
        echo "Error: failed to initialize coordination schema"
        exit 1
    fi

    coord_publish_active_state
    echo "Coordination enabled."
    echo "  Mode: mysql"
    echo "  Server ID: $server_id"
    echo "  MySQL: ${user}@${host}:${port}/${database}"
    echo "  Lease TTL: ${lease_ttl}s"
}

cmd_coord_sync() {
    if ! coord_enabled; then
        echo "Coordination not configured."
        exit 1
    fi
    if coord_mysql_ready; then
        coord_ensure_schema >/dev/null
    fi
    coord_publish_active_state
    echo "Coordination sync complete."
}

cmd_coord_client_setup() {
    local api_url=""
    local api_token=""
    local server_id=""
    local threshold="95"
    local lease_ttl="$DEFAULT_COORD_LEASE_TTL"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-url)
                api_url="$2"
                shift 2
                ;;
            --api-token)
                api_token="$2"
                shift 2
                ;;
            --server-id)
                server_id="$2"
                shift 2
                ;;
            --threshold)
                threshold="$2"
                shift 2
                ;;
            --lease-ttl)
                lease_ttl="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    [[ -n "$api_url" ]] || { echo "Error: --api-url is required"; exit 1; }
    [[ -n "$api_token" ]] || { echo "Error: --api-token is required"; exit 1; }
    [[ -n "$server_id" ]] || server_id=$(hostname 2>/dev/null || echo "unknown-server")

    cmd_coord_setup --mode http --api-url "$api_url" --api-token "$api_token" --server-id "$server_id" --lease-ttl "$lease_ttl"
    cmd_rate_setup --threshold "$threshold"
    cmd_statusline_setup

    echo "Client setup complete."
    echo "  Coordinator: $api_url"
    echo "  Server ID:   $server_id"
    echo "  Threshold:   ${threshold}%"
}

cmd_coord_token() {
    local token=""

    if [[ -f "$SEQUENCE_FILE" ]]; then
        token=$(jq -r '.coordination.http.token // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    fi

    if [[ -z "$token" && -f /etc/default/ccs-coordinator ]]; then
        token=$(sed -n 's/^CCS_COORD_TOKEN=//p' /etc/default/ccs-coordinator | head -n1)
    fi

    if [[ -z "$token" ]]; then
        echo "Error: coordination token not found"
        exit 1
    fi

    printf '%s\n' "$token"
}

cmd_coord_client_command() {
    local api_url=""
    local server_id='$(hostname)'
    local threshold="95"
    local token=""

    if [[ -f "$SEQUENCE_FILE" ]]; then
        api_url=$(jq -r '.coordination.http.url // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    fi
    [[ -n "$api_url" ]] || api_url="https://ccs.dev.gass.web.id"

    token=$(cmd_coord_token 2>/dev/null) || {
        echo "Error: coordination token not found"
        exit 1
    }

    cat <<EOF
ccs --allow-root coord-client-setup \\
  --api-url ${api_url} \\
  --api-token '${token}' \\
  --server-id "${server_id}" \\
  --threshold ${threshold}
EOF
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi

    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Base64url decode (portable)
base64url_decode() {
    local input="$1"
    # Add padding
    local pad=$(( 4 - ${#input} % 4 ))
    if [[ $pad -ne 4 ]]; then
        input="${input}$(printf '%0.s=' $(seq 1 "$pad"))"
    fi
    # Replace URL-safe chars and decode
    echo "$input" | tr '_-' '/+' | base64 -d 2>/dev/null || true
}

# Decode JWT and return payload as JSON
decode_jwt_payload() {
    local token="$1"
    local payload
    payload=$(echo "$token" | cut -d. -f2)
    if [[ -z "$payload" ]]; then
        echo ""
        return
    fi
    base64url_decode "$payload" | jq . 2>/dev/null || echo ""
}

# Kill Claude Code processes
kill_claude_processes() {
    local pids
    pids=$(ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {print $1}')
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 1
        # Force kill if still running
        local remaining
        remaining=$(ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {print $1}')
        if [[ -n "$remaining" ]]; then
            echo "$remaining" | xargs kill -9 2>/dev/null || true
        fi
    fi
}

# Restart Claude Code
restart_claude_code() {
    echo "Restarting Claude Code..."
    kill_claude_processes
    sleep 1
    if command -v claude >/dev/null 2>&1; then
        nohup claude </dev/null >/dev/null 2>&1 &
        echo "Claude Code restarted."
    else
        echo "Warning: 'claude' command not found in PATH. Please start Claude Code manually."
    fi
}

# Handle restart logic after a switch
handle_restart_after_switch() {
    case "$RESTART_FLAG" in
        restart)
            restart_claude_code
            ;;
        no-restart)
            echo "Please restart Claude Code to use the new authentication."
            ;;
        *)
            echo "Please restart Claude Code to use the new authentication."
            ;;
    esac
}

# Backup integrity check
cmd_check() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet. Nothing to check."
        exit 0
    fi

    local issues=0
    local platform
    platform=$(detect_platform)

    echo "Backup Integrity Check"
    echo "======================"
    echo ""

    # Check sequence.json itself
    if jq . "$SEQUENCE_FILE" >/dev/null 2>&1; then
        echo "[OK] sequence.json is valid JSON"
    else
        echo "[FAIL] sequence.json is invalid JSON"
        issues=$((issues + 1))
    fi

    # Check each account
    local accounts
    accounts=$(jq -r '.accounts | to_entries[] | "\(.key)|\(.value.email)"' "$SEQUENCE_FILE")

    while IFS='|' read -r num email; do
        [[ -z "$num" ]] && continue
        echo ""
        echo "Account-$num ($email):"

        # Check config backup
        local config_file="$BACKUP_DIR/configs/.claude-config-${num}-${email}.json"
        if [[ -f "$config_file" ]]; then
            if jq . "$config_file" >/dev/null 2>&1; then
                echo "  [OK] Config backup is valid JSON"
            else
                echo "  [FAIL] Config backup is invalid JSON: $config_file"
                issues=$((issues + 1))
            fi
            # Check file permissions
            local perms
            if [[ "$platform" == "macos" ]]; then
                perms=$(stat -f "%Lp" "$config_file" 2>/dev/null)
            else
                perms=$(stat -c "%a" "$config_file" 2>/dev/null)
            fi
            if [[ "$perms" == "600" ]]; then
                echo "  [OK] Config file permissions: $perms"
            else
                echo "  [WARN] Config file permissions: $perms (expected 600)"
                issues=$((issues + 1))
            fi
        else
            echo "  [FAIL] Config backup missing: $config_file"
            issues=$((issues + 1))
        fi

        # Check credentials backup
        case "$platform" in
            macos)
                if security find-generic-password -s "Claude Code-Account-${num}-${email}" -w >/dev/null 2>&1; then
                    echo "  [OK] Keychain entry exists"
                    # Validate it's valid JSON
                    local kc_creds
                    kc_creds=$(security find-generic-password -s "Claude Code-Account-${num}-${email}" -w 2>/dev/null)
                    if echo "$kc_creds" | jq . >/dev/null 2>&1; then
                        echo "  [OK] Keychain credentials are valid JSON"
                    else
                        echo "  [FAIL] Keychain credentials are invalid JSON"
                        issues=$((issues + 1))
                    fi
                else
                    echo "  [FAIL] Keychain entry missing for Account-$num"
                    issues=$((issues + 1))
                fi
                ;;
            linux|wsl)
                local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${num}-${email}.json"
                if [[ -f "$cred_file" ]]; then
                    if jq . "$cred_file" >/dev/null 2>&1; then
                        echo "  [OK] Credentials backup is valid JSON"
                    else
                        echo "  [FAIL] Credentials backup is invalid JSON: $cred_file"
                        issues=$((issues + 1))
                    fi
                    local cperms
                    if [[ "$platform" == "macos" ]]; then
                        cperms=$(stat -f "%Lp" "$cred_file" 2>/dev/null)
                    else
                        cperms=$(stat -c "%a" "$cred_file" 2>/dev/null)
                    fi
                    if [[ "$cperms" == "600" ]]; then
                        echo "  [OK] Credentials file permissions: $cperms"
                    else
                        echo "  [WARN] Credentials file permissions: $cperms (expected 600)"
                        issues=$((issues + 1))
                    fi
                else
                    echo "  [FAIL] Credentials backup missing: $cred_file"
                    issues=$((issues + 1))
                fi
                ;;
        esac
    done <<< "$accounts"

    # Check backup directory permissions
    echo ""
    local dir_perms
    if [[ "$platform" == "macos" ]]; then
        dir_perms=$(stat -f "%Lp" "$BACKUP_DIR" 2>/dev/null)
    else
        dir_perms=$(stat -c "%a" "$BACKUP_DIR" 2>/dev/null)
    fi
    if [[ "$dir_perms" == "700" ]]; then
        echo "[OK] Backup directory permissions: $dir_perms"
    else
        echo "[WARN] Backup directory permissions: $dir_perms (expected 700)"
        issues=$((issues + 1))
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        echo "All checks passed."
    else
        echo "$issues issue(s) found."
        exit 1
    fi
}

# Token expiry monitoring and status display
cmd_status() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        exit 0
    fi

    local current_email
    current_email=$(get_current_account)

    local active_num=""
    local profile_name=""
    local account_type=""
    if [[ "$current_email" != "none" ]]; then
        active_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$active_num" ]]; then
            profile_name=$(jq -r --arg num "$active_num" '.accounts[$num].profile // empty' "$SEQUENCE_FILE" 2>/dev/null)
            account_type=$(jq -r --arg num "$active_num" '.accounts[$num].accountType // empty' "$SEQUENCE_FILE" 2>/dev/null)
        fi
    fi

    echo "Account Status"
    echo "=============="
    echo ""
    echo "Current account: ${current_email}"
    if [[ -n "$active_num" ]]; then
        echo "Account number:  $active_num"
    fi
    if [[ -n "$profile_name" ]]; then
        echo "Profile name:    $profile_name"
    fi
    if [[ -n "$account_type" ]]; then
        echo "Account type:    $account_type"
    fi
    if coord_enabled; then
        echo "Coordination:    $(coord_mode) ($(coord_server_id))"
    fi

    # Last switch timestamp
    local last_updated
    last_updated=$(jq -r '.lastUpdated // empty' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$last_updated" ]]; then
        echo "Last switch:     $last_updated"
    fi

    # Token expiry check
    echo ""
    local creds
    creds=$(read_credentials)
    if [[ -n "$creds" ]]; then
        # Try to extract access_token or the token field
        local token
        token=$(credential_access_token "$creds")
        if [[ -n "$token" ]]; then
            local payload
            payload=$(decode_jwt_payload "$token")
            if [[ -n "$payload" ]]; then
                local exp
                exp=$(echo "$payload" | jq -r '.exp // empty' 2>/dev/null)
                if [[ -n "$exp" ]]; then
                    local now
                    now=$(date +%s)
                    local diff=$((exp - now))
                    if [[ $diff -le 0 ]]; then
                        echo "Token status:    EXPIRED ($(( -diff / 3600 )) hours ago)"
                    elif [[ $diff -lt 3600 ]]; then
                        echo "Token status:    Expires in $((diff / 60)) minutes"
                    elif [[ $diff -lt 86400 ]]; then
                        echo "Token status:    Expires in $((diff / 3600)) hours"
                    else
                        echo "Token status:    Expires in $((diff / 86400)) days"
                    fi
                else
                    echo "Token status:    Unable to determine expiry (no exp claim)"
                fi
            else
                echo "Token status:    Unable to decode token (not a JWT)"
            fi
        else
            echo "Token status:    No access token found in credentials"
        fi
    else
        echo "Token status:    No credentials found"
    fi

    local cache_file="/tmp/claude-usage-cache.json"
    if [[ -f "$cache_file" ]]; then
        local usage_summary five_reset seven_reset
        usage_summary=$(format_usage_windows "$cache_file")
        five_reset=$(usage_window_reset "$cache_file" "five_hour")
        seven_reset=$(usage_window_reset "$cache_file" "seven_day")

        echo ""
        echo "Usage windows:   $usage_summary"
        [[ -n "$five_reset" ]] && echo "5h resets at:    $five_reset"
        [[ -n "$seven_reset" ]] && echo "7d resets at:    $seven_reset"
    fi

    return 0
}

# Usage statistics
cmd_stats() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        exit 0
    fi

    echo "Usage Statistics"
    echo "================"
    echo ""
    printf "%-6s %-30s %-8s %-15s %s\n" "Acct" "Email" "Switches" "Total Time" "Last Used"
    printf "%-6s %-30s %-8s %-15s %s\n" "----" "-----" "--------" "----------" "---------"

    local accounts
    accounts=$(jq -r '.accounts | to_entries[] | "\(.key)|\(.value.email)|\(.value.switchCount // 0)|\(.value.totalSeconds // 0)|\(.value.lastUsed // "never")"' "$SEQUENCE_FILE")

    while IFS='|' read -r num email switches total_secs last_used; do
        [[ -z "$num" ]] && continue
        # Format total time
        local time_str
        if [[ "$total_secs" -eq 0 ]]; then
            time_str="-"
        elif [[ "$total_secs" -lt 3600 ]]; then
            time_str="${total_secs}s"
        elif [[ "$total_secs" -lt 86400 ]]; then
            time_str="$((total_secs / 3600))h $((total_secs % 3600 / 60))m"
        else
            time_str="$((total_secs / 86400))d $((total_secs % 86400 / 3600))h"
        fi

        # Truncate email if too long
        local display_email="$email"
        if [[ ${#email} -gt 28 ]]; then
            display_email="${email:0:25}..."
        fi

        # Format last_used
        local display_last="$last_used"
        if [[ "$last_used" != "never" && ${#last_used} -gt 15 ]]; then
            display_last="${last_used:0:16}"
        fi

        printf "%-6s %-30s %-8s %-15s %s\n" "$num" "$display_email" "$switches" "$time_str" "$display_last"
    done <<< "$accounts"
}

# Set profile name for an account
cmd_set_profile() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: ccs profile <account_number|email> <profile_name>"
        exit 1
    fi

    local identifier="$1"
    local profile_name="$2"

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local account_num
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: Account '$identifier' not found"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    # Check for duplicate profile names
    local existing
    existing=$(jq -r --arg profile "$profile_name" --arg num "$account_num" '.accounts | to_entries[] | select(.value.profile == $profile and .key != $num) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        echo "Error: Profile name '$profile_name' is already used by Account-$existing"
        exit 1
    fi

    local updated
    updated=$(jq --arg num "$account_num" --arg profile "$profile_name" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].profile = $profile |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated"

    local email
    email=$(echo "$account_info" | jq -r '.email')
    echo "Set profile name for Account-$account_num ($email): $profile_name"
}

# Directory-based auto-switch: set mapping
cmd_set_dir_account() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: ccs dir [directory] <account_number|email|profile>"
        exit 1
    fi

    local dir account_id

    if [[ $# -ge 2 ]]; then
        dir="$1"
        account_id="$2"
    else
        dir="$(pwd)"
        account_id="$1"
    fi

    # Resolve to absolute path
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        echo "Error: Directory '$dir' does not exist"
        exit 1
    }

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local account_num
    account_num=$(resolve_account_identifier "$account_id")
    if [[ -z "$account_num" ]]; then
        echo "Error: Account '$account_id' not found"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    setup_directories

    # Initialize dir-accounts.json if needed
    if [[ ! -f "$DIR_ACCOUNTS_FILE" ]]; then
        write_json "$DIR_ACCOUNTS_FILE" '{}'
    fi

    local updated
    updated=$(jq --arg dir "$dir" --arg num "$account_num" '
        .[$dir] = ($num | tonumber)
    ' "$DIR_ACCOUNTS_FILE")

    write_json "$DIR_ACCOUNTS_FILE" "$updated"

    local email
    email=$(echo "$account_info" | jq -r '.email')
    echo "Directory '$dir' mapped to Account-$account_num ($email)"
}

# Directory-based auto-switch: check and switch
cmd_auto_switch() {
    if [[ ! -f "$DIR_ACCOUNTS_FILE" ]]; then
        echo "No directory-account mappings configured."
        echo "Use 'ccs dir' to create mappings."
        exit 0
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_dir
    current_dir="$(pwd)"

    # Check current directory and parent directories for a mapping
    local check_dir="$current_dir"
    local target_account=""

    while true; do
        target_account=$(jq -r --arg dir "$check_dir" '.[$dir] // empty' "$DIR_ACCOUNTS_FILE" 2>/dev/null)
        if [[ -n "$target_account" ]]; then
            break
        fi
        local parent
        parent="$(dirname "$check_dir")"
        if [[ "$parent" == "$check_dir" ]]; then
            break  # Reached root
        fi
        check_dir="$parent"
    done

    if [[ -z "$target_account" ]]; then
        echo "No account mapping found for $current_dir (or any parent directory)."
        exit 0
    fi

    # Check if already on the right account
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    if [[ "$active_account" == "$target_account" ]]; then
        local email
        email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
        echo "Already on Account-$target_account ($email) for this directory."
        exit 0
    fi

    local email
    email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    echo "Directory mapping found: switching to Account-$target_account ($email)"
    perform_switch "$target_account"
}

# Add account
cmd_add_account() {
    local account_type=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                account_type="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    setup_directories
    init_sequence_file

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    if [[ -z "$account_type" && -t 0 ]]; then
        echo -n "Account type [team/max20, empty=skip]: "
        read -r account_type
    fi
    if [[ -n "$account_type" && "$account_type" != "team" && "$account_type" != "max20" ]]; then
        echo "Error: Invalid account type '$account_type'. Use 'team' or 'max20'."
        exit 1
    fi

    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")

    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg type "$account_type" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: $now
        } |
        (if ($type | length) > 0 then .accounts[$num].accountType = $type else . end) |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ccs rm <account_number|email>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi

        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi

    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi

    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response

    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run 'ccs add' later."
        return 1
    fi

    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)

    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi

    echo "Accounts:"

    local accounts
    accounts=$(jq -r '.sequence[] as $num | "\($num)|\(.accounts["\($num)"].email)|\(.accounts["\($num)"].profile // "")|\(.accounts["\($num)"].accountType // "")"' "$SEQUENCE_FILE")

    while IFS='|' read -r num email profile account_type; do
        [[ -z "$num" ]] && continue
        local prof="" type="" active="" usage_line reset_line
        [[ -n "$profile" ]] && prof=" [$profile]"
        [[ -n "$account_type" ]] && type=" {$account_type}"
        [[ "$num" == "$active_account_num" ]] && active=" (active)"

        echo "  ${num}: ${email}${prof}${type}${active}"

        usage_line=$(format_usage_snapshot "$num" "$email")
        reset_line=$(format_usage_resets_snapshot "$num")
        [[ -n "$usage_line" ]] && echo "      usage: ${usage_line}"
        [[ -n "$reset_line" ]] && echo "      reset: ${reset_line}"
    done <<< "$accounts"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi

    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi

    # wait_for_claude_close

    local active_account next_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    next_account=$(jq -r --argjson active "$active_account" '
        . as $root |
        .sequence as $seq |
        ($seq | index($active) // 0) as $idx |
        [range(1; ($seq | length) + 1) as $offset |
            $seq[($idx + $offset) % ($seq | length)] |
            select((. as $n | ($root.accounts["\($n)"].authState // "") != "invalid"))
        ][0] // empty
    ' "$SEQUENCE_FILE")

    if [[ -z "$next_account" ]]; then
        echo "Error: no usable account found (all other accounts are marked authState=invalid)"
        exit 1
    fi

    CCS_SWITCH_REASON=manual perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ccs to <account_number|email|profile>"
        exit 1
    fi

    local identifier="$1"
    local target_account

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Resolve identifier (number, email, or profile name)
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        # Provide specific error for email-like input vs invalid format
        if [[ "$identifier" =~ @ ]]; then
            echo "Error: No account found with email: $identifier"
        elif [[ ! "$identifier" =~ ^[0-9]+$ ]]; then
            if validate_email "$identifier" 2>/dev/null; then
                echo "Error: No account found matching: $identifier"
            else
                echo "Error: Invalid email format: $identifier"
            fi
        else
            echo "Error: No account found matching: $identifier"
        fi
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    # wait_for_claude_close
    CCS_SWITCH_REASON=manual perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    local switch_reason="${CCS_SWITCH_REASON:-}"
    local cache_file="/tmp/claude-usage-cache.json"

    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    # Dry-run mode: show what would happen and return
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would switch from Account-$current_account ($current_email) to Account-$target_account ($target_email)"
        echo "[DRY RUN] Steps that would be performed:"
        echo "  1. Backup current credentials and config for Account-$current_account"
        echo "  2. Restore credentials and config from Account-$target_account backup"
        echo "  3. Update active account in sequence.json"
        echo "  4. Update usage statistics"
        return
    fi

    # Serialize the switch: take the lock, then RE-READ the authoritative active
    # account under it (another switch may have landed since the reads above).
    if ! acquire_switch_lock 10; then
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Error: another account switch is in progress (could not acquire lock)."
        else
            echo "Error: switch lock busy; skipping." >&2
        fi
        exit 1
    fi
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    local real_current_account
    real_current_account=$(jq -r --arg email "$current_email" '
        (.accounts | to_entries[] | select(.value.email == $email) | .key) // empty
    ' "$SEQUENCE_FILE" 2>/dev/null)
    local current_account_is_managed=true
    if [[ -z "$real_current_account" ]]; then
        current_account_is_managed=false
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Notice: active account ($current_email) is not managed. Switching directly to Account-$target_account without updating source-account stats/backups."
        fi
    elif [[ "$real_current_account" != "$current_account" ]]; then
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Note: corrected active account $current_account -> $real_current_account (source: live Claude config)."
        fi
        current_account="$real_current_account"
    fi

    # No-op guard: if we're already on the target (e.g. a concurrent switch beat
    # us to it), release and return without thrashing the credential store.
    if [[ "$current_account_is_managed" == true && "$current_account" == "$target_account" ]]; then
        release_switch_lock
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Already on Account-$target_account ($target_email)."
        fi
        return
    fi

    # Save pre-switch state for rollback
    local rollback_creds rollback_config rollback_sequence
    rollback_creds=$(read_credentials)
    rollback_config=$(cat "$(get_claude_config_path)")
    rollback_sequence=$(cat "$SEQUENCE_FILE")

    # Rollback function
    rollback() {
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo ""
            echo "Error: Switch failed. Rolling back to previous state..."
        else
            echo "Error: Switch failed. Rolling back..." >&2
        fi
        write_credentials "$rollback_creds" 2>/dev/null || true
        write_json "$(get_claude_config_path)" "$rollback_config" 2>/dev/null || true
        write_json "$SEQUENCE_FILE" "$rollback_sequence" 2>/dev/null || true
        release_switch_lock
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Rollback complete. Account-$current_account ($current_email) is still active."
        else
            echo "Rollback complete." >&2
        fi
    }

    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ "$current_account_is_managed" == true ]]; then
        if ! write_account_credentials "$current_account" "$current_email" "$current_creds"; then
            rollback
            exit 1
        fi
        if ! write_account_config "$current_account" "$current_email" "$current_config"; then
            rollback
            exit 1
        fi
    fi

    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")

    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        rollback
        exit 1
    fi

    # Step 3: Activate target account
    if ! write_credentials "$target_creds"; then
        rollback
        exit 1
    fi

    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        rollback
        exit 1
    fi

    # Merge with current config and validate
    local merged_config
    if ! merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null); then
        echo "Error: Failed to merge config"
        rollback
        exit 1
    fi

    if ! write_json "$(get_claude_config_path)" "$merged_config"; then
        rollback
        exit 1
    fi

    # Step 4: Update state and usage statistics
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local now_epoch
    now_epoch=$(date +%s)

    # Calculate time spent on the old account (since last switch)
    local last_updated_str elapsed_seconds=0
    last_updated_str=$(jq -r '.lastUpdated // empty' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$last_updated_str" ]]; then
        local last_epoch
        # Portable date parsing (macOS vs Linux)
        if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_updated_str" +%s >/dev/null 2>&1; then
            last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_updated_str" +%s 2>/dev/null || echo "0")
        else
            last_epoch=$(date -d "$last_updated_str" +%s 2>/dev/null || echo "0")
        fi
        if [[ "$last_epoch" -gt 0 ]]; then
            elapsed_seconds=$((now_epoch - last_epoch))
            if [[ $elapsed_seconds -lt 0 ]]; then
                elapsed_seconds=0
            fi
        fi
    fi

    local updated_sequence
    if [[ "$current_account_is_managed" == true ]]; then
        updated_sequence=$(jq \
            --arg num "$target_account" \
            --arg cur "$current_account" \
            --arg now "$now" \
            --arg reason "$switch_reason" \
            --argjson elapsed "$elapsed_seconds" '
            # Update time on old account
            .accounts[$cur].totalSeconds = ((.accounts[$cur].totalSeconds // 0) + $elapsed) |
            .accounts[$cur].lastUsed = $now |
            # Increment switch count on target
            .accounts[$num].switchCount = ((.accounts[$num].switchCount // 0) + 1) |
            .accounts[$num].lastUsed = $now |
            # Update active account
            .activeAccountNumber = ($num | tonumber) |
            .lastUpdated = $now |
            (if $reason == "auto" then .lastAutoSwitchAt = $now else . end) |
            (if $reason == "manual" then .lastManualSwitchAt = $now else . end)
        ' "$SEQUENCE_FILE")
    else
        updated_sequence=$(jq \
            --arg num "$target_account" \
            --arg now "$now" \
            --arg reason "$switch_reason" '
            .accounts[$num].switchCount = ((.accounts[$num].switchCount // 0) + 1) |
            .accounts[$num].lastUsed = $now |
            .activeAccountNumber = ($num | tonumber) |
            .lastUpdated = $now |
            (if $reason == "auto" then .lastAutoSwitchAt = $now else . end) |
            (if $reason == "manual" then .lastManualSwitchAt = $now else . end)
        ' "$SEQUENCE_FILE")
    fi

    if ! write_json "$SEQUENCE_FILE" "$updated_sequence"; then
        rollback
        exit 1
    fi
    clear_account_auth_invalid "$target_account"

    # Invalidate any stale usage cache from the previous account immediately.
    # The next hook/statusline pass must fetch fresh usage for the new account.
    rm -f "$cache_file" 2>/dev/null || true

    if [[ "$current_account_is_managed" == true ]]; then
        coord_release_account_state "$current_email"
    fi

    # Best effort: once the target account is active, refresh its usage snapshot
    # immediately. On this host non-active backup credentials are unreliable, but
    # active-account usage reads are reliable enough to seed ladder decisions.
    if [[ "${CCS_SKIP_POST_SWITCH_USAGE_FETCH:-0}" != "1" ]]; then
        local live_cache
        live_cache=$(mktemp "/tmp/ccs-switch-${target_account}-XXXXXX.json")
        fetch_usage_for_account "$target_account" "$target_email" "$target_creds" "$live_cache" >/dev/null 2>&1 || true
        rm -f "$live_cache" 2>/dev/null || true
    fi

    coord_publish_account_state "$target_account" "$target_email"

    if [[ "${CCS_HEADLESS_SMOKE:-0}" == "1" ]]; then
        if ! headless_auth_smoke; then
            mark_account_auth_invalid "$target_account" "headless auth smoke failed"
            rollback
            exit 1
        fi
    fi

    # Switch is committed; release the lock before any interactive display/restart
    # so we never hold it while waiting on the user.
    release_switch_lock

    if [[ "${CCS_SILENT:-}" != "1" ]]; then
        echo "Switched to Account-$target_account ($target_email)"
        # Display updated account list
        cmd_list
        echo ""

        # Handle restart
        handle_restart_after_switch
    fi
}

# Fetch usage data from Anthropic OAuth Usage API
# Writes to /tmp/claude-usage-cache.json with active_account field
# Returns 0 on success, 1 on failure
fetch_usage_data() {
    local cache_file="/tmp/claude-usage-cache.json"
    local current_email
    current_email=$(get_current_account)

    # Read credentials and extract access token
    local creds access_token
    creds=$(read_credentials)
    if [[ -z "$creds" ]]; then
        return 1
    fi

    access_token=$(credential_access_token "$creds")
    if [[ -z "$access_token" ]]; then
        return 1
    fi

    # Call the usage API
    local response http_code
    response=$(curl -sS -w "\n%{http_code}" \
        -H "Authorization: Bearer $access_token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    # Handle token refresh on 401
    if [[ "$http_code" == "401" ]]; then
        local refresh_token client_id
        refresh_token=$(credential_refresh_token "$creds")
        client_id="9d1c250a-e61b-44d9-88ed-5944d1962f5e"

        if [[ -z "$refresh_token" ]]; then
            return 1
        fi

        local refresh_response refresh_code
        refresh_response=$(curl -sS -w "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$refresh_token\",\"client_id\":\"$client_id\"}" \
            "https://console.anthropic.com/v1/oauth/token" 2>/dev/null) || return 1

        refresh_code=$(echo "$refresh_response" | tail -n1)
        local refresh_body
        refresh_body=$(echo "$refresh_response" | sed '$d')

        if [[ "$refresh_code" != "200" ]]; then
            return 1
        fi

        # Update stored credentials with new tokens
        local new_access new_refresh updated_creds
        new_access=$(echo "$refresh_body" | jq -r '.access_token // empty' 2>/dev/null)
        new_refresh=$(echo "$refresh_body" | jq -r '.refresh_token // empty' 2>/dev/null)

        if [[ -z "$new_access" ]]; then
            return 1
        fi

        updated_creds=$(update_credential_tokens "$creds" "$new_access" "${new_refresh:-$refresh_token}")
        write_credentials "$updated_creds"

        # Retry the usage API with new token
        response=$(curl -sS -w "\n%{http_code}" \
            -H "Authorization: Bearer $new_access" \
            -H "anthropic-beta: oauth-2025-04-20" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
    fi

    if [[ "$http_code" != "200" ]]; then
        return 1
    fi

    # Validate response JSON
    if ! echo "$body" | jq . >/dev/null 2>&1; then
        return 1
    fi

    # Write cache with active_account and timestamp
    local cache_content
    cache_content=$(echo "$body" | jq \
        --arg email "$current_email" \
        --arg ts "$(date +%s)" \
        '. + {active_account: $email, cached_at: ($ts | tonumber)}' 2>/dev/null) || return 1

    echo "$cache_content" > "$cache_file"
    update_account_usage_snapshot "$current_email" "$cache_file"
    return 0
}

# Rate limit check command
# Usage: ccs rate-check [--threshold N] [--auto-switch] [--hook-mode] [--refresh] [--max-age SECONDS]
# Exit codes: 0=ok, 1=exceeded (switched if --auto-switch), 2=error, 3=all accounts limited
cmd_rate_check() {
    # Serialize the ENTIRE decision loop (usage check -> reclaim/switch
    # candidates), not just individual perform_switch writes. The statusline
    # spawns this in the background on every render with no dedup, so without
    # a whole-call lock, overlapping invocations interleave: each reads a
    # different in-flight active-account state and both drive perform_switch
    # on the same target accounts concurrently, corrupting credential files.
    # Non-blocking: a busy lock means another invocation is already running
    # the exact same decision, so just skip rather than queue and thrash.
    if ! acquire_switch_lock 0; then
        [[ "${CCS_SILENT:-}" == "1" ]] || echo "rate-check already running elsewhere, skipping." >&2
        return 0
    fi
    export CCS_LOCK_HELD=1
    trap 'release_switch_lock; unset CCS_LOCK_HELD' RETURN EXIT

    local threshold=""
    local auto_switch=false
    local hook_mode=false
    local refresh=false
    local max_age=""
    local cache_file="/tmp/claude-usage-cache.json"

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                threshold="$2"
                shift 2
                ;;
            --auto-switch)
                auto_switch=true
                shift
                ;;
            --hook-mode)
                hook_mode=true
                shift
                ;;
            --refresh)
                refresh=true
                shift
                ;;
            --max-age)
                max_age="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Read threshold from config if not explicitly passed via --threshold
    if [[ -z "$threshold" ]]; then
        if [[ -f "$SEQUENCE_FILE" ]]; then
            local cfg_threshold
            cfg_threshold=$(jq -r '.rateLimit.threshold // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
            if [[ -n "$cfg_threshold" ]]; then
                threshold="$cfg_threshold"
            fi
        fi
        # Default if neither flag nor config provided
        threshold="${threshold:-80}"
    fi

    # Resolve cache TTL: --max-age flag > .rateLimit.cacheTtl config > default
    if [[ -z "$max_age" ]]; then
        if [[ -f "$SEQUENCE_FILE" ]]; then
            local cfg_ttl
            cfg_ttl=$(jq -r '.rateLimit.cacheTtl // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
            [[ -n "$cfg_ttl" ]] && max_age="$cfg_ttl"
        fi
        max_age="${max_age:-$DEFAULT_CACHE_TTL}"
    fi

    local current_email
    current_email=$(get_current_account)

    # Decide whether we need fresh data: forced, or the cache is missing / stale /
    # for a different account than the one currently active. This is what makes the
    # headless (`claude -p`, no statusline) path work — the cache is refreshed on
    # demand instead of silently no-oping on a missing/stale file.
    local need_fetch=false
    if [[ "$refresh" == true ]]; then
        need_fetch=true
    elif [[ "$(cache_freshness "$cache_file" "$max_age" "$current_email")" == "stale" ]]; then
        need_fetch=true
    fi

    if [[ "$need_fetch" == true ]]; then
        if ! fetch_usage_data; then
            if [[ "$hook_mode" == true ]]; then
                exit 0  # Fail open
            fi
            # If a usable (if stale) cache exists, fall back to it rather than error.
            if [[ ! -f "$cache_file" ]]; then
                echo "Error: Failed to fetch usage data and no cache available" >&2
                exit 2
            fi
            echo "Warning: usage refresh failed; using cached data" >&2
        fi
    fi

    # Cache must exist past this point
    if [[ ! -f "$cache_file" ]]; then
        if [[ "$hook_mode" == true ]]; then
            exit 0  # Fail open
        fi
        echo "Error: No usage cache found at $cache_file" >&2
        exit 2
    fi

    # Read utilization
    local usage usage_int usage_summary usage_source
    usage=$(effective_usage_percent "$cache_file")
    usage_int=$(printf "%.0f" "$usage" 2>/dev/null || echo "0")
    usage_summary=$(format_usage_windows "$cache_file")
    usage_source=$(effective_usage_source "$cache_file")

    local starting_account reclaim_target=""
    starting_account=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ -n "$starting_account" && "$starting_account" != "null" ]]; then
        reclaim_target=$(should_reclaim_to_preferred_account "$starting_account" "$threshold" 2>/dev/null || true)
        if [[ -n "$reclaim_target" ]]; then
            log_switch_event "reclaim candidate: active=Account-$starting_account target=Account-$reclaim_target usage=${usage_int}% threshold=${threshold}% auto_switch=$auto_switch"
        fi
    fi

    # Below threshold — all good
    if [[ "$usage_int" -lt "$threshold" ]]; then
        if [[ "$auto_switch" == true && -n "$reclaim_target" ]]; then
            local reclaim_email
            reclaim_email=$(jq -r --arg num "$reclaim_target" '.accounts[$num].email // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
            if ! (CCS_SWITCH_REASON=auto CCS_SILENT=1 CCS_SKIP_POST_SWITCH_USAGE_FETCH=1 perform_switch "$reclaim_target"); then
                log_switch_event "reclaim FAILED: Account-$starting_account -> Account-$reclaim_target ($reclaim_email)"
                if [[ "$hook_mode" == true ]]; then
                    exit 0
                fi
                echo "Error: Failed to reclaim preferred account Account-$reclaim_target ($reclaim_email)" >&2
                exit 2
            fi
            log_switch_event "reclaim OK: Account-$starting_account -> Account-$reclaim_target ($reclaim_email), pre-switch usage=${usage_int}%"
            rm -f "$cache_file"
            fetch_usage_data >/dev/null 2>&1 || true
            if [[ "$hook_mode" == true ]]; then
                _rate_hook_deny "Switched back to preferred account Account-$reclaim_target ($reclaim_email). Please restart Claude Code."
                exit 0
            fi
            echo "Switched back to preferred account Account-$reclaim_target ($reclaim_email)"
            handle_restart_after_switch
            exit 1
        fi
        if [[ "$hook_mode" != true ]]; then
            echo "Usage: ${usage_summary} (threshold: ${threshold}% on ${usage_source}) — OK"
        fi
        exit 0
    fi

    # Above threshold
    if [[ "$hook_mode" != true ]]; then
        echo "Usage: ${usage_summary} exceeds threshold ${threshold}% on ${usage_source}"
    fi
    log_switch_event "threshold exceeded: active=Account-${starting_account:-?} usage=${usage_int}% threshold=${threshold}% auto_switch=$auto_switch"

    if [[ "$auto_switch" == true ]]; then
        if [[ ! -f "$SEQUENCE_FILE" ]]; then
            if [[ "$hook_mode" == true ]]; then
                exit 0  # Fail open
            fi
            echo "Error: No accounts configured" >&2
            exit 2
        fi

        local total_accounts
        total_accounts=$(jq '.sequence | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")

        if [[ "$total_accounts" -lt 2 ]]; then
            if [[ "$hook_mode" == true ]]; then
                _rate_hook_deny "Rate limit exceeded (${usage_int}%). No other accounts to switch to."
                exit 0
            fi
            echo "Only one account configured, cannot auto-switch" >&2
            exit 3
        fi

        # Try switching to next accounts, prioritizing team accounts before max20.
        local attempts=0
        local max_attempts=$((total_accounts - 1))
        starting_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

        while IFS= read -r next_account; do
            [[ -z "$next_account" ]] && continue
            local next_email
            next_email=$(jq -r --arg num "$next_account" '.accounts[$num].email' "$SEQUENCE_FILE")

            # Claim the account atomically BEFORE switching. On a 409 conflict
            # (return 2) another server grabbed it first — skip to the next
            # candidate instead of colliding. On coordinator-unavailable
            # (return 1) fail open and switch anyway, so a down coordinator
            # degrades to the old autonomous behaviour rather than blocking.
            if [[ -n "$next_email" && "$next_email" != "null" ]]; then
                coord_try_claim_exclusive "$next_account" "$next_email"
                if [[ $? -eq 2 ]]; then
                    log_switch_event "candidate Account-$next_account ($next_email) skipped: coordinator claim conflict (another server holds it)"
                    attempts=$((attempts + 1))
                    [[ $attempts -ge $max_attempts ]] && break
                    continue
                fi
            fi

            log_switch_event "attempting switch: Account-$starting_account -> Account-$next_account ($next_email)"
            # Perform switch in subshell to catch exit 1 from perform_switch
            if ! (CCS_SWITCH_REASON=auto CCS_SILENT=1 CCS_SKIP_POST_SWITCH_USAGE_FETCH=1 perform_switch "$next_account"); then
                # Switch failed — fail open in hook mode
                log_switch_event "switch FAILED: Account-$starting_account -> Account-$next_account ($next_email)"
                if [[ "$hook_mode" == true ]]; then
                    exit 0
                fi
                echo "Error: Failed to switch to Account-$next_account ($next_email)" >&2
                exit 2
            fi

            # Invalidate cache and re-fetch for new account
            rm -f "$cache_file"
            if fetch_usage_data; then
                local new_usage new_usage_int
                new_usage=$(effective_usage_percent "$cache_file")
                new_usage_int=$(printf "%.0f" "$new_usage" 2>/dev/null || echo "0")

                if [[ "$new_usage_int" -lt "$threshold" ]]; then
                    # Successfully switched to an account under the threshold
                    log_switch_event "switch OK: Account-$starting_account -> Account-$next_account ($next_email), post-switch usage=${new_usage_int}%"
                    if [[ "$hook_mode" == true ]]; then
                        _rate_hook_deny "Rate limit exceeded. Switched to Account-$next_account ($next_email). Please restart Claude Code."
                        exit 0
                    fi
                    local new_usage_summary
                    new_usage_summary=$(format_usage_windows "$cache_file")
                    echo "Switched to Account-$next_account ($next_email) — usage: ${new_usage_summary}"
                    handle_restart_after_switch
                    exit 1
                fi
                log_switch_event "candidate Account-$next_account ($next_email) still over threshold post-switch: ${new_usage_int}% — trying next"
            else
                # Can't verify new account's usage, assume it's OK
                log_switch_event "switch OK (usage unverifiable): Account-$starting_account -> Account-$next_account ($next_email)"
                if [[ "$hook_mode" == true ]]; then
                    _rate_hook_deny "Rate limit exceeded. Switched to Account-$next_account ($next_email). Please restart Claude Code."
                    exit 0
                fi
                echo "Switched to Account-$next_account ($next_email) — could not verify usage"
                handle_restart_after_switch
                exit 1
            fi

            attempts=$((attempts + 1))
            [[ $attempts -ge $max_attempts ]] && break
        done < <(auto_switch_candidates "$starting_account" "$threshold")

        # Restore the original account before reporting "all limited".
        local current_active
        current_active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        if [[ "$current_active" != "$starting_account" ]]; then
            log_switch_event "restoring original Account-$starting_account after exhausting all candidates"
            CCS_SILENT=1 CCS_SKIP_POST_SWITCH_USAGE_FETCH=1 perform_switch "$starting_account" >/dev/null 2>&1 || true
        fi

        # All accounts are limited
        log_switch_event "all accounts above threshold (${threshold}%), staying on Account-$starting_account"
        if [[ "$hook_mode" == true ]]; then
            _rate_hook_deny "Rate limit exceeded on all accounts (${usage_int}%). Please wait for limits to reset."
            exit 0
        fi
        echo "All accounts are above the threshold" >&2
        exit 3
    fi

    # No auto-switch, just report
    if [[ "$hook_mode" == true ]]; then
        _rate_hook_deny "Rate limit exceeded (${usage_int}%). Run 'ccs sw' to switch accounts."
        exit 0
    fi
    exit 1
}

# Output hook-protocol JSON to deny a tool call
_rate_hook_deny() {
    local reason="$1"
    if [[ "${CCS_SUPPRESS_HOOK_MESSAGE:-0}" == "1" ]]; then
        return 0
    fi
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
}

# Rate limit auto-switch setup
# Usage: ccs rate-setup [--threshold N] [--disable]
cmd_rate_setup() {
    local threshold=80
    local disable=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                threshold="$2"
                shift 2
                ;;
            --disable)
                disable=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    setup_directories
    init_sequence_file

    local settings_file="$HOME/.claude/settings.json"

    # Determine hook script path
    local hook_script
    hook_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks/ccs-rate-hook.sh"

    if [[ "$disable" == true ]]; then
        # Disable: update config and remove hook
        local updated
        updated=$(jq '.rateLimit = {enabled: false}' "$SEQUENCE_FILE" 2>/dev/null)
        write_json "$SEQUENCE_FILE" "$updated"

        # Remove hook from settings.json if present (match by hook script
        # path). Handles both the legacy flat shape and the nested-hooks shape,
        # and drops matcher entries whose nested hooks array becomes empty.
        if [[ -f "$settings_file" ]]; then
            local cleaned
            cleaned=$(jq --arg hook "$hook_script" '
                if .hooks and .hooks.PreToolUse then
                    .hooks.PreToolUse = [
                        .hooks.PreToolUse[]
                        # drop legacy flat entries referencing the hook
                        | select(((.command // "") | contains($hook)) | not)
                        # strip the hook from nested handler arrays
                        | (if has("hooks") then
                               .hooks = (.hooks | map(select((.command // "") | contains($hook) | not)))
                           else . end)
                        # drop entries whose nested hooks array is now empty
                        | select((has("hooks") | not) or ((.hooks | length) > 0))
                    ]
                else . end
            ' "$settings_file" 2>/dev/null)
            if [[ -n "$cleaned" ]]; then
                echo "$cleaned" | jq . > "$settings_file"
            fi
        fi

        echo "Rate limit auto-switch disabled."
        echo "Hook removed from $settings_file"
        return
    fi

    # Enable: update config
    local updated
    updated=$(jq --argjson thresh "$threshold" '
        .rateLimit = {enabled: true, threshold: $thresh}
    ' "$SEQUENCE_FILE" 2>/dev/null)
    write_json "$SEQUENCE_FILE" "$updated"

    # Check hook script exists
    if [[ ! -f "$hook_script" ]]; then
        echo "Warning: Hook script not found at $hook_script"
        echo "Make sure you have the hooks/ccs-rate-hook.sh file installed."
        return 1
    fi

    # Install hook into settings.json
    mkdir -p "$(dirname "$settings_file")"
    if [[ ! -f "$settings_file" ]]; then
        echo '{}' > "$settings_file"
    fi

    # Resolve absolute path to this script (ccs binary) for CCS_PATH
    local ccs_bin
    ccs_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Build hook command with CCS_PATH so the hook can reliably find ccs
    local hook_command="CCS_PATH=${ccs_bin} ${hook_script}"

    # Check if hook already exists (idempotent) — match by hook script path.
    # Detect both the legacy flat shape ({matcher, command}) and the correct
    # nested shape ({matcher, hooks: [{type, command}]}).
    local hook_exists
    hook_exists=$(jq --arg hook "$hook_script" '
        [ .hooks.PreToolUse // [] | .[]
          | ( (.command // empty), ( .hooks // [] | .[] | .command // empty ) )
        ] | map(select(contains($hook))) | length
    ' "$settings_file" 2>/dev/null || echo "0")

    if [[ "$hook_exists" == "0" ]]; then
        # Write the Claude Code hook schema: a matcher entry containing a
        # nested "hooks" array of command handlers. matcher "" matches all tools.
        local with_hook
        with_hook=$(jq --arg hook "$hook_command" '
            .hooks.PreToolUse = (.hooks.PreToolUse // []) + [
                {
                    "matcher": "",
                    "hooks": [
                        {
                            "type": "command",
                            "command": $hook
                        }
                    ]
                }
            ]
        ' "$settings_file" 2>/dev/null)
        echo "$with_hook" | jq . > "$settings_file"
    fi

    echo "Rate limit auto-switch enabled."
    echo "  Threshold: ${threshold}%"
    echo "  Hook script: $hook_script"
    echo "  Settings: $settings_file"
}

# Install (or remove) the statusline that shows usage and keeps the cache warm.
# Usage: ccs statusline-setup [--disable]
cmd_statusline_setup() {
    local disable=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disable)
                disable=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local settings_file="$HOME/.claude/settings.json"
    local statusline_script
    statusline_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline/ccs-statusline.sh"

    if [[ "$disable" == true ]]; then
        # Only remove the statusLine if it's ours (command references our script),
        # so we never clobber a user's own statusline.
        if [[ -f "$settings_file" ]]; then
            local cleaned
            cleaned=$(jq --arg s "$statusline_script" '
                if (.statusLine.command // "") | contains($s)
                then del(.statusLine) else . end
            ' "$settings_file" 2>/dev/null)
            if [[ -n "$cleaned" ]]; then
                echo "$cleaned" | jq . > "$settings_file"
            fi
        fi
        echo "ccs statusline disabled."
        echo "Settings: $settings_file"
        return
    fi

    if [[ ! -f "$statusline_script" ]]; then
        echo "Warning: statusline script not found at $statusline_script"
        echo "Make sure you have the statusline/ccs-statusline.sh file installed."
        return 1
    fi

    mkdir -p "$(dirname "$settings_file")"
    [[ -f "$settings_file" ]] || echo '{}' > "$settings_file"

    # Resolve absolute path to this script (ccs) so the statusline can find it.
    local ccs_bin
    ccs_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local sl_command="CCS_PATH=${ccs_bin} ${statusline_script}"

    # Warn (but proceed) if a different statusline is already configured.
    local existing
    existing=$(jq -r '.statusLine.command // empty' "$settings_file" 2>/dev/null || true)
    if [[ -n "$existing" && "$existing" != *"$statusline_script"* ]]; then
        echo "Note: replacing an existing statusLine command:"
        echo "  was: $existing"
    fi

    local with_sl
    with_sl=$(jq --arg cmd "$sl_command" '
        .statusLine = {"type": "command", "command": $cmd}
    ' "$settings_file" 2>/dev/null)
    echo "$with_sl" | jq . > "$settings_file"

    echo "ccs statusline enabled."
    echo "  Statusline script: $statusline_script"
    echo "  Settings: $settings_file"
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code v${VERSION}"
    echo "Usage: ccs [OPTIONS] <command> [args]"
    echo ""
    echo "Account Management:"
    echo "  add [--type team|max20]          Add current account to managed accounts"
    echo "  rm <num|email>                   Remove account by number or email"
    echo "  ls                               List all managed accounts"
    echo ""
    echo "Switching:"
    echo "  sw                               Rotate to next account in sequence"
    echo "  to <num|email|profile>           Switch to specific account"
    echo ""
    echo "Profile Management:"
    echo "  profile <num|email> <name>       Set a friendly profile name for an account"
    echo ""
    echo "Directory-based Switching:"
    echo "  dir [dir] <num|email|profile>    Associate a directory with an account"
    echo "  auto                             Switch based on current directory mapping"
    echo ""
    echo "Rate Limiting:"
    echo "  rate-check [--threshold N]       Check if usage exceeds threshold"
    echo "  rate-setup [--threshold N]       Install PreToolUse hook for auto-switch"
    echo "  rate-setup --disable             Remove hook and disable auto-switch"
    echo "  statusline-setup                 Install statusline (shows usage, keeps cache warm)"
    echo "  statusline-setup --disable       Remove the ccs statusline"
    echo "  warm-check                       Refresh all accounts, ping just-reset 5h windows once"
    echo "  warm-loop                        Run warm-check every 60s"
    echo "  coord-setup                      Configure HTTP/MySQL coordination"
    echo "  coord-client-setup               One-command client setup for other servers"
    echo "  coord-client-command             Print copy-paste command for other servers"
    echo "  coord-token                      Print coordinator API token"
    echo "  coord-sync                       Publish current active lease to coordinator"
    echo ""
    echo "Diagnostics:"
    echo "  check                            Verify backup integrity (JSON, permissions, keychain)"
    echo "  status                           Show current account, token expiry, last switch"
    echo "  stats                            Show per-account usage statistics"
    echo ""
    echo "Options:"
    echo "  -n, --dry-run                    Show what would happen without making changes"
    echo "  -r, --restart                    Restart Claude Code after switching"
    echo "  --no-restart                     Skip restart prompt after switching"
    echo "  --allow-root                     Allow running as root (or set CCSWITCH_ALLOW_ROOT=1)"
    echo "  version                          Show version number"
    echo "  help                             Show this help message"
    echo ""
    echo "Examples:"
    echo "  ccs add                                    # Add current account"
    echo "  ccs ls                                     # List accounts"
    echo "  ccs sw                                     # Rotate to next account"
    echo "  ccs to 2                                   # Switch to account 2"
    echo "  ccs to user@example.com                    # Switch by email"
    echo "  ccs to work                                # Switch by profile name"
    echo "  ccs -n sw                                  # Preview switch"
    echo "  ccs sw -r                                  # Switch and restart Claude Code"
    echo "  ccs profile 1 work                         # Name account 1 'work'"
    echo "  ccs dir ~/work 1                           # Map ~/work to account 1"
    echo "  ccs auto                                   # Switch based on current directory"
    echo "  ccs rm user@example.com                    # Remove account"
}

# Main script logic
main() {
    check_dependencies

    # Parse global flags first, collect remaining args
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --restart|-r)
                RESTART_FLAG="restart"
                shift
                ;;
            --no-restart)
                RESTART_FLAG="no-restart"
                shift
                ;;
            --allow-root)
                ALLOW_ROOT=true
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Restore positional parameters from remaining args
    set -- "${args[@]+"${args[@]}"}"

    # Basic checks - allow root execution in containers or via --allow-root
    if should_block_root "$EUID" "$ALLOW_ROOT"; then
        echo "Error: Do not run this script as root."
        echo "If you understand the risks (e.g. sandbox testing), re-run with --allow-root"
        echo "or set CCSWITCH_ALLOW_ROOT=1."
        exit 1
    fi
    if [[ $EUID -eq 0 && "$ALLOW_ROOT" == "true" ]] && ! is_running_in_container; then
        echo "Warning: Running as root (--allow-root). Proceed at your own risk." >&2
    fi

    case "${1:-}" in
        add|--add-account)
            shift
            cmd_add_account "$@"
            ;;
        rm|--remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        ls|--list)
            cmd_list
            ;;
        sw|--switch)
            cmd_switch
            ;;
        to|--switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        profile|--set-profile)
            shift
            cmd_set_profile "$@"
            ;;
        dir|--set-dir-account)
            shift
            cmd_set_dir_account "$@"
            ;;
        auto|--auto-switch)
            cmd_auto_switch
            ;;
        rate-check)
            shift
            cmd_rate_check "$@"
            ;;
        rate-setup)
            shift
            cmd_rate_setup "$@"
            ;;
        statusline-setup)
            shift
            cmd_statusline_setup "$@"
            ;;
        warm-check)
            shift
            cmd_warm_check "$@"
            ;;
        warm-loop)
            shift
            cmd_warm_loop "$@"
            ;;
        coord-setup)
            shift
            cmd_coord_setup "$@"
            ;;
        coord-client-setup)
            shift
            cmd_coord_client_setup "$@"
            ;;
        coord-client-command)
            cmd_coord_client_command
            ;;
        coord-token)
            cmd_coord_token
            ;;
        coord-sync)
            shift
            cmd_coord_sync "$@"
            ;;
        check|--check)
            cmd_check
            ;;
        status|--status)
            cmd_status
            ;;
        stats|--stats)
            cmd_stats
            ;;
        version|--version)
            echo "ccs v${VERSION}"
            ;;
        help|--help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
