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

# Helper to create a fake usage cache at the test cache path
# Usage: create_test_cache <utilization> [email]
create_test_cache() {
    local utilization="${1:-50}"
    local email="${2:-user1@example.com}"
    cat > "$CACHE_FILE" <<EOF
{
  "five_hour": {
    "utilization": $utilization,
    "limit": 100,
    "used": $utilization
  },
  "active_account": "$email",
  "cached_at": $(date +%s)
}
EOF
}

@test "test_rate_check_below_threshold_returns_0" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 50 "user1@example.com"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_above_threshold_returns_1" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 1 ]
    [[ "$output" == *"exceeds"* ]]
}

@test "test_rate_check_reports_5h_and_7d_usage" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com" 13

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 1 ]
    [[ "$output" == *"5h 90% | 7d 13%"* ]]
}

@test "test_rate_check_uses_highest_active_limit_when_above_5h" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 0 "user1@example.com" 13 95

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 1 ]
    [[ "$output" == *"limit 95%"* ]]
    [[ "$output" == *"exceeds threshold 80% on limit"* ]]
}

@test "test_rate_check_falls_back_to_seven_day_when_no_active_limit" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    cat > /tmp/claude-usage-cache.json <<EOF
{
  "five_hour": { "utilization": 0 },
  "seven_day": { "utilization": 91 },
  "limits": [
    { "kind": "weekly_all", "percent": 91, "is_active": false }
  ],
  "active_account": "user1@example.com",
  "cached_at": $(date +%s)
}
EOF

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 1 ]
    [[ "$output" == *"exceeds threshold 80% on seven_day"* ]]
}

@test "test_rate_check_no_cache_returns_2" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Ensure no cache file exists
    rm -f /tmp/claude-usage-cache.json

    # Offline: a failing fetch with no cache to fall back to → error exit 2.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check
    [ "$status" -eq 2 ]
}

@test "test_rate_check_custom_threshold_flag" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 50 "user1@example.com"

    # With threshold 40, 50% should exceed
    run run_ccswitch rate-check --threshold 40
    [ "$status" -eq 1 ]

    # With threshold 60, 50% should be OK
    run run_ccswitch rate-check --threshold 60
    [ "$status" -eq 0 ]
}

@test "test_rate_check_custom_threshold_from_config" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Set threshold to 40 in config
    local updated
    updated=$(jq '.rateLimit = {enabled: true, threshold: 40}' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 50 "user1@example.com"

    # 50% should exceed config threshold of 40
    run run_ccswitch rate-check
    [ "$status" -eq 1 ]
}

@test "test_rate_check_hook_mode_outputs_valid_json_on_deny" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    run run_ccswitch rate-check --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    # Validate JSON output
    echo "$output" | jq . >/dev/null 2>&1
    # Check hook protocol fields
    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "test_rate_check_hook_mode_can_suppress_deny_output" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    run env HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" CCS_SUPPRESS_HOOK_MESSAGE=1 /bin/bash "$CCSWITCH_SCRIPT" rate-check --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "test_rate_check_hook_mode_silent_on_allow" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 50 "user1@example.com"

    run run_ccswitch rate-check --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "test_rate_check_auto_switch_rotates_account" {
    # Set up two accounts
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    create_fake_usage_cache 90 "user1@example.com"

    # Mock curl for fetch_usage_data (it will fail, but that's OK — we verify switch happened)
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
# Return a low-usage response for any API call
echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    # Should exit 1 (switched) or could fail on fetch — check switch happened
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_auto_switch_all_limited_returns_3" {
    # Set up two accounts
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    create_fake_usage_cache 90 "user1@example.com"

    # Mock curl to return high usage for all accounts
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 3 ]
}

