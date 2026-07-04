#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    CACHE_FILE="/tmp/claude-usage-cache-test-$$.json"
    rm -f /tmp/claude-usage-cache.json
}

teardown() {
    rm -f "$CACHE_FILE"
    rm -f /tmp/claude-usage-cache.json
    teardown_test_env
}

# Set the recorded 5h entry point for an account (the hysteresis anchor:
# rate-check switches away once live 5h >= entry + RL_MOVE_STEP).
seed_entry_five() {
    local num="$1" val="$2" updated
    updated=$(jq --arg n "$num" --argjson v "$val" '.accounts[$n].entryFiveHour = $v' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"
}

# Seed a candidate account's last-known 5h/7d snapshot so ranking/hard-block
# logic (which reads .accounts[n].lastKnownUsage) can see it as observed.
seed_account_usage() {
    local num="$1" five="$2" seven="${3:-0}" updated
    updated=$(jq --arg n "$num" --argjson f "$five" --argjson s "$seven" --argjson now "$(date +%s)" '
        .accounts[$n].lastKnownUsage = {fiveHour: $f, sevenDay: $s, activeLimit: $f, observedAt: $now}
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"
}

# ---------------------------------------------------------------------------
# Switch trigger: 5h entry+step hysteresis and hard caps
# ---------------------------------------------------------------------------

@test "test_rate_check_stays_when_5h_below_entry_plus_step" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    seed_entry_five "1" 84          # trigger point = 94
    create_fake_usage_cache 90 "user1@example.com"

    # 90 < 94: not time to switch away yet.
    run run_ccswitch rate-check --auto-switch
    [ "$status" -eq 0 ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}

@test "test_rate_check_switches_when_5h_reaches_entry_plus_step" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84          # trigger point = 94
    seed_account_usage "2" 10 5     # healthy candidate
    create_fake_usage_cache 94 "user1@example.com"

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_forced_switch_when_5h_at_cap" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 97          # trigger 98; but 5h=98 also hits hard cap -> forced
    seed_account_usage "2" 10 5
    create_fake_usage_cache 98 "user1@example.com"

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_forced_switch_when_7d_at_cap_even_if_5h_low" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 10          # 5h trigger far away
    seed_account_usage "2" 10 5
    # 5h=30 (low), 7d=99 (hard cap) -> forced switch
    create_fake_usage_cache 30 "user1@example.com" 99

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Candidate selection: hard-block, headroom, ranking
# ---------------------------------------------------------------------------

@test "test_rate_check_skips_hard_blocked_candidate" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    add_account_to_sequence "3" "user3@example.com" "uuid-3" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84
    seed_account_usage "2" 99 5     # hard-blocked (5h >= 98)
    seed_account_usage "3" 20 5     # healthy
    create_fake_usage_cache 94 "user1@example.com"

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 3 ]
}

@test "test_rate_check_skips_candidate_without_headroom_when_not_forced" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84          # trigger 94, active reaches it
    seed_account_usage "2" 90 5     # not hard-blocked, but > accept_max 88 -> no headroom
    create_fake_usage_cache 94 "user1@example.com"

    # No candidate worth moving to and not forced -> stay, fail open (exit 0 hook).
    run run_ccswitch rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}

@test "test_rate_check_forced_accepts_candidate_with_little_headroom" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 97
    seed_account_usage "2" 95 5     # >88 (no normal headroom) but <98 (usable when forced)
    create_fake_usage_cache 98 "user1@example.com"  # forced (5h cap)

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_ranks_lowest_5h_first" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    add_account_to_sequence "3" "user3@example.com" "uuid-3" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84
    seed_account_usage "2" 60 5     # higher 5h
    seed_account_usage "3" 20 90    # lower 5h, high 7d (7d must NOT affect ranking)
    create_fake_usage_cache 94 "user1@example.com"

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Fail-open: never block the user when there's nowhere better
# ---------------------------------------------------------------------------

@test "test_rate_check_all_hard_blocked_fails_open_no_deny" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84
    seed_account_usage "2" 99 5     # only other account is hard-blocked
    create_fake_usage_cache 94 "user1@example.com"

    # Nowhere usable -> fail open (allow), no deny JSON, stay put.
    run run_ccswitch rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}

@test "test_rate_check_single_account_over_cap_fails_open" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    seed_entry_five "1" 97
    create_fake_usage_cache 98 "user1@example.com"  # forced but no other account

    run run_ccswitch rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Hook-mode output protocol
# ---------------------------------------------------------------------------

