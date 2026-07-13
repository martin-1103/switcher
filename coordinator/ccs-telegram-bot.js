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
let state = { notified: [], pending: {} };
try {
  state = { notified: [], pending: {}, ...JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) };
} catch { /* first run: defaults */ }

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

function send(text) {
  return tg('sendMessage', { chat_id: CHAT_ID, text, disable_web_page_preview: true })
    .catch((e) => console.error('send failed:', e.message));
}

// ---- bridge / ccs shell-outs ----
function run(cmd, args) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 60000 }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code || 1) : 0, stdout: stdout || '', stderr: stderr || '' });
    });
  });
}

async function listExpired() {
  const { stdout } = await run(CCS_BIN, ['ls']);
  const expired = new Set();
  const all = new Set();
  for (const line of stdout.split('\n')) {
    const m = line.match(/^\s*(\[EXPIRED\])?.*?\d+:\s+(\S+@\S+?)(?:\s|$)/);
    if (!m) continue;
    all.add(m[2]);
    if (/\[EXPIRED\]/.test(line)) expired.add(m[2]);
  }
  return { expired, all };
}

// ---- detect loop ----
async function detect() {
  let expired, all;
  try { ({ expired, all } = await listExpired()); }
  catch (e) { console.error('detect: ccs ls failed:', e.message); return; }

  // Recovered accounts drop out of `notified` so re-expiry re-notifies.
  state.notified = state.notified.filter((e) => expired.has(e));

  for (const email of expired) {
    if (state.notified.includes(email)) continue; // already announced
    if (state.pending[email]) continue;            // already awaiting a code
    state.notified.push(email); // mark before start so a failed start doesn't retry every interval
    saveState();
    await startLogin(email, `🔑 Account expired: ${email}`);
  }
}

// Run `bridge start <email>`, DM the URL + instructions, mark pending. Shared
// by the detect loop and the /login command. Returns true on success.
async function startLogin(email, header) {
  const r = await run('bash', [BRIDGE, 'start', email]);
  const url = r.stdout.trim();
  if (r.code !== 0 || !/^https:\/\//.test(url)) {
    await send(`⚠️ couldn't start login for ${email}:\n${r.stderr.trim() || 'no URL'}`);
    return false;
  }
  state.pending[email] = true;
  saveState();
  await send(
    `${header}\n\n` +
    `1. Open in an INCOGNITO window and sign in AS ${email}:\n${url}\n\n` +
    `2. Copy the code shown after authorizing and reply here with just the code` +
    ` (or "${email} <code>" if multiple logins are pending).`
  );
  return true;
}

// ---- reply handling ----
const HELP = [
  'ccs re-login bot commands:',
  '/status — accounts + which are expired/pending',
  '/login <email> — start a re-login now (don\'t wait for expiry)',
  '/pending — logins awaiting a code',
  '/cancel <email> — abandon a pending login',
  '/help — this message',
  '',
  'Reply with just the code to finish a login (or "<email> <code>" if several pending).',
].join('\n');

// Returns true if the message was a command (handled here), false otherwise.
async function handleCommand(text) {
  const t = text.trim();
  if (!t.startsWith('/')) return false;
  // Strip @botname suffix Telegram adds in groups.
  const [rawCmd, ...rest] = t.split(/\s+/);
  const cmd = rawCmd.replace(/@.*$/, '').toLowerCase();
  const arg = rest.join(' ').trim();

  switch (cmd) {
    case '/help':
    case '/start':
      await send(HELP);
      return true;
    case '/status': {
      let expired, all;
      try { ({ expired, all } = await listExpired()); }
      catch (e) { await send(`ccs ls failed: ${e.message}`); return true; }
      const pend = Object.keys(state.pending);
      const lines = [...all].sort().map((e) => {
        const tags = [];
        if (expired.has(e)) tags.push('EXPIRED');
        if (state.pending[e]) tags.push('pending-code');
        return `${tags.length ? tags.join(',') + ' ' : 'ok '}${e}`;
      });
      await send(
        `${all.size} accounts, ${expired.size} expired, ${pend.length} awaiting code:\n\n` +
        lines.join('\n')
      );
      return true;
    }
    case '/login': {
      if (!/\S+@\S+/.test(arg)) { await send('Usage: /login <email>'); return true; }
      await send(`Starting login for ${arg}…`);
      await startLogin(arg, `🔑 /login: ${arg}`);
      return true;
    }
    case '/pending': {
      const pend = Object.keys(state.pending);
      await send(pend.length ? `Awaiting code:\n${pend.join('\n')}` : 'No pending logins.');
      return true;
    }
    case '/cancel': {
      if (!/\S+@\S+/.test(arg)) { await send('Usage: /cancel <email>'); return true; }
      const r = await run('bash', [BRIDGE, 'cancel', arg]);
      delete state.pending[arg];
      saveState();
      await send(`Cancelled ${arg}. ${r.stdout.trim()}`);
      return true;
    }
    default:
      await send(`Unknown command ${cmd}. /help for the list.`);
      return true;
  }
}

async function handleText(text) {
  if (await handleCommand(text)) return; // slash command, done

  const pendingEmails = Object.keys(state.pending);
  if (pendingEmails.length === 0) return; // nothing to submit to

  let email, code;
  const twoPart = text.trim().match(/^(\S+@\S+)\s+(\S.*)$/);
  if (twoPart) {
    email = twoPart[1];
    code = twoPart[2].trim();
  } else if (pendingEmails.length === 1) {
    email = pendingEmails[0];
    code = text.trim();
  } else {
    await send(`Multiple logins pending (${pendingEmails.join(', ')}). Reply "<email> <code>".`);
    return;
  }

  if (!state.pending[email]) {
    await send(`No pending login for ${email}. Pending: ${pendingEmails.join(', ') || 'none'}.`);
    return;
  }

  await send(`Submitting code for ${email}…`);
  const r = await run('bash', [BRIDGE, 'submit', email, code]);
  delete state.pending[email];
  if (r.code === 0) {
    // A successful capture means it's no longer expired; let a future
    // re-expiry re-notify.
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
      if (String(msg.chat.id) !== CHAT_ID) continue; // ignore everyone else
      await handleText(msg.text);
    }
  } catch (e) {
    console.error('poll error:', e.message);
    await new Promise((r) => setTimeout(r, 5000)); // back off on transient failure
  }
  setImmediate(poll);
}

console.log(`ccs-telegram-bot up. detect every ${DETECT_INTERVAL_MS / 1000}s, chat ${CHAT_ID}.`);
detect();
setInterval(detect, DETECT_INTERVAL_MS);
poll();
