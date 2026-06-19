#!/usr/bin/env node

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const PORT = Number(process.env.CCS_COORD_PORT || 19090);
const HOST = process.env.CCS_COORD_HOST || '0.0.0.0';
const TOKEN = process.env.CCS_COORD_TOKEN || '';
const STATE_FILE = process.env.CCS_COORD_STATE_FILE || '/var/lib/ccs-coordinator/state.json';
const LEASE_TTL = Number(process.env.CCS_COORD_LEASE_TTL || 180);

if (!TOKEN) {
  console.error('CCS_COORD_TOKEN is required');
  process.exit(1);
}

fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return { leases: {} };
  }
}

function saveState(state) {
  const temp = `${STATE_FILE}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(state, null, 2));
  fs.renameSync(temp, STATE_FILE);
}

function cleanupExpired(state, now = Date.now()) {
  for (const [email, lease] of Object.entries(state.leases || {})) {
    if (!lease || Number(lease.leaseExpiresAt || 0) <= now) {
      delete state.leases[email];
    }
  }
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error('payload too large'));
      }
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

function send(res, code, payload) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload));
}

function unauthorized(res) {
  send(res, 401, { error: 'unauthorized' });
}

function authOk(req) {
  const header = req.headers.authorization || '';
  return header === `Bearer ${TOKEN}`;
}

function normalizeLease(input) {
  const now = Date.now();
  const ttlMs = Math.max(30, Number(input.leaseTtlSeconds || LEASE_TTL)) * 1000;
  return {
    email: String(input.email || '').trim(),
    serverId: String(input.serverId || '').trim(),
    accountNumber: Number(input.accountNumber || 0),
    accountType: input.accountType || null,
    activeLimit: Number(input.activeLimit || 0),
    fiveHour: Number(input.fiveHour || 0),
    sevenDay: Number(input.sevenDay || 0),
    resetAt5h: input.resetAt5h || null,
    resetAt7d: input.resetAt7d || null,
    observedAt: Number(input.observedAt || 0),
    updatedAt: now,
    leaseExpiresAt: now + ttlMs,
  };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    if (req.method === 'GET' && url.pathname === '/health') {
      return send(res, 200, { ok: true, port: PORT, stateFile: STATE_FILE });
    }

    if (!authOk(req)) {
      return unauthorized(res);
    }

    const state = loadState();
    cleanupExpired(state);

    if (req.method === 'GET' && url.pathname === '/v1/leases') {
      saveState(state);
      return send(res, 200, { leases: Object.values(state.leases) });
    }

    if (req.method === 'GET' && url.pathname === '/v1/leases/owner') {
      const email = String(url.searchParams.get('email') || '').trim();
      const serverId = String(url.searchParams.get('serverId') || '').trim();
      const lease = state.leases[email];
      saveState(state);
      if (!lease || (serverId && lease.serverId === serverId)) {
        return send(res, 200, { owner: null });
      }
      return send(res, 200, { owner: lease });
    }

    if (req.method === 'POST' && url.pathname === '/v1/leases/claim') {
      const body = normalizeLease(await readJson(req));
      if (!body.email || !body.serverId) {
        return send(res, 400, { error: 'email and serverId required' });
      }
      state.leases[body.email] = body;
      saveState(state);
      return send(res, 200, { ok: true, lease: body });
    }

    if (req.method === 'POST' && url.pathname === '/v1/leases/release') {
      const body = await readJson(req);
      const email = String(body.email || '').trim();
      const serverId = String(body.serverId || '').trim();
      const lease = state.leases[email];
      if (lease && (!serverId || lease.serverId === serverId)) {
        delete state.leases[email];
      }
      saveState(state);
      return send(res, 200, { ok: true });
    }

    return send(res, 404, { error: 'not found' });
  } catch (err) {
    return send(res, 500, { error: err.message || 'internal error' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`ccs-coordinator listening on ${HOST}:${PORT}`);
});
