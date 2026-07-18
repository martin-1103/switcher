#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_CURL_RESULT:-200}" in
    network) exit 28 ;;
    401) printf '%s\n401\n' '{"error":"invalid token"}' ;;
    429) printf '%s\n429\n' '{"error":"rate limited"}' ;;
    500) printf '%s\n500\n' '{"error":"server error"}' ;;
    *) printf '%s\n200\n' '{"five_hour":{}}' ;;
esac
EOF
    chmod +x "$MOCK_BIN/curl"
}

teardown() {
    teardown_test_env
}

@test "auth probe quarantines invalid credentials without storing the token" {
    source_ccswitch_functions
    mkdir -p "$BACKUP_DIR"
    cat > "$SEQUENCE_FILE" <<'EOF'
{"activeAccountNumber":1,"sequence":[1],"accounts":{"1":{"email":"one@example.com","expiresAt":"keep","credential":"do-not-touch"}}}
EOF
    export MOCK_CURL_RESULT=401

    set +e
    probe_account_credential 1 '{"access_token":"secret-token"}'
    probe_status=$?
    set -e
    [ "$probe_status" -eq 1 ]
    [ "$SWITCH_PROBE_RESULT" = "invalid" ]
    [ "$SWITCH_PROBE_STATUS" = "401" ]
    record_probe_failure 1 "$SWITCH_PROBE_RESULT" "$SWITCH_PROBE_STATUS" "$SWITCH_PROBE_REASON"

    [ "$(jq -r '.accounts["1"].quarantineReason' "$SEQUENCE_FILE")" = "http_401" ]
    [ "$(jq -r '.accounts["1"].expiresAt' "$SEQUENCE_FILE")" = "keep" ]
    [ "$(jq -r '.accounts["1"].credential' "$SEQUENCE_FILE")" = "do-not-touch" ]
    [ "$(jq -r '.accounts["1"].credentialHealth.status' "$SEQUENCE_FILE")" = "invalid" ]
    [ "$(jq -r '.accounts["1"].credentialHealth.fingerprint | length' "$SEQUENCE_FILE")" -eq 64 ]
    ! grep -q 'secret-token' "$BACKUP_DIR/autoswitch.log"
}

@test "transient probe is short cooldown and healthy probe clears quarantine" {
    source_ccswitch_functions
    mkdir -p "$BACKUP_DIR"
    cat > "$SEQUENCE_FILE" <<'EOF'
{"activeAccountNumber":1,"sequence":[1],"accounts":{"1":{}}}
EOF
    export MOCK_CURL_RESULT=429

    set +e
    probe_account_credential 1 '{"access_token":"secret-token"}'
    probe_status=$?
    set -e
    [ "$probe_status" -eq 2 ]
    record_probe_failure 1 "$SWITCH_PROBE_RESULT" "$SWITCH_PROBE_STATUS" "$SWITCH_PROBE_REASON"
    [ "$(jq -r '.accounts["1"].quarantineReason' "$SEQUENCE_FILE")" = "http_429" ]
    [ "$(jq -r '(.accounts["1"].quarantineUntil - now) | floor' "$SEQUENCE_FILE")" -le 31 ]
    [ "$(jq -r '.accounts["1"].credentialHealth.status' "$SEQUENCE_FILE")" = "throttled" ]

    export MOCK_CURL_RESULT=200
    probe_account_credential 1 '{"access_token":"secret-token"}'
    clear_account_quarantine 1
    [ "$(jq -r '.accounts["1"].quarantineUntil // empty' "$SEQUENCE_FILE")" = "" ]
}

@test "automatic candidate selection skips active quarantine" {
    source_ccswitch_functions
    add_account_to_sequence 1 one@example.com uuid-1 true
    add_account_to_sequence 2 two@example.com uuid-2 false
    add_account_to_sequence 3 three@example.com uuid-3 false
    set_account_quarantine 2 3600 auth_failure

    run auto_switch_candidates 1
    [ "$status" -eq 0 ]
    [[ "$output" != *"2"* ]]
    [[ "$output" == *"3"* ]]
}

