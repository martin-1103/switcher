#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    rm -f /tmp/claude-usage-cache.json
    teardown_test_env
}

@test "status prints 5h and 7d usage windows when cache exists" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_usage_cache 42 "user1@example.com" 13

    run run_ccswitch status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage windows:   5h 42% | 7d 13%"* ]]
}