@test "test_rate_check_auto_switch_prioritizes_team_before_max20" {
    setup_fake_account "max@example.com" "uuid-max"
    add_account_to_sequence "1" "max@example.com" "uuid-max" "true"
    add_account_to_sequence "2" "team1@example.com" "uuid-team1" "false"
    add_account_to_sequence "3" "team2@example.com" "uuid-team2" "false"
    create_fake_credentials "max@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "max20" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team"
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "max@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
if [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 0 > "$HOME/.curl_calls"
fi
calls=$(cat "$HOME/.curl_calls")
calls=$((calls + 1))
echo "$calls" > "$HOME/.curl_calls"
if [[ "$calls" -eq 1 ]]; then
  echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
fi
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_auto_switch_prioritizes_known_zero_usage_team_first" {
    setup_fake_account "max@example.com" "uuid-max"
    add_account_to_sequence "1" "max@example.com" "uuid-max" "true"
    add_account_to_sequence "2" "team-used@example.com" "uuid-team-used" "false"
    add_account_to_sequence "3" "team-fresh@example.com" "uuid-team-fresh" "false"
    create_fake_credentials "max@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "max20" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team" |
        .accounts["2"].lastKnownUsage = {
            fiveHour: 10,
            sevenDay: 0,
            activeLimit: 10,
            observedAt: 123
        } |
        .accounts["3"].lastKnownUsage = {
            fiveHour: 0,
            sevenDay: 0,
            activeLimit: 0,
            observedAt: 123
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "max@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
if [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 0 > "$HOME/.curl_calls"
fi
calls=$(cat "$HOME/.curl_calls")
calls=$((calls + 1))
echo "$calls" > "$HOME/.curl_calls"
if [[ "$calls" -eq 1 ]]; then
  echo '{"five_hour":{"utilization":0,"limit":100,"used":0}}'
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
fi
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 3 ]
}

@test "test_rate_check_auto_switch_holds_group_stage_until_all_team_reach_it" {
    setup_fake_account "max@example.com" "uuid-max"
    add_account_to_sequence "1" "max@example.com" "uuid-max" "true"
    add_account_to_sequence "2" "team-over20@example.com" "uuid-team-over20" "false"
    add_account_to_sequence "3" "team-under20@example.com" "uuid-team-under20" "false"
    create_fake_credentials "max@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "max20" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team" |
        .accounts["2"].lastKnownUsage = {
            fiveHour: 25,
            sevenDay: 0,
            activeLimit: 25,
            observedAt: 123
        } |
        .accounts["3"].lastKnownUsage = {
            fiveHour: 10,
            sevenDay: 0,
            activeLimit: 10,
            observedAt: 123
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "max@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
if [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 0 > "$HOME/.curl_calls"
fi
calls=$(cat "$HOME/.curl_calls")
calls=$((calls + 1))
echo "$calls" > "$HOME/.curl_calls"
if [[ "$calls" -eq 1 ]]; then
  echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
fi
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 3 ]
}

@test "test_rate_check_auto_switch_skips_team_account_leased_by_other_server" {
    setup_fake_account "max@example.com" "uuid-max"
    add_account_to_sequence "1" "max@example.com" "uuid-max" "true"
    add_account_to_sequence "2" "team1@example.com" "uuid-team1" "false"
    add_account_to_sequence "3" "team2@example.com" "uuid-team2" "false"
    create_fake_credentials "max@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "max20" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team" |
        .coordination = {
            mode: "mysql",
            serverId: "srv-a",
            leaseTtlSeconds: 180,
            mysql: {
                host: "127.0.0.1",
                port: "3306",
                database: "ccs",
                user: "ccs",
                password: "secret"
            }
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "max@example.com"

    cat > "$MOCK_BIN/mysql" << 'MOCK_EOF'
#!/bin/bash
args="$*"
if [[ "$args" == *"CREATE DATABASE IF NOT EXISTS"* ]] || [[ "$args" == *"CREATE TABLE IF NOT EXISTS account_leases"* ]]; then
  exit 0
fi
if [[ "$args" == *"email = 'team1@example.com'"* ]]; then
  echo "srv-b"
fi
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/mysql"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
if [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 0 > "$HOME/.curl_calls"
fi
calls=$(cat "$HOME/.curl_calls")
calls=$((calls + 1))
echo "$calls" > "$HOME/.curl_calls"
if [[ "$calls" -eq 1 ]]; then
  echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
fi
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 3 ]
}

@test "test_rate_check_auto_switch_skips_team_account_leased_by_other_server_via_http" {
    setup_fake_account "max@example.com" "uuid-max"
    add_account_to_sequence "1" "max@example.com" "uuid-max" "true"
    add_account_to_sequence "2" "team1@example.com" "uuid-team1" "false"
    add_account_to_sequence "3" "team2@example.com" "uuid-team2" "false"
    create_fake_credentials "max@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "max20" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team" |
        .coordination = {
            mode: "http",
            serverId: "srv-a",
            leaseTtlSeconds: 180,
            http: {
                url: "http://127.0.0.1:19090",
                token: "token-123"
            }
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "max@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
args="$*"
if [[ "$args" == *"/v1/leases/owner?email=team1%40example.com&serverId=srv-a"* ]]; then
  echo '{"owner":{"serverId":"srv-b"},"owners":[{"serverId":"srv-b"}],"holderCount":1}'
  echo "200"
elif [[ "$args" == *"/v1/leases/owner?email=team2%40example.com&serverId=srv-a"* ]]; then
  echo '{"owner":null,"owners":[],"holderCount":0}'
  echo "200"
elif [[ "$args" == *"/v1/leases/claim"* ]]; then
  echo '{"ok":true}'
  echo "200"
elif [[ "$args" == *"/v1/leases/release"* ]]; then
  echo '{"ok":true}'
  echo "200"
elif [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 1 > "$HOME/.curl_calls"
  echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
  echo "200"
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
  echo "200"
fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 3 ]
}

@test "test_rate_check_treats_team_snapshot_as_zero_after_reset_at_passes" {
    setup_fake_account "max@example.com" "uuid-max"
    add_account_to_sequence "1" "max@example.com" "uuid-max" "true"
    add_account_to_sequence "2" "team-stale@example.com" "uuid-team-stale" "false"
    add_account_to_sequence "3" "team-busy@example.com" "uuid-team-busy" "false"
    create_fake_credentials "max@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "max20" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team" |
        .accounts["2"].lastKnownUsage = {
            fiveHour: 97,
            sevenDay: 20,
            activeLimit: 97,
            resetAt5h: "2026-06-19T00:00:00Z",
            observedAt: 123
        } |
        .accounts["3"].lastKnownUsage = {
            fiveHour: 40,
            sevenDay: 20,
            activeLimit: 40,
            resetAt5h: "2099-06-19T00:00:00Z",
            observedAt: 123
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "max@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
if [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 0 > "$HOME/.curl_calls"
fi
calls=$(cat "$HOME/.curl_calls")
calls=$((calls + 1))
echo "$calls" > "$HOME/.curl_calls"
if [[ "$calls" -eq 1 ]]; then
  echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
fi
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_allows_shared_fallback_when_no_exclusive_candidate_left" {
    setup_fake_account "team-active@example.com" "uuid-active"
    add_account_to_sequence "1" "team-active@example.com" "uuid-active" "true"
    add_account_to_sequence "2" "shared-a@example.com" "uuid-a" "false"
    add_account_to_sequence "3" "shared-b@example.com" "uuid-b" "false"
    create_fake_credentials "team-active@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "team" |
        .accounts["2"].accountType = "team" |
        .accounts["3"].accountType = "team" |
        .accounts["2"].lastKnownUsage = {
            fiveHour: 5,
            sevenDay: 10,
            activeLimit: 5,
            observedAt: 123
        } |
        .accounts["3"].lastKnownUsage = {
            fiveHour: 20,
            sevenDay: 20,
            activeLimit: 20,
            observedAt: 123
        } |
        .coordination = {
            mode: "http",
            serverId: "srv-a",
            leaseTtlSeconds: 180,
            http: {
                url: "http://127.0.0.1:19090",
                token: "token-123"
            }
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 90 "team-active@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
args="$*"
if [[ "$args" == *"/v1/leases/owner?email=shared-a%40example.com&serverId=srv-a"* ]]; then
  echo '{"owner":{"serverId":"srv-b"},"owners":[{"serverId":"srv-b"}],"holderCount":1}'
  echo "200"
elif [[ "$args" == *"/v1/leases/owner?email=shared-b%40example.com&serverId=srv-a"* ]]; then
  echo '{"owner":{"serverId":"srv-c"},"owners":[{"serverId":"srv-c"}],"holderCount":1}'
  echo "200"
elif [[ "$args" == *"/v1/leases/claim"* ]]; then
  echo '{"ok":true}'
  echo "200"
elif [[ "$args" == *"/v1/leases/release"* ]]; then
  echo '{"ok":true}'
  echo "200"
elif [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 1 > "$HOME/.curl_calls"
  echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
  echo "200"
else
  echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
  echo "200"
fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_allows_shared_fallback_when_exclusive_candidates_are_unhealthy" {
    setup_fake_account "team-active@example.com" "uuid-active"
    add_account_to_sequence "1" "team-active@example.com" "uuid-active" "true"
    add_account_to_sequence "2" "shared-good@example.com" "uuid-a" "false"
    add_account_to_sequence "3" "exclusive-bad@example.com" "uuid-b" "false"
    create_fake_credentials "team-active@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "team" |
        .accounts["2"].accountType = "max20" |
        .accounts["3"].accountType = "team" |
        .accounts["2"].lastKnownUsage = {
            fiveHour: 1,
            sevenDay: 5,
            activeLimit: 1,
            observedAt: 123
        } |
        .accounts["3"].lastKnownUsage = {
            fiveHour: 96,
            sevenDay: 20,
            activeLimit: 96,
            observedAt: 123
        } |
        .coordination = {
            mode: "http",
            serverId: "srv-a",
            leaseTtlSeconds: 180,
            http: {
                url: "http://127.0.0.1:19090",
                token: "token-123"
            }
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 100 "team-active@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
args="$*"
if [[ "$args" == *"/v1/leases/owner?email=shared-good%40example.com&serverId=srv-a"* ]]; then
  echo '{"owner":{"serverId":"srv-b"},"owners":[{"serverId":"srv-b"}],"holderCount":1}'
  echo "200"
elif [[ "$args" == *"/v1/leases/owner?email=exclusive-bad%40example.com&serverId=srv-a"* ]]; then
  echo '{"owner":null,"owners":[],"holderCount":0}'
  echo "200"
elif [[ "$args" == *"/v1/leases/claim"* ]]; then
  echo '{"ok":true}'
  echo "200"
elif [[ "$args" == *"/v1/leases/release"* ]]; then
  echo '{"ok":true}'
  echo "200"
elif [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 1 > "$HOME/.curl_calls"
  echo '{"five_hour":{"utilization":5,"limit":100,"used":5}}'
  echo "200"
else
  echo '{"five_hour":{"utilization":100,"limit":100,"used":100}}'
  echo "200"
fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 95
    [ "$status" -eq 1 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_reclaims_preferred_team_when_active_fallback_is_lower_priority" {
    setup_fake_account "fallback@example.com" "uuid-fallback"
    add_account_to_sequence "1" "team-fresh@example.com" "uuid-team" "false"
    add_account_to_sequence "2" "fallback@example.com" "uuid-fallback" "true"
    create_fake_credentials "fallback@example.com"

    local updated
    updated=$(jq '
        .accounts["1"].accountType = "team" |
        .accounts["1"].lastKnownUsage = {
            fiveHour: 95,
            sevenDay: 20,
            activeLimit: 95,
            resetAt5h: "2026-06-19T00:00:00Z",
            observedAt: 123
        } |
        .accounts["2"].accountType = "max20" |
        .accounts["2"].lastKnownUsage = {
            fiveHour: 10,
            sevenDay: 70,
            activeLimit: 70,
            observedAt: 123
        }
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 10 "fallback@example.com" 70 70

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
if [[ ! -f "$HOME/.curl_calls" ]]; then
  echo 0 > "$HOME/.curl_calls"
fi
calls=$(cat "$HOME/.curl_calls")
calls=$((calls + 1))
echo "$calls" > "$HOME/.curl_calls"
if [[ "$calls" -eq 1 ]]; then
  echo '{"five_hour":{"utilization":0,"limit":100,"used":0}}'
else
  echo '{"five_hour":{"utilization":5,"limit":100,"used":5}}'
fi
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 95
    [ "$status" -eq 1 ]
    [[ "$output" == *"Switched back to preferred account"* ]]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}

@test "test_rate_check_auto_switch_all_limited_restores_original_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    add_account_to_sequence "3" "user3@example.com" "uuid-3" "false"
    create_fake_credentials "user1@example.com"

    create_fake_usage_cache 90 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 3 ]
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}

@test "test_rate_check_stale_cache_account_mismatch_refetches" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Create cache with different account email
    create_fake_usage_cache 50 "other@example.com"

    # Mock curl to return fresh data
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":30,"limit":100,"used":30}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
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

    # Cache is 5 minutes old (older than the 60s default TTL) and shows high usage.
    create_aged_cache 300 95 "user1@example.com"

    # A refresh returns low usage — the stale value must be replaced by this.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":20,"limit":100,"used":20}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_fresh_cache_within_max_age_does_not_fetch" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Cache is 30s old, under threshold.
    create_aged_cache 30 50 "user1@example.com"

    # curl would FAIL if called — proves no fetch happens when cache is fresh.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80 --max-age 60
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_max_age_zero_forces_refresh" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Fresh cache showing high usage, but --max-age 0 makes everything stale.
    create_aged_cache 1 95 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80 --max-age 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_refresh_failure_falls_back_to_stale_cache" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Stale cache, under threshold. Refresh fails — we should fall back to it.
    create_aged_cache 300 40 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"using cached data"* ]]
}

@test "test_rate_check_perform_switch_failure_fails_open" {
    # Set up one account only (switch will fail — no target)
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    # Only 1 account, auto-switch should report no accounts
    run run_ccswitch rate-check --auto-switch --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    # Should output deny JSON since there's only one account
    echo "$output" | jq . >/dev/null 2>&1
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