@test "credential event auto-add stores switchable config" {
    source_ccswitch_functions
    setup_fake_account "current@example.com" "uuid-current"
    mkdir -p "$BACKUP_DIR"
    cat > "$SEQUENCE_FILE" <<'EOF'
{"activeAccountNumber":null,"sequence":[],"accounts":{}}
EOF
    coord_fetch_credential() {
        printf '%s\n' '{"sourceServer":"remote-a","claudeAiOauth":{"accessToken":"at-remote@example.com","refreshToken":"rt-remote@example.com"}}'
    }
    fetch_oauth_profile() {
        printf '%s\n' 'remote@example.com	uuid-remote'
    }

    coord_reconcile_credential_email "remote@example.com"
    local num config_email
    num=$(jq -r '.sequence[0]' "$SEQUENCE_FILE")
    config_email=$(jq -r '.oauthAccount.emailAddress' "$BACKUP_DIR/configs/.claude-config-${num}-remote@example.com.json")
    [ "$config_email" = "remote@example.com" ]
    [ -n "$(jq -r '.oauthAccount.accountUuid' "$BACKUP_DIR/configs/.claude-config-${num}-remote@example.com.json")" ]
}

@test "credential event reconciliation fetches the event source" {
    source_ccswitch_functions
    add_account_to_sequence "1" "known@example.com" "uuid-known" "false"
    local source_capture="$TEST_HOME/source-server"
    coord_fetch_credential() {
        printf '%s' "${2:-legacy}" > "$source_capture"
        printf '%s\n' '{"sourceServer":"server-a","claudeAiOauth":{"accessToken":"at-known","refreshToken":"rt-known","credentialUpdatedAt":2}}'
    }

    coord_reconcile_credential_email "known@example.com" "server-a"
    [ "$(cat "$source_capture")" = "server-a" ]
}

@test "credential event replaces expired local credential with older coordinator version" {
    source_ccswitch_functions
    add_account_to_sequence "1" "known@example.com" "uuid-known" "false"
    security add-generic-password -U -s "Claude Code-Account-1-known@example.com" -a "$USER" \
        -w '{"claudeAiOauth":{"accessToken":"expired-local","refreshToken":"expired-local-rt","expiresAt":1,"credentialUpdatedAt":20}}'
    coord_fetch_credential() {
        printf '%s\n' '{"sourceServer":"server-a","credentialHealth":{"status":"healthy"},"claudeAiOauth":{"accessToken":"remote-good","refreshToken":"remote-good-rt","expiresAt":4102444800,"credentialUpdatedAt":10}}'
    }

    coord_reconcile_credential_email "known@example.com" "server-a"
    [ "$(read_account_credentials 1 known@example.com | jq -r '.claudeAiOauth.accessToken')" = "remote-good" ]
}

@test "credential event does not overwrite fresher usable local credential" {
    source_ccswitch_functions
    add_account_to_sequence "1" "known@example.com" "uuid-known" "false"
    security add-generic-password -U -s "Claude Code-Account-1-known@example.com" -a "$USER" \
        -w '{"claudeAiOauth":{"accessToken":"local-good","refreshToken":"local-good-rt","expiresAt":4102444800,"credentialUpdatedAt":20}}'
    coord_fetch_credential() {
        printf '%s\n' '{"sourceServer":"server-a","credentialHealth":{"status":"healthy"},"claudeAiOauth":{"accessToken":"remote-old","refreshToken":"remote-old-rt","expiresAt":4102444800,"credentialUpdatedAt":10}}'
    }

    coord_reconcile_credential_email "known@example.com" "server-a"
    [ "$(read_account_credentials 1 known@example.com | jq -r '.claudeAiOauth.accessToken')" = "local-good" ]
}

@test "unknown coordinator baseline does not clear invalid auth state" {
    source_ccswitch_functions
    add_account_to_sequence "1" "known@example.com" "uuid-known" "false"
    jq '.accounts["1"].authState = "invalid"' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    coord_fetch_credential() {
        printf '%s\n' '{"sourceServer":"server-a","credentialHealth":{"status":"unknown"},"claudeAiOauth":{"accessToken":"at-known-new","refreshToken":"rt-known-new","credentialUpdatedAt":2}}'
    }

    coord_reconcile_credential_email "known@example.com" "server-a"
    [ "$(jq -r '.accounts["1"].authState' "$SEQUENCE_FILE")" = "invalid" ]
}
