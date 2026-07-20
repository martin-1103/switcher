#!/usr/bin/env bash
# ccs-open-oauth — open Chrome for the email's profile via ccs-chrome-service
# (server 103.120.169.238, service port 9334, CDP port 9333, profile name =
# email local part), start the login bridge, open the OAuth URL in that
# Chrome, and print the consent page state.
#
# Usage:
#   ccs-open-oauth.sh <email>              # Manual click (VNC/real mouse)
#   ccs-open-oauth.sh --auto-click <email> # Auto-click via CDP
#
# Without --auto-click: the human clicks Authorize manually (VNC / real mouse),
# then feeds the code back to the bridge:
#
#   ccs-login-bridge.sh submit <email> <code>
#
# With --auto-click: polls the CDP page for the Authorize button every 500ms,
# clicks it via Runtime.evaluate, captures the authorization code from the
# redirect URL, and auto-submits it via `ccs-login-bridge.sh submit`.
# Note: scripted clicks may trip OAuth bot-detection (observed in some cases).
set -euo pipefail

EMAIL="${1:?usage: ccs-open-oauth.sh [--auto-click] <email>}"
AUTO_CLICK=false
if [[ "$1" == "--auto-click" ]]; then
    AUTO_CLICK=true
    shift
    EMAIL="${1:?usage: ccs-open-oauth.sh [--auto-click] <email>}"
fi
BRIDGE="/usr/local/lib/cc-account-switcher/coordinator/ccs-login-bridge.sh"
SSH="/root/cc-account-switcher/connectgass.sh"
CDP_PORT="${CDP_PORT:-9333}"
CHROME_SVC_PORT="${CHROME_SVC_PORT:-9334}"
CHROME_PROFILE="${CHROME_PROFILE:-${EMAIL%%@*}}"

# 0. Ask the ccs-chrome-service on the remote to open Chrome with this profile
#    (kills any Chrome holding the CDP port with a wrong profile or headless
#    mode, starts non-headless on the VNC display, waits for CDP).
resp=$(bash "$SSH" "curl -s --max-time 60 -X POST -d 'profile=${CHROME_PROFILE}' http://localhost:${CHROME_SVC_PORT}/open")
echo "chrome-service: $resp"
[[ "$resp" == *'"started": true'* ]] \
    || { echo "ERROR: chrome-service /open failed" >&2; exit 1; }

