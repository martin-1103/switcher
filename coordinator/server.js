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
    const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    if (!state.leases || typeof state.leases !== 'object') {
      state.leases = {};
    }
    return state;
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
    if (!lease) {
      delete state.leases[email];
      continue;
    }

    if (lease.holders && typeof lease.holders === 'object') {
      for (const [serverId, holder] of Object.entries(lease.holders)) {
        if (!holder || Number(holder.leaseExpiresAt || 0) <= now) {
          delete lease.holders[serverId];
        }
      }
      if (Object.keys(lease.holders).length === 0) {
        delete state.leases[email];
      }
      continue;
    }

    if (Number(lease.leaseExpiresAt || 0) <= now) {
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

function upgradeLeaseRecord(email, lease) {
  if (!lease) return null;
  if (lease.holders && typeof lease.holders === 'object') {
    return lease;
  }
  const serverId = String(lease.serverId || '').trim();
  if (!serverId) return null;
  return {
    email,
    accountType: lease.accountType || null,
    holders: {
      [serverId]: {
        ...lease,
        email,
        serverId,
      },
    },
  };
}

function flattenLease(email, lease) {
  const record = upgradeLeaseRecord(email, lease);
  if (!record) return null;
  const holders = Object.values(record.holders || {}).sort((a, b) => Number(b.updatedAt || 0) - Number(a.updatedAt || 0));
  const latest = holders[0] || {};
  return {
    email,
    accountType: latest.accountType || record.accountType || null,
    holderCount: holders.length,
    leaseExpiresAt: Math.max(...holders.map(h => Number(h.leaseExpiresAt || 0)), 0),
    updatedAt: Math.max(...holders.map(h => Number(h.updatedAt || 0)), 0),
    latestSnapshot: {
      activeLimit: Number(latest.activeLimit || 0),
      fiveHour: Number(latest.fiveHour || 0),
      sevenDay: Number(latest.sevenDay || 0),
      resetAt5h: latest.resetAt5h || null,
      resetAt7d: latest.resetAt7d || null,
      observedAt: Number(latest.observedAt || 0),
    },
    holders,
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
      const leases = Object.entries(state.leases)
        .map(([email, lease]) => flattenLease(email, lease))
        .filter(Boolean);
      saveState(state);
      return send(res, 200, { leases });
    }

    if (req.method === 'GET' && url.pathname === '/v1/leases/owner') {
      const email = String(url.searchParams.get('email') || '').trim();
      const serverId = String(url.searchParams.get('serverId') || '').trim();
      const lease = flattenLease(email, state.leases[email]);
      saveState(state);
      if (!lease) {
        return send(res, 200, { owner: null, owners: [], holderCount: 0 });
      }
      const owners = lease.holders.filter(holder => !serverId || holder.serverId !== serverId);
      return send(res, 200, {
        owner: owners[0] || null,
        owners,
        holderCount: owners.length,
      });
    }

    if (req.method === 'POST' && url.pathname === '/v1/leases/claim') {
      const body = normalizeLease(await readJson(req));
      if (!body.email || !body.serverId) {
        return send(res, 400, { error: 'email and serverId required' });
      }
      const existing = upgradeLeaseRecord(body.email, state.leases[body.email]) || {
        email: body.email,
        accountType: body.accountType || null,
        holders: {},
      };
      existing.accountType = body.accountType || existing.accountType || null;
      existing.holders[body.serverId] = body;
      state.leases[body.email] = existing;
      saveState(state);
      return send(res, 200, { ok: true, lease: flattenLease(body.email, state.leases[body.email]) });
    }

    if (req.method === 'POST' && url.pathname === '/v1/leases/release') {
      const body = await readJson(req);
      const email = String(body.email || '').trim();
      const serverId = String(body.serverId || '').trim();
      const lease = upgradeLeaseRecord(email, state.leases[email]);
      if (lease) {
        if (serverId) {
          delete lease.holders[serverId];
        } else {
          lease.holders = {};
        }
        if (Object.keys(lease.holders).length === 0) {
          delete state.leases[email];
        } else {
          state.leases[email] = lease;
        }
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
