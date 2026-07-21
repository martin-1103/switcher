#!/usr/bin/env node
// ccs-telegram-bot — notify on expired accounts and drive re-login over
// Telegram, using ccs-login-bridge to run the OAuth flow in tmux.
//
// One daemon, two loops:
//   detect  (setInterval): parse `ccs ls`, find newly-expired accounts, run
//           `bridge start <email>` to get an OAuth URL, and DM it with
//           instructions. Registers the account as pending a code.
//   reply   (long-poll getUpdates): a message from the configured chat that
//           looks like a code is passed to `bridge submit <email> <code>`;
//           the result is sent back.
//
// Stdlib only (https + child_process + fs): no npm deps, matches server.js.
//
// SECURITY: the OAuth code transits Telegram's servers. It is one-time and
// short-lived, acceptable for personal use. Messages are accepted ONLY from
// TELEGRAM_CHAT_ID; anything else is ignored so a stranger can't inject codes.
// OAuth authorizes whatever account the BROWSER opening the URL is signed in
// to, so the notification tells the human to use an incognito window.
'use strict';

const https = require('https');
const fs = require('fs');
const { execFile } = require('child_process');

const TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';
const CHAT_ID = String(process.env.TELEGRAM_CHAT_ID || '');
const CCS_BIN = process.env.CCS_BIN || 'ccs';
const BRIDGE = process.env.CCS_LOGIN_BRIDGE ||
  '/usr/local/lib/cc-account-switcher/coordinator/ccs-login-bridge.sh';
const OPEN_OAUTH = process.env.CCS_OPEN_OAUTH ||
  '/root/cc-account-switcher/ccs-open-oauth.sh';
const STATE_FILE = process.env.CCS_BOT_STATE_FILE ||
  '/var/lib/ccs-coordinator/telegram-bot-state.json';
const DETECT_INTERVAL_MS = Number(process.env.CCS_BOT_DETECT_INTERVAL || 300) * 1000;
const GASS_SSH = process.env.CCS_GASS_SSH || '/root/cc-account-switcher/connectgass.sh';
const CDP_PORT = process.env.CCS_CDP_PORT || '9333';
const CHROME_SVC_PORT = process.env.CCS_CHROME_SVC_PORT || '9334';
const CODE_POLL_INTERVAL_MS = Number(process.env.CCS_BOT_CODE_POLL_INTERVAL || 5) * 1000;

if (require.main === module && (!TOKEN || !CHAT_ID)) {
  console.error('TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are required');
  process.exit(1);
}

// ---- persisted state ----
// notified: emails already announced as expired (cleared when they recover,
//           so a later re-expiry re-notifies).
// pending:  email -> true, awaiting a code reply.
// users:    authorized chat IDs (strings). Seeded once from TELEGRAM_CHAT_ID
//           (bootstrap owner), then managed at runtime via /adduser /deluser.
let state = { notified: [], pending: {}, users: [], autologinAttempted: [] };
try {
  state = { notified: [], pending: {}, users: [], autologinAttempted: [], ...JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) };
} catch { /* first run: defaults */ }

// Bootstrap the owner from env on first run (or if the list was emptied).
if (state.users.length === 0) {
  state.users.push(CHAT_ID);
}

// Email of an in-flight autologin, or null. One at a time: the flow owns the
// single remote Chrome/CDP port, two runs would stomp each other's tabs.
let autologinRunning = null;

// Auto-queue for expired accounts (detect() feeds this). No retry: an email
// that fails autologin is marked in `autologinAttempted` and won't be
// re-queued until it recovers and expires again (mirrors `notified`).
let autologinQueue = [];

function saveState() {
  try {
    fs.mkdirSync(require('path').dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state));
  } catch (e) {
    console.error('saveState failed:', e.message);
  }
}

