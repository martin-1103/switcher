#!/usr/bin/env bats

setup() {
    STATE_FILE="$BATS_TEST_TMPDIR/coord-state.json"
    PORT=$((19091 + RANDOM % 200))
    TOKEN="test-coordinator-token"
    KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    CCS_COORD_STATE_FILE="$STATE_FILE" CCS_COORD_PORT="$PORT" CCS_COORD_TOKEN="$TOKEN" CCS_COORD_CRED_KEY="$KEY" \
        node "$BATS_TEST_DIRNAME/../coordinator/server.js" >"$BATS_TEST_TMPDIR/coord.log" 2>&1 &
    SERVER_PID=$!
    for _ in {1..30}; do
        curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
        sleep 0.05
    done
}

teardown() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

coord() {
    curl -sf -H "Authorization: Bearer $TOKEN" "$@"
}

publish() {
    local source="$1" version="$2" health="${3:-unknown}"
    curl -sf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"email\":\"user@example.com\",\"sourceServer\":\"$source\",\"accessToken\":\"at-$source-$version\",\"refreshToken\":\"rt-$source-$version\",\"credentialUpdatedAt\":$version,\"healthStatus\":\"$health\"}" \
        "http://127.0.0.1:$PORT/v1/credentials/publish"
}

@test "credentials are retained by source and newer rotations reset health" {
    [ "$(publish server-a 1 | jq -r '.event')" = "credential.add" ]
    [ "$(publish server-b 2 | jq -r '.event')" = "credential.add" ]

    coord "http://127.0.0.1:$PORT/v1/credentials/health?email=user%40example.com" |
        jq -e '.sources | length == 2 and any(.[]; .sourceServer == "server-a") and any(.[]; .sourceServer == "server-b")'

    curl -sf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d '{"email":"user@example.com","sourceServer":"server-a","status":"healthy","reason":"probe"}' \
        "http://127.0.0.1:$PORT/v1/credentials/health" >/dev/null
    jq -e '[.events[] | select(.type == "credential.health.updated" and .sourceServer == "server-a")] | length == 1' "$STATE_FILE"

    [ "$(publish server-a 2 | jq -r '.accepted')" = "true" ]
    [ "$(coord "http://127.0.0.1:$PORT/v1/credentials/health?email=user%40example.com" | jq -r '.sources[] | select(.sourceServer == "server-a") | .status')" = "unknown" ]
    [ "$(publish server-a 3 healthy | jq -r '.accepted')" = "true" ]
    [ "$(coord "http://127.0.0.1:$PORT/v1/credentials/fetch?email=user%40example.com" | jq -r '.sourceServer')" = "server-a" ]
}

@test "invalid source is excluded while throttled remains recoverable" {
    publish server-a 1 >/dev/null
    curl -sf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d '{"email":"user@example.com","sourceServer":"server-a","status":"invalid","reason":"http_401"}' \
        "http://127.0.0.1:$PORT/v1/credentials/health" >/dev/null
    publish server-b 2 >/dev/null

    curl -sf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d '{"email":"user@example.com","sourceServer":"server-b","status":"throttled","reason":"http_429","fingerprint":"fp-b","observedAt":123}' \
        "http://127.0.0.1:$PORT/v1/credentials/health" >/dev/null

    [ "$(coord "http://127.0.0.1:$PORT/v1/credentials/fetch?email=user%40example.com" | jq -r '.sourceServer')" = "server-b" ]
    [ "$(coord "http://127.0.0.1:$PORT/v1/credentials/health?email=user%40example.com" | jq -r '.sources[] | select(.sourceServer == "server-a") | .status')" = "invalid" ]
    [ "$(coord "http://127.0.0.1:$PORT/v1/credentials/health?email=user%40example.com" | jq -r '.sources[] | select(.sourceServer == "server-b") | .fingerprint')" = "fp-b" ]
}
