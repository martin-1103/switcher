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
const STATE_FILE = process.env.CCS_BOT_STATE_FILE ||
  '/var/lib/ccs-coordinator/telegram-bot-state.json';
const DETECT_INTERVAL_MS = Number(process.env.CCS_BOT_DETECT_INTERVAL || 300) * 1000;

if (!TOKEN || !CHAT_ID) {
  console.error('TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are required');
  process.exit(1);
}

// ---- persisted state ----
// notified: emails already announced as expired (cleared when they recover,
//           so a later re-expiry re-notifies).
// pending:  email -> true, awaiting a code reply.
// users:    authorized chat IDs (strings). Seeded once from TELEGRAM_CHAT_ID
//           (bootstrap owner), then managed at runtime via /adduser /deluser.
let state = { notified: [], pending: {}, users: [] };
try {
  state = { notified: [], pending: {}, users: [], ...JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) };
} catch { /* first run: defaults */ }

// Bootstrap the owner from env on first run (or if the list was emptied).
if (state.users.length === 0) {
  state.users.push(CHAT_ID);
}

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

// ---- bridge / ccs shell-outs ----
function run(cmd, args) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 60000 }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code || 1) : 0, stdout: stdout || '', stderr: stderr || '' });
    });
  });
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
      // Also un-notify so a still-expired account gets a fresh URL next cycle.
      state.notified = state.notified.filter((e) => e !== email);
      saveState();
    }
  }

  let expired, all, accounts;
  try { ({ expired, all, accounts } = await listExpired()); }
  catch (e) { console.error('detect: ccs ls failed:', e.message); return; }

  // Recovered accounts drop out of `notified` so re-expiry re-notifies.
  state.notified = state.notified.filter((e) => expired.has(e));

  for (const email of expired) {
    if (state.notified.includes(email)) continue; // already announced
    if (state.pending[email]) continue;            // already awaiting a code
    state.notified.push(email); // mark before start so a failed start doesn't retry every interval
    saveState();
    const num = emailToNum(accounts, email);
    await startLogin(email, num, `🔑 Account ${num} expired: ${email}`);
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
    ` (or "${num} <code>" if multiple logins are pending).`
  );
  return true;
}

// ---- reply handling ----
const HELP = [
  'ccs re-login bot commands:',
  '/status — accounts + which are expired/pending',
  '/login <num> — start a re-login now (don\'t wait for expiry)',
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
      // Forward `ccs ls` verbatim (usage/reset/tags) — no reparse — then
      // append the bot-only pending-code list, which ccs ls doesn't know.
      const r = await run(CCS_BIN, ['ls']);
      if (r.code !== 0) { await reply(`ccs ls failed:\n${r.stderr.trim() || 'unknown error'}`); return true; }
      let out = r.stdout.trim() || '(no accounts)';
      const pend = Object.keys(state.pending);
      if (pend.length) {
        let accounts = [];
        try { accounts = await listAccounts(); } catch { /* email-only */ }
        out += '\n\nAwaiting code:\n' + pend.map((e) => `  ${emailToNum(accounts, e)}: ${e}`).join('\n');
      }
      // Telegram hard-caps messages at 4096 chars.
      await reply(out.length > 4000 ? out.slice(0, 3990) + '\n…(truncated)' : out);
      return true;
    }
    case '/login': {
      if (!/^\d+$/.test(arg)) { await reply('Usage: /login <num> (account number from /status)'); return true; }
      const email = await numToEmail(arg);
      if (!email) { await reply(`No account numbered ${arg}. See /status.`); return true; }
      await reply(`Starting login for account ${arg} (${email})…`);
      await startLogin(email, arg, `🔑 /login: account ${arg} (${email})`); // broadcast
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
  // "<num> <code>" disambiguates when several logins are pending. A bare
  // reply (just the code) is only accepted when exactly one is pending.
  const twoPart = text.trim().match(/^(\d+)\s+(\S.*)$/);
  if (twoPart) {
    email = await numToEmail(twoPart[1]);
    code = twoPart[2].trim();
    if (!email) { await reply(`No account numbered ${twoPart[1]}. See /status.`); return; }
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
  if (r.code === 0) {
    // A successful capture means it's no longer expired; let a future
    // re-expiry re-notify. Broadcast: the account is shared across all users.
    state.notified = state.notified.filter((e) => e !== email);
    await send(`✅ ${email}: ${r.stdout.trim() || 'logged in'}`);
  } else {
    await send(`❌ ${email} login failed:\n${r.stderr.trim() || 'unknown error'}\nRun the login again to retry.`);
  }
  saveState();
}

// ---- long-poll loop ----
let offset = 0;
async function poll() {
  try {
    const updates = await tg('getUpdates', { offset, timeout: 50, allowed_updates: ['message'] });
    for (const u of updates) {
      offset = u.update_id + 1;
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

saveState(); // persist bootstrapped user list
console.log(`ccs-telegram-bot up. detect every ${DETECT_INTERVAL_MS / 1000}s, ${state.users.length} authorized user(s).`);
detect();
setInterval(detect, DETECT_INTERVAL_MS);
poll();
