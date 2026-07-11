#!/usr/bin/env node

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { URL } = require('url');

const PORT = Number(process.env.CCS_COORD_PORT || 19090);
const HOST = process.env.CCS_COORD_HOST || '0.0.0.0';
const TOKEN = process.env.CCS_COORD_TOKEN || '';
const STATE_FILE = process.env.CCS_COORD_STATE_FILE || '/var/lib/ccs-coordinator/state.json';
const LEASE_TTL = Number(process.env.CCS_COORD_LEASE_TTL || 180);
const CRED_KEY_HEX = process.env.CCS_COORD_CRED_KEY || '';

if (!TOKEN) {
  console.error('CCS_COORD_TOKEN is required');
  process.exit(1);
}

// Credential publish/fetch endpoints are opt-in: only enabled once a key is
// configured, so a deploy that never sets it can never persist tokens in
// plaintext by accident.
let CRED_KEY = null;
if (CRED_KEY_HEX) {
  const keyBuf = Buffer.from(CRED_KEY_HEX, 'hex');
  if (keyBuf.length !== 32) {
    console.error('CCS_COORD_CRED_KEY must be 32 bytes hex-encoded (64 hex chars)');
    process.exit(1);
  }
  CRED_KEY = keyBuf;
}

function encryptCredential(plaintextObj) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', CRED_KEY, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(plaintextObj), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    iv: iv.toString('base64'),
    tag: tag.toString('base64'),
    ciphertext: ciphertext.toString('base64'),
  };
}

function decryptCredential(record) {
  const iv = Buffer.from(record.iv, 'base64');
  const tag = Buffer.from(record.tag, 'base64');
  const ciphertext = Buffer.from(record.ciphertext, 'base64');
  const decipher = crypto.createDecipheriv('aes-256-gcm', CRED_KEY, iv);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return JSON.parse(plaintext.toString('utf8'));
}

fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });

