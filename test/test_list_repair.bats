#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export CCS_SERVER_ID="local"
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"/v1/credentials/health?email="*)
        printf 'health\n' >> "$HOME/coord-calls"
        if [[ -n "${MOCK_HEALTH_RESPONSE:-}" ]]; then
            printf '%s\n200\n' "$MOCK_HEALTH_RESPONSE"
        else
            printf '%s\n200\n' '{"email":"one@example.com","sources":[{"sourceServer":"remote","status":"healthy","observedAt":200}]}'
        fi
        ;;
    *"/v1/credentials/fetch?email="*)
        printf 'fetch\n' >> "$HOME/coord-calls"
        printf '%s\n200\n' '{"accessToken":"remote-at","refreshToken":"remote-rt","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":[],"credentialUpdatedAt":200,"sourceServer":"remote","health":{"status":"healthy"}}'
        ;;
    *"/v1/credentials/health")
        printf 'health-post\n' >> "$HOME/coord-calls"
        printf '%s\n200\n' '{"ok":true}'
        ;;
    *"api/oauth/usage"*)
        printf 'probe\n' >> "$HOME/coord-calls"
        printf '%s\n200\n' '{"five_hour":{}}'
        ;;
    *)
        exit 99
        ;;
esac
EOF
    chmod +x "$MOCK_BIN/curl"
}

teardown() {
    teardown_test_env
}

configure_coord() {
    jq '.coordination = {mode:"http", serverId:"local", http:{url:"http://coord.test", token:"test-token"}}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
}

@test "ls --repair repairs invalid account from healthy remote source once" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "true"
    configure_coord
    jq '.accounts["1"].authState = "invalid" | .accounts["1"].credentialHealth = {status:"invalid"}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"

    run run_ccswitch ls --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPAIRED account=1 email=one@example.com source=remote"* ]]
    [ "$(grep -c '^health$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(grep -c '^fetch$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(grep -c '^probe$' "$HOME/coord-calls")" -eq 1 ]
    [[ "$(security find-generic-password -s "Claude Code-Account-1-one@example.com" -w)" == *"remote-at"* ]]
    [ "$(jq -r '.accounts["1"].authState // ""' "$SEQUENCE_FILE")" = "" ]
}

@test "ls --repair reports no healthy source without fetching" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "false"
    configure_coord
    jq '.accounts["1"].authState = "invalid" | .accounts["1"].credentialHealth = {status:"invalid"}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    export MOCK_HEALTH_RESPONSE='{"email":"one@example.com","sources":[{"sourceServer":"remote","status":"invalid"}]}'

    run run_ccswitch ls --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_SOURCE account=1 email=one@example.com"* ]]
    [ ! -e "$HOME/coord-calls" ] || [ "$(grep -c '^fetch$' "$HOME/coord-calls")" -eq 0 ]
}

@test "ls --repair repairs expired invalid account from healthy remote source" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "false"
    configure_coord
    security add-generic-password -U -s "Claude Code-Account-1-one@example.com" -a "$USER" \
        -w '{"access_token":"expired-at","refresh_token":"expired-rt","expires_at":1}'
    jq '.accounts["1"].authState = "invalid" | .accounts["1"].credentialHealth = {status:"invalid"}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"

    run run_ccswitch ls --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPAIRED account=1 email=one@example.com source=remote"* ]]
    [ "$(grep -c '^health$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(grep -c '^fetch$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(grep -c '^probe$' "$HOME/coord-calls")" -eq 1 ]
    [[ "$(security find-generic-password -s "Claude Code-Account-1-one@example.com" -w)" == *"remote-at"* ]]
}

@test "ls --repair repairs missing local credentials from healthy remote once without switching" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "true"
    configure_coord
    security delete-generic-password -s "Claude Code-Account-1-one@example.com"
    jq '.accounts["1"].authState = "invalid" | .accounts["1"].credentialHealth = {status:"invalid"}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"

    run run_ccswitch ls --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPAIRED account=1 email=one@example.com source=remote"* ]]
    [ "$(grep -c '^health$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(grep -c '^fetch$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(grep -c '^probe$' "$HOME/coord-calls")" -eq 1 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
    [[ "$(security find-generic-password -s "Claude Code-Account-1-one@example.com" -w)" == *"remote-at"* ]]
}

@test "default ls does not request coordinator" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "true"
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"/v1/credentials/"*) printf 'unexpected coordinator curl\n' >> "$HOME/coord-calls" ;;
esac
exit 99
EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch ls
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/coord-calls" ]
}