// ---- Telegram API (stdlib https) ----
function tg(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(params);
    const req = https.request({
      hostname: 'api.telegram.org',
      path: `/bot${TOKEN}/${method}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (!parsed.ok) return reject(new Error(`${method}: ${parsed.description}`));
          resolve(parsed.result);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// send(text)        -> broadcast to every authorized user (notifs, login URL,
//                       login result — all authorized users share the accounts)
// send(text, chatId) -> reply to one chat (command responses, usage errors)
function send(text, to) {
  const targets = to ? [String(to)] : state.users;
  return Promise.all(targets.map((chat_id) =>
    tg('sendMessage', { chat_id, text, disable_web_page_preview: true })
      .catch((e) => console.error(`send to ${chat_id} failed:`, e.message))
  ));
}

// One message with a tappable inline keyboard, private to `to`. `rows` is an
// array of button rows, each row an array of {text, callback_data}.
function sendKeyboard(text, rows, to) {
  return tg('sendMessage', {
    chat_id: String(to),
    text,
    reply_markup: { inline_keyboard: rows },
  }).catch((e) => console.error(`sendKeyboard to ${to} failed:`, e.message));
}

// ---- bridge / ccs shell-outs ----
function run(cmd, args, timeoutMs = 60000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code || 1) : 0, stdout: stdout || '', stderr: stderr || '' });
    });
  });
}

function parseCcsAddResult(output, email) {
  const escapedEmail = String(email).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const localAdded = new RegExp(`(?:Account added successfully for|(?:Added|Updated) Account \\d+:)\\s*${escapedEmail}(?:\\s|$)`).test(output);
  if (!localAdded) return { localAdded: false, coordinator: 'unknown' };
  if (new RegExp(`Coordinator publish accepted for ${escapedEmail}(?:\\s|$)`).test(output)) {
    return { localAdded: true, coordinator: 'accepted' };
  }
  if (new RegExp(`Coordinator publish rejected for ${escapedEmail}(?:\\s|$)`).test(output)) {
    return { localAdded: true, coordinator: 'rejected' };
  }
  if (new RegExp(`Coordinator publish (?:failed|skipped) for ${escapedEmail}(?:\\s|$)`).test(output)) {
    return { localAdded: true, coordinator: 'unreachable' };
  }
  return { localAdded: true, coordinator: 'unknown' };
}

async function verifyCoordinatorPublish(output, email) {
  const direct = parseCcsAddResult(output, email);
  if (direct.coordinator !== 'unknown') return direct;

  // `coord-push` emits token-free Pushed/Rejected/Failed status. Its exit code
  // is intentionally not trusted: command stays zero for per-account errors.
  const r = await run(CCS_BIN, ['coord-push']);
  const pushOutput = `${r.stdout}\n${r.stderr}`;
  const escapedEmail = String(email).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  let coordinator = 'unknown';
  if (new RegExp(`\\bPushed Account \\d+:\\s*${escapedEmail}(?:\\s|$)`).test(pushOutput)) coordinator = 'accepted';
  // "Rejected ... coordinator has fresher credential" here means the login's
  // own publish already landed (this push is the same-or-older credential) —
  // for verification purposes the coordinator HAS it, so that's success.
  else if (new RegExp(`\\bRejected Account \\d+:\\s*${escapedEmail}(?:\\s|$)`).test(pushOutput)) coordinator = 'accepted';
  else if (new RegExp(`\\bFailed Account \\d+:\\s*${escapedEmail}(?:\\s|$)`).test(pushOutput) || /not configured|nothing pushed|no usable credential/i.test(pushOutput)) coordinator = 'unreachable';
  return { localAdded: direct.localAdded, coordinator };
}

function coordinatorFailureMessage(email, retryCommand, coordinator) {
  const reason = coordinator === 'rejected'
    ? 'coordinator publish rejected'
    : 'coordinator publish unreachable or not configured';
  return `⚠️ ${email}: local login succeeded, but ${reason}. Retry with ${retryCommand}.`;
}

// Parse `ccs ls` into account records. Internal state keys on email (stable
// identity for the bridge); the account number is a UI convenience resolved
// on demand via numToEmail().
async function listAccounts() {
  const { stdout } = await run(CCS_BIN, ['ls']);
  const accounts = []; // {num, email, expired}
  for (const line of stdout.split('\n')) {
    const m = line.match(/^\s*(\[EXPIRED\])?.*?(\d+):\s+(\S+@\S+?)(?:\s|$)/);
    if (!m) continue;
    accounts.push({ num: m[2], email: m[3], expired: /\[EXPIRED\]/.test(line) });
  }
  return accounts;
}

function formatTelegramAccountList(stdout) {
  const icons = {
    OK: '✅',
    RELOGIN_REQUIRED: '🔐',
    EXPIRED: '🔐',
    UNKNOWN: '⚠️',
    THROTTLED: '🟡',
  };
  const lines = [];
  const rawLines = String(stdout).split('\n');
  for (let i = 0; i < rawLines.length; i++) {
    const line = rawLines[i];
    const match = line.match(/^\s*(?:\[[A-Z_]+\]\s+)?\[([A-Z_]+)\]\s+(\d+):\s+(\S+@\S+?)(?:\s|$)/);
    if (!match) continue;
    const [, status, num, email] = match;
    lines.push(`${icons[status] || '⚠️'} ${num}: ${email}`);
    // `ccs ls` puts a "usage: 5h X% | 7d Y% | ..." line directly after the
    // account line — pull just the 5h/7d percents, drop the rest (reset
    // timers, "limit" duplicate) to keep each account to two short lines.
    const usageLine = rawLines[i + 1];
    const usageMatch = usageLine && usageLine.match(/usage:\s*5h\s+(\d+%)\s*\|\s*7d\s+(\d+%)/);
    if (usageMatch) lines.push(`    5h ${usageMatch[1]} · 7d ${usageMatch[2]}`);
  }
  return lines.join('\n') || '(no accounts)';
}

// Convenience view for callers that only care about expired/all email sets.
async function listExpired() {
  const accounts = await listAccounts();
  return {
    accounts,
    expired: new Set(accounts.filter((a) => a.expired).map((a) => a.email)),
    all: new Set(accounts.map((a) => a.email)),
  };
}

// Resolve a user-supplied account number to its email. Returns null if none.
async function numToEmail(num) {
  const accounts = await listAccounts();
  const hit = accounts.find((a) => a.num === String(num));
  return hit ? hit.email : null;
}

// Reverse: email -> account number (for display). Returns '?' if unknown.
function emailToNum(accounts, email) {
  const hit = accounts.find((a) => a.email === email);
  return hit ? hit.num : '?';
}

// Run automated re-login for one account and notify start/result. Shared by
// the manual /autologin command and the auto-queue worker. No retry on
// failure — caller decides whether to mark it as attempted (queue does;
// manual /autologin doesn't, so a human can immediately retry).
async function runAutologin(email, num, { manual } = {}) {
  autologinRunning = email;
  const source = manual ? '/autologin' : 'auto-queue';
  await send(`🤖 Autologin (${source}) started for account ${num} (${email})… (~1-2 min)`);
  try {
    const r = await run('bash', [OPEN_OAUTH, '--auto-click', email], 300000);
    autologinRunning = null;
    const out = (r.stdout.trim() + '\n' + r.stderr.trim()).trim();
    if (parseCcsAddResult(out, email).localAdded) {
      const publish = await verifyCoordinatorPublish(out, email);
      if (publish.localAdded && publish.coordinator === 'accepted') {
        delete state.pending[email];
        state.notified = state.notified.filter((e) => e !== email);
        saveState();
        await send(`✅ Autologin OK: account ${num} (${email}) re-logged in and published.`);
        return true;
      }
      await send(coordinatorFailureMessage(email, `/autologin ${num}`, publish.coordinator));
      return false;
    }
    await send(`❌ Autologin failed for account ${num} (${email}). No retry queued — run /autologin ${num} or /login ${num} manually.`);
    return false;
  } catch (e) {
    autologinRunning = null;
    await send(`❌ Autologin crashed for account ${num} (${email}): ${e.message}. No retry queued — fallback: /login ${num}`);
    return false;
  }
}

// Drain autologinQueue one at a time (autologinRunning is the mutex already
// enforced by runAutologin's single Chrome/CDP port). Each entry attempted
// exactly once: success or failure both mark it done, never re-enqueued
// until the account recovers and expires again.
async function processAutologinQueue() {
  if (autologinRunning) return; // a manual /autologin or prior queue run owns it
  const next = autologinQueue.shift();
  if (!next) return;
  if (!state.autologinAttempted.includes(next.email)) {
    state.autologinAttempted.push(next.email);
    saveState();
  }
  await runAutologin(next.email, next.num, { manual: false });
  setImmediate(processAutologinQueue); // pick up whatever queued while we ran
}

// ---- detect loop ----
const REAP_AGE = Number(process.env.CCS_BOT_REAP_AGE || 900); // seconds

async function detect() {
  // Reap stale login sessions (user got a URL but never replied). Then drop
  // pending entries whose session no longer exists, so a stale pending doesn't
  // block re-notifying that account.
  const reaped = await run('bash', [BRIDGE, 'reap', String(REAP_AGE)]);
  if (reaped.stdout.trim()) console.log('reaped:', reaped.stdout.trim());
  for (const email of Object.keys(state.pending)) {
    const chk = await run('bash', [BRIDGE, 'status', email]);
    if (chk.code !== 0) {
      delete state.pending[email];
      saveState();
      // Keep the account in `notified` — un-notifying here made every
      // abandoned /login re-trigger the expired broadcast each cycle.
      // One timeout notice instead; the user retries with /login when ready.
      await send(`⌛ Login for ${email} timed out (no code received). /login again when ready.`);
    }
  }

  let expired, all, accounts;
  try { ({ expired, all, accounts } = await listExpired()); }
  catch (e) { console.error('detect: ccs ls failed:', e.message); return; }

  // Recovered accounts drop out of `notified`/`autologinAttempted` so a later
  // re-expiry re-notifies and re-queues.
  state.notified = state.notified.filter((e) => expired.has(e));
  state.autologinAttempted = state.autologinAttempted.filter((e) => expired.has(e));

  for (const email of expired) {
    if (state.notified.includes(email)) continue; // already announced this expiry
    state.notified.push(email);
    saveState();
    const num = emailToNum(accounts, email);
    await send(`⚠️ Account ${num} expired: ${email}\nQueuing automated re-login…`);
    if (!state.autologinAttempted.includes(email) && !autologinQueue.some((q) => q.email === email)) {
      autologinQueue.push({ email, num });
    }
  }
  processAutologinQueue();
}

// Sanitize an email the same way ccs-login-bridge.sh's session_name() does
// (`tr -c 'a-zA-Z0-9' '_'`), so a tmux session name can be mapped back to
// the email that owns it.
function sanitizeForSession(email) {
  return String(email).replace(/[^a-zA-Z0-9]/g, '_');
}

// Find every live `ccslogin-*` tmux session and resolve it back to an email
// via listAccounts() (so we only match known accounts, not garbage names).
async function pendingLoginEmails() {
  const r = await run('tmux', ['list-sessions', '-F', '#{session_name}']);
  if (r.code !== 0) return [];
  const sessions = r.stdout.split('\n').filter((l) => l.startsWith('ccslogin-'));
  if (!sessions.length) return [];
  let accounts = [];
  try { accounts = await listAccounts(); } catch { return []; }
  const emails = [];
  for (const s of sessions) {
    const name = s.slice('ccslogin-'.length);
    const hit = accounts.find((a) => sanitizeForSession(a.email) === name);
    if (hit) emails.push(hit.email);
  }
  return emails;
}

// After a successful code submit, log the remote Chrome profile out of
// claude.ai and close it — same cleanup ccs-open-oauth.sh does for the
// --auto-click path, needed here too since pollForStrayCodes/handleText
// submit codes without ever touching the browser afterward (profile was
// staying signed in as this account, so the next login for a different
// account risked silently authorizing as this one instead).
async function logoutAndCloseBrowser(email) {
  const profile = email.split('@')[0];
  try {
    const r = await run('bash', [GASS_SSH, `curl -s --max-time 30 -X PUT 'http://localhost:${CDP_PORT}/json/new?https%3A%2F%2Fclaude.ai%2Flogout'`], 35000);
    const tabId = JSON.parse(r.stdout).id;
    // Wait for the logout page's own load event (capped at 10s) instead of a
    // blind delay, so a slow network doesn't close the browser before the
    // logout request actually lands.
    const waitCmd = `python3 - <<'PYEOF'
import asyncio, websockets, json
async def main():
    uri = 'ws://localhost:${CDP_PORT}/devtools/page/${tabId}'
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
PYEOF`;
    await run('bash', [GASS_SSH, waitCmd], 15000);
  } catch (e) {
    console.error(`logoutAndCloseBrowser: logout nav failed for ${email}:`, e.message);
  }
  try {
    await run('bash', [GASS_SSH, `curl -s --max-time 30 -X POST 'http://localhost:${CHROME_SVC_PORT}/close?profile=${profile}'`], 35000);
  } catch (e) {
    console.error(`logoutAndCloseBrowser: close failed for ${email}:`, e.message);
  }
}

// The `state` query param the OAuth URL for a live login session was started
// with, read straight from the tmux pane ccs-login-bridge.sh's cmd_start left
// behind (same regex it uses to find the URL). Returns null if no state is
// found — caller must not guess.
async function sessionOAuthState(sess) {
  const r = await run('tmux', ['capture-pane', '-J', '-p', '-t', sess]);
  if (r.code !== 0) return null;
  const m = r.stdout.match(/https:\/\/claude\.com\/cai\/oauth\/authorize[^\s]*/);
  if (!m) return null;
  const qs = m[0].split('?', 2)[1];
  if (!qs) return null;
  return new URLSearchParams(qs).get('state');
}

// Independent poller for OAuth codes that never got auto-submitted — e.g. a
// human clicked Authorize manually (captcha blocked the scripted click) after
// the --auto-click script that would have caught it already exited, OR a
// login was started outside the bot entirely (direct `ccs login`, a stray
// bridge `start`). Detection is driven by the live `ccslogin-*` tmux session
// itself (source of truth for "a login is in flight"), not state.pending —
// state.pending is only ever set by the bot's own startLogin(), so it stays
// blind to logins started any other way (this blind spot lost account 28's
// code once already). Only one remote Chrome/CDP instance exists (same
// constraint as runAutologin), so a code found there can only belong to
// whichever single login session is in flight; with more than one, which tab
// belongs to which email is ambiguous and this poller skips it — same
// ambiguity the rest of this codebase already accepts for one CDP port.
let codePollBusy = false;
async function pollForStrayCodes() {
  if (codePollBusy) return;
  const emails = await pendingLoginEmails();
  if (emails.length !== 1) return;
  const email = emails[0];
  if (autologinRunning === email) return; // --auto-click script already owns this code
  codePollBusy = true;
  try {
    // /json/list can still hold a stale target from a PRIOR attempt for this
    // same email (old tab never closed) — matching by state ties the code to
    // THIS session's own OAuth request, not just any callback URL that exists
    // (a stale match here submits an old/already-dead code, which bridge
    // submit's failure path then uses to kill the brand-new tmux session,
    // making a fresh `bridge start` look like it "died on its own").
    const sess = `ccslogin-${sanitizeForSession(email)}`;
    const expectedState = await sessionOAuthState(sess);
    if (!expectedState) return;
    const r = await run('bash', [GASS_SSH, `curl -s --max-time 5 http://localhost:${CDP_PORT}/json/list`], 15000);
    if (r.code !== 0) return;
    let targets;
    try { targets = JSON.parse(r.stdout); } catch { return; }
    let code = null;
    for (const t of targets) {
      const url = t.url || '';
      if (!url.includes('/oauth/code/callback')) continue;
      const qs = url.split('?', 2)[1];
      if (!qs) continue;
      const params = new URLSearchParams(qs);
      const c = params.get('code');
      const s = params.get('state');
      if (c && c !== 'true' && s === expectedState) { code = c + '#' + s; break; }
    }
    if (!code) return;
    const sub = await run('bash', [BRIDGE, 'submit', email, code]);
    const out = (sub.stdout.trim() + '\n' + sub.stderr.trim()).trim();
    // bridge submit kills the tmux session on both success AND failure (see
    // ccs-login-bridge.sh cmd_submit), so pending must clear either way —
    // otherwise a failed submit leaves pending stuck pointing at a dead
    // session and this poller retries it every tick forever.
    delete state.pending[email];
    saveState();
    if (parseCcsAddResult(out, email).localAdded) {
      state.notified = state.notified.filter((e) => e !== email);
      saveState();
      await logoutAndCloseBrowser(email);
      await send(`✅ Code auto-recovered for ${email} (found in browser, no script was watching) and submitted successfully.`);
    } else {
      console.log(`pollForStrayCodes: submit failed for ${email}:`, out);
      await send(`❌ Auto-recovered code for ${email} but submit failed (likely expired by the time it was found). Run /login ${email} again.`);
    }
  } catch (e) {
    console.error('pollForStrayCodes error:', e.message);
  } finally {
    codePollBusy = false;
  }
}

// Run `bridge start <email>`, DM the URL + instructions, mark pending. Shared
// by the detect loop and the /login command. Returns true on success.
async function startLogin(email, num, header) {
  const r = await run('bash', [BRIDGE, 'start', email]);
  const url = r.stdout.trim();
  if (r.code !== 0 || !/^https:\/\//.test(url)) {
    await send(`⚠️ couldn't start login for account ${num} (${email}):\n${r.stderr.trim() || 'no URL'}`);
    return false;
  }
  state.pending[email] = true;
  saveState();
  await send(
    `${header}\n\n` +
    `1. Open in an INCOGNITO window and sign in AS ${email}:\n${url}\n\n` +
    `2. Copy the code shown after authorizing and reply here with just the code` +
    ` (or "${num === '?' ? email : num} <code>" if multiple logins are pending).`
  );
  return true;
}

// ---- reply handling ----
const HELP = [
  'ccs re-login bot commands:',
  '/status — accounts + which are expired/pending',
  '/login <num|email> — re-login an account, or add a NEW account by email',
  '/autologin <num> — fully automated re-login (remote Chrome + auto-click)',
  '/retry — re-queue all expired accounts whose autologin already failed once',
  '/switch <num> — switch active account to <num>',
  '/pending — logins awaiting a code',
  '/cancel <num> — abandon a pending login',
  '/ids — list authorized users',
  '/adduser <chat_id> — authorize another user',
  '/deluser <chat_id> — remove an authorized user',
  '/help — this message',
  '',
  'Reply with just the code to finish a login (or "<num> <code>" if several pending).',
].join('\n');

// Returns true if the message was a command (handled here), false otherwise.
// `from` is the sender's chat id: command replies go only to them, while
// account notifications (login URL, results) broadcast to all users.
async function handleCommand(text, from) {
  const t = text.trim();
  if (!t.startsWith('/')) return false;
  // Strip @botname suffix Telegram adds in groups.
  const [rawCmd, ...rest] = t.split(/\s+/);
  const cmd = rawCmd.replace(/@.*$/, '').toLowerCase();
  const arg = rest.join(' ').trim();
  const reply = (text) => send(text, from); // command replies are private

  switch (cmd) {
    case '/help':
      await reply(HELP);
      return true;
    case '/status': {
      // Telegram needs only central's local account list, not ccs ls details.
      const r = await run(CCS_BIN, ['ls']);
      if (r.code !== 0) { await reply(`ccs ls failed:\n${r.stderr.trim() || 'unknown error'}`); return true; }
      const out = formatTelegramAccountList(r.stdout);
      // Telegram hard-caps messages at 4096 chars.
      await reply(out.length > 4000 ? out.slice(0, 3990) + '\n…(truncated)' : out);
      return true;
    }
    case '/login': {
      // Accepts an existing account number OR an email. An email not yet in
      // `ccs ls` starts a NEW-account login: the bridge runs `ccs login
      // --email X` and cmd_add_account registers it on code capture.
      let email, num;
      if (/^\d+$/.test(arg)) {
        email = await numToEmail(arg);
        if (!email) { await reply(`No account numbered ${arg}. See /status.`); return true; }
        num = arg;
      } else if (/^\S+@\S+\.\S+$/.test(arg)) {
        email = arg.toLowerCase();
        let accounts = [];
        try { accounts = await listAccounts(); } catch { /* new-email path */ }
        num = emailToNum(accounts, email); // '?' when not yet registered
      } else {
        await reply('Usage: /login <num|email> (number from /status, or an email to add a new account)');
        return true;
      }
      const label = num === '?' ? `NEW account (${email})` : `account ${num} (${email})`;
      await reply(`Starting login for ${label}…`);
      await startLogin(email, num, `🔑 /login: ${label}`); // broadcast
      return true;
    }
    case '/autologin': {
      // Fully automated re-login: ccs-open-oauth --auto-click opens Chrome on
      // the gass server (chrome-service), clicks Authorize via CDP, captures
      // the code, submits it to the bridge, and closes Chrome. Takes ~1-2 min.
      if (!arg) {
        // No number given: offer expired accounts as tappable inline buttons
        // instead of forcing the user to cross-reference /status by hand.
        let expired, accounts;
        try { ({ expired, accounts } = await listExpired()); }
        catch (e) { await reply(`ccs ls failed: ${e.message}`); return true; }
        if (!expired.size) { await reply('No expired accounts.'); return true; }
        const buttons = [...expired].map((email) => {
          const num = emailToNum(accounts, email);
          return [{ text: `${num}: ${email}`, callback_data: `autologin:${num}` }];
        });
        await sendKeyboard('Pick an account to autologin:', buttons, from);
        return true;
      }
      if (!/^\d+$/.test(arg)) { await reply('Usage: /autologin <num> (account number from /status)'); return true; }
      const email = await numToEmail(arg);
      if (!email) { await reply(`No account numbered ${arg}. See /status.`); return true; }
      if (autologinRunning) { await reply(`Autologin already running for ${autologinRunning} — wait for it to finish.`); return true; }
      runAutologin(email, arg, { manual: true }); // async, don't block the reply loop
      return true;
    }
    case '/retry': {
      // Re-queue expired accounts whose autologin already failed once
      // (autologinAttempted blocks them from the normal detect-loop
      // auto-queue — see runAutologin's no-retry-on-failure comment).
      // Skips accounts already running or already queued.
      let expired, accounts;
      try { ({ expired, accounts } = await listExpired()); }
      catch (e) { await reply(`ccs ls failed: ${e.message}`); return true; }
      const requeued = [];
      for (const email of expired) {
        if (email === autologinRunning) continue;
        if (autologinQueue.some((q) => q.email === email)) continue;
        state.autologinAttempted = state.autologinAttempted.filter((e) => e !== email);
        const num = emailToNum(accounts, email);
        autologinQueue.push({ email, num });
        requeued.push(`${num}: ${email}`);
      }
      if (!requeued.length) { await reply('Nothing to retry — no expired accounts eligible (already running or queued).'); return true; }
      await reply(`Re-queued for autologin:\n${requeued.join('\n')}`);
      processAutologinQueue();
      return true;
    }
    case '/pending': {
      const pend = Object.keys(state.pending);
      if (!pend.length) { await reply('No pending logins.'); return true; }
      let accounts = [];
      try { accounts = await listAccounts(); } catch { /* fall back to email-only */ }
      const lines = pend.map((e) => `${emailToNum(accounts, e)}: ${e}`);
      await reply(`Awaiting code:\n${lines.join('\n')}`);
      return true;
    }
    case '/cancel': {
      if (!/^\d+$/.test(arg)) { await reply('Usage: /cancel <num> (account number from /status)'); return true; }
      const email = await numToEmail(arg);
      if (!email) { await reply(`No account numbered ${arg}. See /status.`); return true; }
      const r = await run('bash', [BRIDGE, 'cancel', email]);
      delete state.pending[email];
      saveState();
      await reply(`Cancelled account ${arg} (${email}). ${r.stdout.trim()}`);
      return true;
    }
    case '/switch': {
      if (!/^\d+$/.test(arg)) { await reply('Usage: /switch <num> (account number from /status)'); return true; }
      const email = await numToEmail(arg);
      if (!email) { await reply(`No account numbered ${arg}. See /status.`); return true; }
      await reply(`Switching to account ${arg} (${email})…`);
      const r = await run(CCS_BIN, ['to', arg]);
      const out = (r.stdout.trim() + '\n' + r.stderr.trim()).trim();
      // Broadcast: the active account is shared state across all users.
      await send(r.code === 0
        ? `🔀 Switched to account ${arg} (${email}):\n${out || 'done'}`
        : `❌ Switch to ${arg} failed:\n${out || 'unknown error'}`);
      return true;
    }
    case '/ids': {
      const lines = state.users.map((u) => `${u}${u === from ? ' (you)' : ''}`);
      await reply(`Authorized users (${state.users.length}):\n${lines.join('\n')}`);
      return true;
    }
    case '/adduser': {
      if (!/^-?\d+$/.test(arg)) { await reply('Usage: /adduser <chat_id> (get it from /ids run by that user, or forward their message)'); return true; }
      if (state.users.includes(arg)) { await reply(`${arg} already authorized.`); return true; }
      state.users.push(arg);
      saveState();
      await reply(`Added ${arg}. Now ${state.users.length} authorized.`);
      await send(`👋 You've been added to the ccs re-login bot. /help for commands.`, arg);
      return true;
    }
    case '/deluser': {
      if (!/^-?\d+$/.test(arg)) { await reply('Usage: /deluser <chat_id> (see /ids)'); return true; }
      if (!state.users.includes(arg)) { await reply(`${arg} not in the list. See /ids.`); return true; }
      if (state.users.length === 1) { await reply('Refusing to remove the last user — you would lock everyone out.'); return true; }
      state.users = state.users.filter((u) => u !== arg);
      saveState();
      await reply(`Removed ${arg}. Now ${state.users.length} authorized.`);
      return true;
    }
    default:
      await reply(`Unknown command ${cmd}. /help for the list.`);
      return true;
  }
}

async function handleText(text, from) {
  if (await handleCommand(text, from)) return; // slash command, done

  const pendingEmails = Object.keys(state.pending);
  if (pendingEmails.length === 0) return; // nothing to submit to

  const reply = (t) => send(t, from); // sender-only until we have a result
  let email, code;
  // "<num> <code>" or "<email> <code>" disambiguates when several logins are
  // pending (email form is the only handle for a new, unnumbered account). A
  // bare reply (just the code) is only accepted when exactly one is pending.
  const twoPart = text.trim().match(/^(\d+)\s+(\S.*)$/);
  const emailPart = text.trim().match(/^(\S+@\S+\.\S+)\s+(\S.*)$/);
  if (twoPart) {
    email = await numToEmail(twoPart[1]);
    code = twoPart[2].trim();
    if (!email) { await reply(`No account numbered ${twoPart[1]}. See /status.`); return; }
  } else if (emailPart) {
    email = emailPart[1].toLowerCase();
    code = emailPart[2].trim();
  } else if (pendingEmails.length === 1) {
    email = pendingEmails[0];
    code = text.trim();
  } else {
    let accounts = [];
    try { accounts = await listAccounts(); } catch { /* email-only fallback */ }
    const list = pendingEmails.map((e) => `${emailToNum(accounts, e)}: ${e}`).join('\n');
    await reply(`Multiple logins pending:\n${list}\n\nReply "<num> <code>".`);
    return;
  }

  if (!state.pending[email]) {
    await reply(`No pending login for ${email}. Pending: ${pendingEmails.join(', ') || 'none'}.`);
    return;
  }

  await reply(`Submitting code for ${email}…`);
  const r = await run('bash', [BRIDGE, 'submit', email, code]);
  delete state.pending[email];
  const bridgeOutput = `${r.stdout}\n${r.stderr}`;
  if (parseCcsAddResult(bridgeOutput, email).localAdded) {
    const publish = await verifyCoordinatorPublish(bridgeOutput, email);
    if (publish.localAdded && publish.coordinator === 'accepted') {
      // A successful capture means it's no longer expired; let a future
      // re-expiry re-notify. Broadcast: the account is shared across all users.
      state.notified = state.notified.filter((e) => e !== email);
      await send(`✅ ${email}: logged in and published.`);
    } else {
      await send(coordinatorFailureMessage(email, `/login ${email}`, publish.coordinator));
    }
  } else {
    await send(`❌ ${email} login failed. Run /login ${email} again to retry.`);
  }
  saveState();
}

// ---- long-poll loop ----
let offset = 0;
async function poll() {
  try {
    const updates = await tg('getUpdates', { offset, timeout: 50, allowed_updates: ['message', 'callback_query'] });
    for (const u of updates) {
      offset = u.update_id + 1;
      if (u.callback_query) {
        const cq = u.callback_query;
        const from = String(cq.from.id);
        tg('answerCallbackQuery', { callback_query_id: cq.id }).catch((e) => console.error('answerCallbackQuery failed:', e.message));
        if (!state.users.includes(from)) continue; // ignore taps from non-authorized chats
        const m = /^autologin:(\d+)$/.exec(cq.data || '');
        if (!m) continue;
        const num = m[1];
        const email = await numToEmail(num);
        if (!email) { await send(`No account numbered ${num}. See /status.`, from); continue; }
        if (autologinRunning) { await send(`Autologin already running for ${autologinRunning} — wait for it to finish.`, from); continue; }
        runAutologin(email, num, { manual: true }); // async, don't block the reply loop
        continue;
      }
      const msg = u.message;
      if (!msg || !msg.text) continue;
      const from = String(msg.chat.id);
      // /start works for anyone (even non-authorized) so a new user can learn
      // their own chat id to hand to an owner for /adduser.
      if (/^\/start(@\S+)?\s*$/.test(msg.text.trim())) {
        const authed = state.users.includes(from);
        await send(
          `User id kamu: ${from}\n` +
          (authed ? 'Kamu sudah authorized. /help untuk daftar command.'
                  : 'Kamu belum authorized. Kasih id ini ke admin untuk /adduser.'),
          from
        );
        continue;
      }
      if (!state.users.includes(from)) continue; // ignore non-authorized chats
      await handleText(msg.text, from);
    }
  } catch (e) {
    console.error('poll error:', e.message);
    await new Promise((r) => setTimeout(r, 5000)); // back off on transient failure
  }
  setImmediate(poll);
}

// Registers Telegram's native "/" menu button with our command list. Runs
// once at startup — not user-triggered, so a failure here is non-fatal.
function registerCommands() {
  const commands = [
    { command: 'status', description: 'accounts + which are expired/pending' },
    { command: 'login', description: 're-login <num|email>, or add a NEW account by email' },
    { command: 'autologin', description: 'automated re-login <num>, or tap-to-pick if omitted' },
    { command: 'retry', description: 're-queue expired accounts whose autologin already failed' },
    { command: 'switch', description: 'switch active account to <num>' },
    { command: 'pending', description: 'logins awaiting a code' },
    { command: 'cancel', description: 'abandon a pending login <num>' },
    { command: 'ids', description: 'list authorized users' },
    { command: 'adduser', description: 'authorize another user <chat_id>' },
    { command: 'deluser', description: 'remove an authorized user <chat_id>' },
    { command: 'help', description: 'this message' },
  ];
  tg('setMyCommands', { commands }).catch((e) => console.error('setMyCommands failed:', e.message));
}

if (require.main === module) {
  saveState(); // persist bootstrapped user list
  console.log(`ccs-telegram-bot up. detect every ${DETECT_INTERVAL_MS / 1000}s, ${state.users.length} authorized user(s).`);
  registerCommands();
  detect();
  setInterval(detect, DETECT_INTERVAL_MS);
  setInterval(pollForStrayCodes, CODE_POLL_INTERVAL_MS);
  poll();
}

module.exports = { parseCcsAddResult, coordinatorFailureMessage };
