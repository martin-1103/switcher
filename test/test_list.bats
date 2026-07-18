#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_list_with_no_accounts_shows_no_accounts_message" {
    # No sequence file exists, no config either
    # first_run_setup finds no active account and returns 1, which
    # causes exit under set -e, so status is non-zero
    run run_ccswitch --list
    [[ "$output" == *"No accounts are managed yet"* ]]
}

@test "test_list_with_accounts_shows_all_accounts" {
    # Set up two accounts directly
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    run run_ccswitch --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"user1@example.com"* ]]
    [[ "$output" == *"user2@example.com"* ]]
}

@test "test_list_marks_active_account_correctly" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    run run_ccswitch --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"1: user1@example.com"* ]]
    # user2 should NOT be marked active
    [[ "$output" != *"2: user2@example.com (active)"* ]]
}

@test "test_list_ordering_matches_sequence" {
    setup_fake_account "alpha@example.com" "uuid-a"
    add_account_to_sequence "1" "alpha@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "bravo@example.com" "uuid-b" "false"
    add_account_to_sequence "3" "charlie@example.com" "uuid-c" "false"

    run run_ccswitch --list
    [ "$status" -eq 0 ]

    # Check ordering: alpha before bravo before charlie
    local alpha_line bravo_line charlie_line
    alpha_line=$(echo "$output" | grep -n "alpha@example.com" | cut -d: -f1)
    bravo_line=$(echo "$output" | grep -n "bravo@example.com" | cut -d: -f1)
    charlie_line=$(echo "$output" | grep -n "charlie@example.com" | cut -d: -f1)

    [ "$alpha_line" -lt "$bravo_line" ]
    [ "$bravo_line" -lt "$charlie_line" ]
}

@test "list keeps cached health tag compact without coordinator requests" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    local updated
    updated=$(jq '.accounts["1"].authState = "invalid" | .accounts["1"].credentialHealth = {status:"invalid", sourceServer:"server-a", reason:"http_401", fingerprint:"fp", observedAt:123}' "$SEQUENCE_FILE")
    printf '%s\n' "$updated" > "$SEQUENCE_FILE"
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"[RELOGIN_REQUIRED]"* ]]
    [[ "$output" != *"health:"* ]]
}

@test "list --health renders cached credential health detail" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    local updated
    updated=$(jq '.accounts["1"].authState = "invalid" | .accounts["1"].credentialHealth = {status:"invalid", sourceServer:"server-a", reason:"http_401", fingerprint:"fp", observedAt:123}' "$SEQUENCE_FILE")
    printf '%s\n' "$updated" > "$SEQUENCE_FILE"
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch ls --health
    [ "$status" -eq 0 ]
    [[ "$output" == *"[RELOGIN_REQUIRED]"* ]]
    [[ "$output" == *"health: local=invalid remote=unknown"* ]]
}

@test "list renders cached healthy throttled and unknown statuses" {
    add_account_to_sequence "1" "healthy@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "throttled@example.com" "uuid-2" "false"
    add_account_to_sequence "3" "unknown@example.com" "uuid-3" "false"
    jq '.accounts["1"].credentialHealth.status = "healthy" |
        .accounts["2"].credentialHealth.status = "throttled" |
        .accounts["3"].credentialHealth.status = "unknown"' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"

    run run_ccswitch ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"*healthy@example.com* ]]
    [[ "$output" == *"[THROTTLED]"*throttled@example.com* ]]
    [[ "$output" == *"[UNKNOWN]"*unknown@example.com* ]]
}