# 1. Fresh bridge session, capture the OAuth URL.
bash "$BRIDGE" cancel "$EMAIL" >/dev/null 2>&1 || true
url=$(bash "$BRIDGE" start "$EMAIL")
[[ "$url" == https://* ]] || { echo "ERROR: no OAuth URL from bridge" >&2; echo "$url" >&2; exit 1; }
echo "OAuth URL:"
echo "$url"
echo

# 2. Open it in the remote profile1 tab. curl needs the query '&' percent-encoded
#    so they aren't parsed as separate shell/URL args; encode on the remote side.
tab_id=$(bash "$SSH" "python3 - <<'PYEOF'
import urllib.parse, urllib.request, json
url = ${url@Q}
# /json/new?<url> — the URL after ? must be percent-encoded as one opaque arg.
enc = urllib.parse.quote(url, safe='')
req = urllib.request.Request('http://localhost:${CDP_PORT}/json/new?' + enc, method='PUT')
print(json.load(urllib.request.urlopen(req))['id'])
PYEOF")
echo "Opened tab: $tab_id"

# 3. Wait for redirect + render, then dump the page state (URL + visible text).
sleep 6
bash "$SSH" "python3 - <<PYEOF
import asyncio, websockets, json
async def main():
    uri = 'ws://localhost:${CDP_PORT}/devtools/page/${tab_id}'
    async with websockets.connect(uri, max_size=10_000_000) as ws:
        for i, expr in [(1, 'window.location.href'), (2, 'document.body.innerText')]:
            await ws.send(json.dumps({'id': i, 'method': 'Runtime.evaluate', 'params': {'expression': expr}}))
            while True:
                m = json.loads(await ws.recv())
                if m.get('id') == i:
                    label = 'URL:  ' if i == 1 else 'PAGE:\n'
                    print(label + str(m['result']['result'].get('value', ''))[:800])
                    break
asyncio.run(main())
PYEOF"

echo
echo "Tab id: $tab_id  (bridge session waiting for code)"

if [[ "$AUTO_CLICK" == true ]]; then
    # 4. Auto-click the Authorize button via CDP and auto-submit the code.
    echo "Auto-click enabled: polling for Authorize button..."
    # Write Python script to temp file so heredoc quoting doesn't clash
    # with Python triple quotes. Variables expand here.
    tmpfile=$(mktemp /tmp/ccs-autoclick-XXXXXX.py)
    cat > "$tmpfile" <<PYEOF
import asyncio, websockets, json, sys, time, urllib.parse, urllib.request

URI = 'ws://localhost:${CDP_PORT}/devtools/page/${tab_id}'
CDP_HTTP = 'http://localhost:${CDP_PORT}'


def extract_code_from_url(url):
    if '?' not in url or '/oauth/code/callback' not in url:
        return None
    qs = url.split('?', 1)[1]
    params = urllib.parse.parse_qs(qs)
    code = params.get('code', [None])[0]
    state = params.get('state', [None])[0]
    if code and code != 'true':
        return code + ('#' + state if state else '')
    return None


def poll_targets_for_code(deadline):
    # Authorizing can navigate cross-origin (claude.ai -> platform.claude.com),
    # which makes Chrome open a NEW CDP target and tear down the old one — any
    # websocket still attached to the old page id dies with
    # ConnectionClosedError before the code is ever read. /json/list is a
    # fresh HTTP call each time, so it sees whatever target currently holds
    # the callback URL regardless of what happened to the original page.
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(CDP_HTTP + '/json/list', timeout=5) as resp:
                targets = json.load(resp)
            for t in targets:
                code = extract_code_from_url(t.get('url', ''))
                if code:
                    return code
        except Exception:
            pass
        time.sleep(0.5)
    return None

async def autoclick(uri, timeout=90):
    async with websockets.connect(uri, max_size=10_000_000) as ws:
        def send_msg(ws, id, method, params):
            return ws.send(json.dumps({'id': id, 'method': method, 'params': params}))

        # Enable Runtime domain
        await send_msg(ws, 1, 'Runtime.enable', {})
        await asyncio.sleep(0.5)

        deadline = time.time() + timeout

        # --- Step A0: some flows show a Login/Sign in gate before the
        # Authorize page (e.g. account picker). Click it once if present so
        # the loop below doesn't spin waiting on a page that never shows
        # Authorize because Login was never clicked.
        login_clicked = False
        login_deadline = time.time() + 15
        while time.time() < login_deadline and not login_clicked:
            await send_msg(ws, 10, 'Runtime.evaluate', {
                'expression': """
                    (() => {
                        const btns = document.querySelectorAll('button, input[type="submit"], a[role="button"], a');
                        for (const b of btns) {
                            const t = (b.textContent || b.value || '').trim().toLowerCase();
                            if (t === 'log in' || t === 'login' || t === 'sign in') { b.click(); return 'clicked'; }
                        }
                        return null;
                    })()
                """,
                'returnByValue': True,
                'userGesture': True,
            })
            while time.time() < login_deadline:
                m = json.loads(await ws.recv())
                if m.get('id') == 10:
                    val = m.get('result', {}).get('result', {}).get('value')
                    if val == 'clicked':
                        login_clicked = True
                        print('LOGIN_CLICKED', flush=True)
                        await asyncio.sleep(1.5)  # let the page navigate/render
                    break
            if not login_clicked:
                await asyncio.sleep(0.5)

        # --- Step A: find and click Authorize button ---
        found = False
        while time.time() < deadline and not found:
            await send_msg(ws, 2, 'Runtime.evaluate', {
                'expression': """
                    (() => {
                        const btns = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
                        for (const b of btns) {
                            const t = (b.textContent || b.value || '').trim().toLowerCase();
                            if (t.includes('authorize')) return b.outerHTML;
                        }
                        return null;
                    })()
                """,
                'returnByValue': True,
            })
            while time.time() < deadline:
                m = json.loads(await ws.recv())
                if m.get('id') == 2:
                    val = m.get('result', {}).get('result', {}).get('value')
                    if val:
                        found = True
                    break
            if not found:
                await asyncio.sleep(0.5)

        if not found:
            print('ERROR: Authorize button not found within timeout.', flush=True)
            sys.exit(1)

        # Click. The click itself can trigger the cross-origin navigation
        # that kills this websocket mid-flight, so a ConnectionClosed here
        # just means the click landed and we move straight to HTTP polling.
        try:
            await send_msg(ws, 3, 'Runtime.evaluate', {
                'expression': """
                    (() => {
                        const btns = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
                        for (const b of btns) {
                            const t = (b.textContent || b.value || '').trim().toLowerCase();
                            if (t.includes('authorize')) { b.click(); return 'clicked'; }
                        }
                        return 'not_found';
                    })()
                """,
                'returnByValue': True,
                'userGesture': True,
            })
            while time.time() < deadline:
                m = json.loads(await ws.recv())
                if m.get('id') == 3:
                    break
        except websockets.exceptions.ConnectionClosed:
            pass

        print('CLICKED', flush=True)

        # --- Step B: wait for redirect to the callback page and extract the
        # code via HTTP /json/list (see poll_targets_for_code) — the original
        # page's websocket may already be dead from the cross-origin jump.
        code = poll_targets_for_code(deadline)
        if code:
            print('CODE:' + code, flush=True)
            return

        print('ERROR: No authorization code found after clicking Authorize.', flush=True)
        sys.exit(1)

asyncio.run(autoclick(URI))
PYEOF
    # Run the auto-click script on the remote server via SSH and capture output
    output=$(bash "$SSH" "python3" < "$tmpfile")
    rm -f "$tmpfile"

    echo "$output"

    # Extract code from output
    code_line=$(echo "$output" | grep '^CODE:' | head -1)
    if [[ -n "$code_line" ]]; then
        code="${code_line#CODE:}"
        echo "Authorization code detected. Submitting to bridge..."
        bash "$BRIDGE" submit "$EMAIL" "$code"
        submit_exit=$?
        if [[ $submit_exit -eq 0 ]]; then
            echo "✓ Account added successfully for $EMAIL"
            # Log the browser session out of claude.ai so the profile's Chrome
            # doesn't stay signed in as this account (next open/oauth for a
            # different account would otherwise silently authorize as this one).
            # Wait for the logout page's own load event (capped at 10s) instead
            # of a blind delay, so a slow network doesn't close the browser
            # before the logout request actually lands.
            logout_tab=$(bash "$SSH" "curl -s --max-time 30 -X PUT 'http://localhost:${CDP_PORT}/json/new?https%3A%2F%2Fclaude.ai%2Flogout'" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
            bash "$SSH" "python3 - <<PYEOF
import asyncio, websockets, json
async def main():
    uri = 'ws://localhost:${CDP_PORT}/devtools/page/${logout_tab}'
    try:
        async with websockets.connect(uri, max_size=10_000_000) as ws:
            await ws.send(json.dumps({'id': 1, 'method': 'Page.enable', 'params': {}}))
            await ws.recv()
            deadline = asyncio.get_event_loop().time() + 10
            while asyncio.get_event_loop().time() < deadline:
                remaining = deadline - asyncio.get_event_loop().time()
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=max(remaining, 0.1)))
                if m.get('method') == 'Page.loadEventFired':
                    print('logout page load event fired')
                    return
    except Exception as e:
        print('logout wait: ' + str(e))
asyncio.run(main())
PYEOF"
        else
            echo "✗ Bridge submit failed (exit $submit_exit)"
        fi
        # Done with the browser — close it via chrome-service.
        resp=$(bash "$SSH" "curl -s --max-time 30 -X POST 'http://localhost:${CHROME_SVC_PORT}/close?profile=${CHROME_PROFILE}'")
        echo "chrome-service: $resp"
    else
        echo "Auto-click finished, but no authorization code was captured."
        echo "You may need to submit manually:"
        echo "  bash $BRIDGE submit $EMAIL <code>"
    fi
else
    echo "Next (manual): click Authorize as $EMAIL via real mouse/VNC, then:"
    echo "  bash $BRIDGE submit $EMAIL <code>"
fi
