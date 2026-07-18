#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "coord-push --all --force publishes manual login replacement" {
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    jq '.coordination = {mode:"http", serverId:"local", http:{url:"http://coord.test", token:"test-token"}}' \
        "$SEQUENCE_FILE" > "$SEQUENCE_FILE.tmp"
    mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    local payload_file="$BATS_TEST_TMPDIR/publish-payloads"
    rm -f "$payload_file"
    export PUBLISH_PAYLOAD_FILE="$payload_file"

    cat > "$MOCK_BIN/curl" <<EOF
#!/usr/bin/env bash
body=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data) body="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "\$body" | jq -c . >> "$payload_file"
printf '%s\n200\n' '{"accepted":true,"reason":"manual_login_accepted"}'
EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch coord-push --all --force
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$payload_file")" -eq 2 ]
    [ "$(jq -s 'all(.[]; .publishReason == "manual_login" and .forceReplace == true)' "$payload_file")" = "true" ]
    [[ "$output" == *"Force push totals: accepted=2 rejected=0 failed=0"* ]]
}
