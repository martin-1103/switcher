#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export CCS_SERVER_ID="test-server"
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *https://api.anthropic.com/api/oauth/usage*)
        printf '%s\n' "${MOCK_CURL_RESULT:-200}" >> "$HOME/usage-curl-calls"
        ;;
esac
case "${MOCK_CURL_RESULT:-200}" in
    401) printf '%s\n401\n' '{"error":"invalid token"}' ;;
    429) printf '%s\n429\n' '{"error":"rate limited"}' ;;
    *) printf '%s\n200\n' '{"five_hour":{}}' ;;
esac
EOF
    chmod +x "$MOCK_BIN/curl"
}

teardown() {
    teardown_test_env
}

@test "health-check probes unknown once and does not switch" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "two@example.com" "uuid-2" "false"
    jq '.accounts["2"].credentialHealth = {status:"healthy"}' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"

    run run_ccswitch health-check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK account=1 email=one@example.com status=healthy"* ]]
    [[ "$output" == *"SKIP account=2 email=two@example.com status=healthy"* ]]
    [ "$(wc -l < "$HOME/usage-curl-calls")" -eq 1 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" = "1" ]
}

@test "health-check --all probes every usable account" {
    setup_fake_account "one@example.com" "uuid-1"
    add_account_to_sequence "1" "one@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "two@example.com" "uuid-2" "false"
    jq '.accounts["1"].credentialHealth = {status:"healthy"} |
        .accounts["2"].credentialHealth = {status:"invalid"}' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    create_fake_credentials "two@example.com"

    run run_ccswitch health-check --all
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HOME/usage-curl-calls")" -eq 2 ]
    [[ "$output" == *"CHECK account=1"* ]]
    [[ "$output" == *"CHECK account=2"* ]]
}

@test "health-check skips expired or missing credentials explicitly" {
    add_account_to_sequence "1" "expired@example.com" "uuid-1" "false"
    jq '.accounts["1"].credentialHealth = {status:"unknown"}' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    security delete-generic-password -s "Claude Code-Account-1-expired@example.com"

    run run_ccswitch health-check --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP account=1 email=expired@example.com status=skipped"*"reason=expired_or_missing"* ]]
    [ ! -e "$HOME/usage-curl-calls" ]
}