@test "test_rate_check_hook_mode_silent_on_allow" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    seed_entry_five "1" 40
    create_fake_usage_cache 50 "user1@example.com"

    run run_ccswitch rate-check --hook-mode
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "test_rate_check_hook_mode_deny_json_on_successful_switch" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84
    seed_account_usage "2" 10 5
    create_fake_usage_cache 94 "user1@example.com"

    run run_ccswitch rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    echo "$output" | jq . >/dev/null 2>&1
    local decision reason
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    [ "$decision" = "deny" ]
    [[ "$reason" == *"Switched to Account-2"* ]]
}

@test "test_rate_check_hook_mode_can_suppress_deny_output" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    seed_entry_five "1" 84
    seed_account_usage "2" 10 5
    create_fake_usage_cache 94 "user1@example.com"

    run env HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" CCS_SUPPRESS_HOOK_MESSAGE=1 /bin/bash "$CCSWITCH_SCRIPT" rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Switch still happened; only the message was suppressed.
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_no_cache_returns_2" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    rm -f /tmp/claude-usage-cache.json

    # Offline: a failing fetch with no cache to fall back to -> error exit 2.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Reclaim to a higher-priority sibling when the active account is under trigger
# ---------------------------------------------------------------------------

@test "test_rate_check_reclaims_higher_priority_sibling_when_under_trigger" {
    # Active is a low-priority "other" account under its trigger; a higher
    # priority (team) sibling with lower 5h exists -> reclaim to it.
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "team@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    # Make account 2 team-priority, account 1 other-priority.
    local updated
    updated=$(jq '.accounts["1"].accountType = "other" | .accounts["2"].accountType = "team"' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    seed_entry_five "1" 40          # trigger 50, active below it
    seed_account_usage "2" 10 5     # healthy higher-priority sibling
    create_fake_usage_cache 45 "user1@example.com"

    run run_ccswitch rate-check --auto-switch
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Cache freshness / refetch plumbing (unchanged behavior)
# ---------------------------------------------------------------------------

@test "test_rate_check_stale_cache_account_mismatch_refetches" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Cache belongs to a different account -> must refetch.
    create_fake_usage_cache 50 "other@example.com"
    seed_entry_five "1" 90

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":30,"limit":100,"used":30}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check
    [ "$status" -eq 0 ]
}

# Write a cache at the real path with a custom age (seconds ago) and account.
create_aged_cache() {
    local age="${1:-0}"
    local utilization="${2:-50}"
    local email="${3:-user1@example.com}"
    local ts=$(( $(date +%s) - age ))
    cat > /tmp/claude-usage-cache.json <<EOF
{
  "five_hour": { "utilization": $utilization, "limit": 100, "used": $utilization },
  "active_account": "$email",
  "cached_at": $ts
}
EOF
}

@test "test_rate_check_stale_cache_triggers_refresh" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    seed_entry_five "1" 90

    # 5 min old (older than 60s TTL), shows high usage; refresh returns low.
    create_aged_cache 300 95 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":20,"limit":100,"used":20}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check
    [ "$status" -eq 0 ]
}

@test "test_rate_check_fresh_cache_within_max_age_does_not_fetch" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    seed_entry_five "1" 90
    create_aged_cache 30 50 "user1@example.com"

    # curl FAILS if called -> proves no fetch when cache is fresh.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --max-age 60
    [ "$status" -eq 0 ]
}

@test "test_rate_check_max_age_zero_forces_refresh" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    seed_entry_five "1" 90
    create_aged_cache 1 95 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --max-age 0
    [ "$status" -eq 0 ]
}

@test "test_rate_check_refresh_failure_falls_back_to_stale_cache" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    seed_entry_five "1" 90
    create_aged_cache 300 40 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check
    [ "$status" -eq 0 ]
    [[ "$output" == *"using cached data"* ]]
}

@test "test_warm_check_only_refreshes_active_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":12,"resets_at":"2026-06-19T04:20:00+00:00"},"seven_day":{"utilization":5,"resets_at":"2026-06-23T16:00:00+00:00"},"limits":[{"kind":"session","percent":12,"is_active":true}]}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch warm-check
    [ "$status" -eq 0 ]
    [[ "$output" == *"No account needed warm ping."* ]]

    usage1=$(jq -r '.accounts["1"].lastKnownUsage.fiveHour' "$SEQUENCE_FILE")
    usage2=$(jq -r '.accounts["2"].lastKnownUsage // empty' "$SEQUENCE_FILE")
    [ "$usage1" = "12" ]
    [ -z "$usage2" ]
}
