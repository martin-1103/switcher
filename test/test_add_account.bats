#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_add_account_with_valid_login_initializes_sequence_json" {
    setup_fake_account "user1@example.com" "uuid-1"

    run run_ccswitch --add-account
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added Account 1: user1@example.com"* ]]

    # Verify sequence.json exists and is valid JSON
    [ -f "$SEQUENCE_FILE" ]
    run jq . "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
}

@test "test_add_account_with_valid_login_stores_credentials_and_config" {
    setup_fake_account "user1@example.com" "uuid-1"

    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Verify backup config exists
    [ -f "$BACKUP_DIR/configs/.claude-config-1-user1@example.com.json" ]

    # Verify credentials stored in mock keychain
    local stored_creds
    stored_creds=$(security find-generic-password -s "Claude Code-Account-1-user1@example.com" -w)
    [ -n "$stored_creds" ]
}

@test "test_add_account_with_duplicate_email_shows_already_managed" {
    setup_fake_account "user1@example.com" "uuid-1"

    # Add first time
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Add again - should be idempotent
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]
    [[ "$output" == *"already managed"* ]]
}

@test "manual login publishes fresh timestamp with reason and force replace" {
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    jq '.coordination = {mode:"http", serverId:"local", http:{url:"http://coord.test", token:"test-token"}}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/publish-calls"
case "$*" in
    *"api/oauth/profile"*)
        printf '%s\n200\n' '{"account":{"email":"user1@example.com","uuid":"uuid-1"}}'
        exit 0
        ;;
esac
printf '%s\n200\n' '{"accepted":true,"reason":"manual_login_accepted"}'
EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch --add-account
    [ "$status" -eq 0 ]
    grep -q '"publishReason": "manual_login"' "$HOME/publish-calls"
    grep -q '"forceReplace": true' "$HOME/publish-calls"
    local updated
    updated=$(security find-generic-password -s "Claude Code-Account-1-user1@example.com" -w | jq -r '.credentialUpdatedAt // .claudeAiOauth.credentialUpdatedAt // 0')
    [ "$updated" -gt 0 ]
    [[ "$output" == *"Coordinator publish accepted"* ]]
}

@test "add account probes fresh credentials once without failing on transient result" {
    setup_fake_account "user1@example.com" "uuid-1"
    source_ccswitch_functions

    export PROBE_CALLS_FILE="$TEST_HOME/probe-calls"
    probe_account_credential() {
        printf '%s %s\n' "$1" "$3" >> "$PROBE_CALLS_FILE"
        printf '%s' "$2" > "$TEST_HOME/probe-creds"
        return 2
    }
    coord_publish_credential() {
        COORD_PUBLISH_REASON=mock
        return 0
    }
    coord_publish_account_state() { :; }
    fetch_oauth_profile() {
        printf 'user1@example.com\tuuid-1\n'
    }

    local cmd_output="$TEST_HOME/add-output"
    set +e
    cmd_add_account >"$cmd_output" 2>&1
    local status=$?
    set -e
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$PROBE_CALLS_FILE")" -eq 1 ]
    read -r probe_num probe_source < "$PROBE_CALLS_FILE"
    [ "$probe_num" = "1" ]
    grep -q 'at-user1@example.com' "$TEST_HOME/probe-creds"
    [ "$probe_source" = "legacy" ]
}

@test "test_add_account_with_no_active_login_shows_error" {
    # No config file created = no active login
    run run_ccswitch --add-account
    [ "$status" -eq 1 ]
    [[ "$output" == *"No active Claude account found"* ]]
}

@test "test_add_account_with_no_credentials_shows_error" {
    # Create config but no credentials
    create_fake_claude_config "user1@example.com" "uuid-1"

    run run_ccswitch --add-account
    [ "$status" -eq 1 ]
    [[ "$output" == *"No credentials found"* ]]
}

@test "test_add_account_multiple_accounts_builds_correct_sequence" {
    # Add first account
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Switch to second account
    setup_fake_account "user2@example.com" "uuid-2"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Verify sequence.json structure
    local count
    count=$(jq '.sequence | length' "$SEQUENCE_FILE")
    [ "$count" -eq 2 ]

    local first_email second_email
    first_email=$(jq -r '.accounts["1"].email' "$SEQUENCE_FILE")
    second_email=$(jq -r '.accounts["2"].email' "$SEQUENCE_FILE")
    [ "$first_email" = "user1@example.com" ]
    [ "$second_email" = "user2@example.com" ]

    # Active should be the last added
    local active
    active=$(jq '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_add_account_with_type_flag_stores_account_type" {
    setup_fake_account "user1@example.com" "uuid-1"

    run run_ccswitch add --type team
    [ "$status" -eq 0 ]

    local account_type
    account_type=$(jq -r '.accounts["1"].accountType // empty' "$SEQUENCE_FILE")
    [ "$account_type" = "team" ]
}

@test "test_add_account_with_invalid_type_fails" {
    setup_fake_account "user1@example.com" "uuid-1"

    run run_ccswitch add --type wrong
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid account type"* ]]
}

@test "test_coord_setup_persists_mysql_configuration" {
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    cat > "$MOCK_BIN/mysql" << 'MOCK_EOF'
#!/bin/bash
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/mysql"

    run run_ccswitch coord-setup --mode mysql --host 127.0.0.1 --port 3306 --database ccs --user ccs --password secret --server-id srv-a --lease-ttl 180
    [ "$status" -eq 0 ]
    [[ "$output" == *"Coordination enabled."* ]]

    run jq -r '.coordination.serverId' "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "srv-a" ]

    run jq -r '.coordination.mysql.password' "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "secret" ]
}

@test "test_coord_setup_persists_http_configuration" {
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"ok":true}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch coord-setup --mode http --api-url http://127.0.0.1:19090 --api-token token-123 --server-id srv-http --lease-ttl 180
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: http"* ]]

    run jq -r '.coordination.mode' "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "http" ]

    run jq -r '.coordination.http.url' "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "http://127.0.0.1:19090" ]
}

@test "test_coord_client_setup_configures_http_hook_and_statusline" {
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"ok":true}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch coord-client-setup --api-url https://ccs.dev.gass.web.id --api-token token-xyz --server-id srv-client --threshold 95
    [ "$status" -eq 0 ]
    [[ "$output" == *"Client setup complete."* ]]

    run jq -r '.coordination.mode' "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "http" ]

    run jq -r '.rateLimit.threshold' "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "95" ]

    run jq -r '.statusLine.command' "$HOME/.claude/settings.local.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ccs-statusline.sh"* ]]

    run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOME/.claude/settings.local.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ccs-rate-hook.sh"* ]]
}

@test "test_coord_token_prints_http_token_from_sequence_file" {
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"ok":true}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch coord-setup --mode http --api-url https://ccs.dev.gass.web.id --api-token token-abc --server-id srv-token --lease-ttl 180
    [ "$status" -eq 0 ]

    run run_ccswitch coord-token
    [ "$status" -eq 0 ]
    [ "$output" = "token-abc" ]
}

@test "test_coord_client_command_prints_copy_paste_setup_command" {
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"ok":true}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch coord-setup --mode http --api-url https://ccs.dev.gass.web.id --api-token token-cmd --server-id srv-cmd --lease-ttl 180
    [ "$status" -eq 0 ]

    run run_ccswitch coord-client-command
    [ "$status" -eq 0 ]
    [[ "$output" == *"coord-client-setup"* ]]
    [[ "$output" == *"--api-url https://ccs.dev.gass.web.id"* ]]
    [[ "$output" == *"--api-token 'token-cmd'"* ]]
}