function loadState() {
  try {
    const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    if (!state.leases || typeof state.leases !== 'object') {
      state.leases = {};
    }
    if (!state.usageSnapshots || typeof state.usageSnapshots !== 'object') {
      state.usageSnapshots = {};
    }
    if (!state.credentials || typeof state.credentials !== 'object') {
      state.credentials = {};
    }
    return state;
  } catch {
    return { leases: {}, usageSnapshots: {}, credentials: {} };
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

function flattenLease(email, lease, usageSnapshot) {
  const record = upgradeLeaseRecord(email, lease);
  const holders = record ? Object.values(record.holders || {}).sort((a, b) => Number(b.updatedAt || 0) - Number(a.updatedAt || 0)) : [];
  const latest = holders[0];
  // Prefer a live holder's snapshot (freshest, tied to an active lease); fall
  // back to the persisted last-known snapshot when no server currently holds
  // the lease — usage data must survive lease expiry, it isn't exclusivity state.
  const source = latest || usageSnapshot;
  if (!source) return null;
  return {
    email,
    accountType: (latest && latest.accountType) || (record && record.accountType) || (usageSnapshot && usageSnapshot.accountType) || null,
    holderCount: holders.length,
    leaseExpiresAt: holders.length ? Math.max(...holders.map(h => Number(h.leaseExpiresAt || 0)), 0) : 0,
    updatedAt: Number(source.updatedAt || 0),
    latestSnapshot: {
      accountNumber: Number(source.accountNumber || 0) || null,
      serverId: source.serverId || null,
      activeLimit: Number(source.activeLimit || 0),
      fiveHour: Number(source.fiveHour || 0),
      sevenDay: Number(source.sevenDay || 0),
      resetAt5h: source.resetAt5h || null,
      resetAt7d: source.resetAt7d || null,
      observedAt: Number(source.observedAt || 0),
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

    const now = Date.now();
    const state = loadState();
    cleanupExpired(state, now);

    if (req.method === 'GET' && url.pathname === '/v1/leases') {
      const emails = new Set([...Object.keys(state.leases), ...Object.keys(state.usageSnapshots)]);
      const leases = Array.from(emails)
        .map(email => flattenLease(email, state.leases[email], state.usageSnapshots[email]))
        .filter(Boolean);
      saveState(state);
      return send(res, 200, { leases });
    }

    if (req.method === 'GET' && url.pathname === '/v1/leases/owner') {
      const email = String(url.searchParams.get('email') || '').trim();
      const serverId = String(url.searchParams.get('serverId') || '').trim();
      const lease = flattenLease(email, state.leases[email], state.usageSnapshots[email]);
      saveState(state);
      if (!lease) {
        return send(res, 200, { owner: null, owners: [], holderCount: 0 });
      }
      const owners = lease.holders.filter(holder => !serverId || holder.serverId !== serverId);
      // No live holder (lease expired) but a persisted usage snapshot exists:
      // surface it as a synthetic, non-exclusive "owner" so callers still see
      // the last-known usage instead of it vanishing with the lease.
      const fallbackOwner = owners.length === 0 && lease.holderCount === 0
        ? { ...lease.latestSnapshot, email, observedAt: lease.latestSnapshot.observedAt }
        : null;
      return send(res, 200, {
        owner: owners[0] || fallbackOwner,
        owners,
        holderCount: owners.length,
      });
    }

    if (req.method === 'POST' && url.pathname === '/v1/leases/claim') {
      const raw = await readJson(req);
      const exclusive = raw.exclusive === true;
      const body = normalizeLease(raw);
      if (!body.email || !body.serverId) {
        return send(res, 400, { error: 'email and serverId required' });
      }
      // Reload fresh AFTER the await, then check+mutate+save synchronously with
      // no further await. Node is single-threaded, so this whole sequence runs
      // atomically — it closes the load→await→save race where two overlapping
      // claims could each save over the other and drop a holder.
      const fresh = loadState();
      cleanupExpired(fresh, now);
      const existing = upgradeLeaseRecord(body.email, fresh.leases[body.email]) || {
        email: body.email,
        accountType: body.accountType || null,
        holders: {},
      };
      // Exclusive claim: refuse if ANOTHER server already holds a live lease on
      // this account. This lets a client claim-before-switch and only switch on
      // 200, so two servers can never converge on the same account.
      if (exclusive) {
        const conflict = Object.values(existing.holders || {}).some(
          h => h && h.serverId !== body.serverId && Number(h.leaseExpiresAt || 0) > now,
        );
        if (conflict) {
          return send(res, 409, {
            error: 'conflict',
            lease: flattenLease(body.email, fresh.leases[body.email]),
          });
        }
      }
      existing.accountType = body.accountType || existing.accountType || null;
      existing.holders[body.serverId] = body;
      fresh.leases[body.email] = existing;
      // Persist the usage snapshot outside the lease, keyed only by email, so
      // it survives lease expiry (cleanupExpired only touches state.leases).
      fresh.usageSnapshots[body.email] = { ...body };
      saveState(fresh);
      return send(res, 200, { ok: true, lease: flattenLease(body.email, fresh.leases[body.email], fresh.usageSnapshots[body.email]) });
    }

    if (req.method === 'POST' && url.pathname === '/v1/credentials/publish') {
      if (!CRED_KEY) {
        return send(res, 501, { error: 'credential store not configured (CCS_COORD_CRED_KEY unset)' });
      }
      const body = await readJson(req);
      const email = String(body.email || '').trim();
      const accessToken = String(body.accessToken || '');
      const refreshToken = String(body.refreshToken || '');
      const expiresAt = Number(body.expiresAt || 0);
      const scopes = Array.isArray(body.scopes) ? body.scopes : [];
      if (!email || !accessToken || !refreshToken) {
        return send(res, 400, { error: 'email, accessToken, refreshToken required' });
      }
      // Reload fresh AFTER the await, mutate+save synchronously — same
      // atomic-claim pattern as /v1/leases/claim, closes the same race.
      const fresh = loadState();
      const existing = fresh.credentials[email];
      // Freshness compare on expiresAt (not wall-clock updatedAt): a host that
      // just refreshed always has a later expiresAt than a stale copy, so this
      // is safe even if server clocks disagree slightly.
      if (existing) {
        const existingPlain = decryptCredential(existing);
        if (Number(existingPlain.expiresAt || 0) >= expiresAt) {
          return send(res, 200, { ok: true, accepted: false, reason: 'existing credential is fresher or equal' });
        }
      }
      fresh.credentials[email] = encryptCredential({ accessToken, refreshToken, expiresAt, scopes, updatedAt: now });
      saveState(fresh);
      return send(res, 200, { ok: true, accepted: true });
    }

    if (req.method === 'GET' && url.pathname === '/v1/credentials/fetch') {
      if (!CRED_KEY) {
        return send(res, 501, { error: 'credential store not configured (CCS_COORD_CRED_KEY unset)' });
      }
      const email = String(url.searchParams.get('email') || '').trim();
      if (!email) {
        return send(res, 400, { error: 'email required' });
      }
      const record = state.credentials[email];
      if (!record) {
        return send(res, 404, { error: 'not found' });
      }
      return send(res, 200, decryptCredential(record));
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
