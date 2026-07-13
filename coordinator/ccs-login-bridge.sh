#!/usr/bin/env bash
# ccs-login-bridge — drive `ccs login` inside a detached tmux session so a
# remote channel (Telegram) can run the two OAuth steps as separate events:
#
#   start <email>        launch login in tmux, print the OAuth URL, leave the
#                        session running waiting for the code
#   submit <email> <code>  inject the code into the waiting session, print the
#                          result (Updated/Added Account ... on success)
#   status <email>       print current pane tail (debug)
#   cancel <email>       kill the session (abandon a login)
#
# Stateless across invocations: all state lives in the tmux session itself,
# which stays alive between start and submit. That is what lets a webhook
# trigger start and a later reply trigger submit without a long-lived process.
#
# OAuth authorizes whatever account the BROWSER that opens the URL is signed
# in to — --email only pre-fills login_hint. The caller must tell the human to
# open the URL in a clean/incognito session as the intended account.
set -euo pipefail

CCS_BIN="${CCS_BIN:-ccs}"
URL_TIMEOUT="${CCS_LOGIN_URL_TIMEOUT:-15}"     # seconds to wait for URL
RESULT_TIMEOUT="${CCS_LOGIN_RESULT_TIMEOUT:-30}" # seconds to wait after code

# tmux session name for an email. Sanitize to the same charset ccs uses for
# cache files so two emails never collide on one session.
session_name() {
    local email="$1"
    printf 'ccslogin-%s' "$(printf '%s' "$email" | tr -c 'a-zA-Z0-9' '_')"
}

# Join wrapped lines (-J) — the OAuth URL wraps across pane columns otherwise
# and a naive grep returns a truncated URL.
pane() {
    tmux capture-pane -t "$1" -p -J 2>/dev/null || true
}

cmd_start() {
    local email="${1:?usage: start <email>}"
    local sess; sess=$(session_name "$email")

    # Fresh session every start: a stale one from an abandoned/failed attempt
    # would still show its old URL and swallow the new code.
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" -x 200 -y 50

    # -- separates ccs's flags from tmux's; email is shell-quoted by send-keys.
    tmux send-keys -t "$sess" "$(printf '%q login --email %q' "$CCS_BIN" "$email")" Enter

    local url="" i=0
    while (( i < URL_TIMEOUT )); do
        url=$(pane "$sess" | grep -o 'https://claude\.com/cai/oauth/authorize[^ ]*' | head -1 || true)
        [[ -n "$url" ]] && break
        sleep 1; i=$(( i + 1 ))
    done

    if [[ -z "$url" ]]; then
        echo "ERROR: OAuth URL did not appear within ${URL_TIMEOUT}s" >&2
        echo "--- pane ---" >&2; pane "$sess" | tail -15 >&2
        tmux kill-session -t "$sess" 2>/dev/null || true
        exit 1
    fi
    # Only the URL on stdout, so a caller can capture it cleanly.
    printf '%s\n' "$url"
}

cmd_submit() {
    local email="${1:?usage: submit <email> <code>}"
    local code="${2:?usage: submit <email> <code>}"
    local sess; sess=$(session_name "$email")

    if ! tmux has-session -t "$sess" 2>/dev/null; then
        echo "ERROR: no pending login session for $email (run start first, or it timed out)" >&2
        exit 1
    fi

    tmux send-keys -t "$sess" "$code" Enter

    local out="" i=0
    while (( i < RESULT_TIMEOUT )); do
        out=$(pane "$sess")
        if grep -qE 'Updated Account|Added Account' <<< "$out"; then
            grep -E 'Updated Account|Added Account' <<< "$out" | tail -1
            tmux kill-session -t "$sess" 2>/dev/null || true
            return 0
        fi
        if grep -qE 'Nothing captured|Login failed|auth login failed|not logged in' <<< "$out"; then
            echo "ERROR: login failed" >&2
            grep -E 'Login failed|Nothing captured|not logged in|status code' <<< "$out" | tail -2 >&2
            tmux kill-session -t "$sess" 2>/dev/null || true
            exit 1
        fi
        sleep 1; i=$(( i + 1 ))
    done

    echo "ERROR: no result within ${RESULT_TIMEOUT}s after submitting code" >&2
    echo "--- pane ---" >&2; pane "$sess" | tail -15 >&2
    tmux kill-session -t "$sess" 2>/dev/null || true
    exit 1
}

cmd_status() {
    local email="${1:?usage: status <email>}"
    local sess; sess=$(session_name "$email")
    tmux has-session -t "$sess" 2>/dev/null || { echo "no session for $email"; exit 1; }
    pane "$sess" | grep -vE '^\s*$' | tail -15
}

cmd_cancel() {
    local email="${1:?usage: cancel <email>}"
    local sess; sess=$(session_name "$email")
    tmux kill-session -t "$sess" 2>/dev/null && echo "cancelled $email" || echo "no session for $email"
}

case "${1:-}" in
    start)  shift; cmd_start "$@" ;;
    submit) shift; cmd_submit "$@" ;;
    status) shift; cmd_status "$@" ;;
    cancel) shift; cmd_cancel "$@" ;;
    *)
        echo "usage: $0 {start <email>|submit <email> <code>|status <email>|cancel <email>}" >&2
        exit 2
        ;;
esac
