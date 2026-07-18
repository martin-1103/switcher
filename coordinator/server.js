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
const EVENT_LIMIT = Number(process.env.CCS_COORD_EVENT_LIMIT || 1000);
const SNAPSHOT_MAX_AGE_MS = Number(process.env.CCS_COORD_SNAPSHOT_MAX_AGE_MS || 15 * 60 * 1000);
const sseClients = new Set();

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

function isEncryptedCredential(record) {
  return Boolean(record && record.iv && record.tag && record.ciphertext);
}

function normalizeCredentialStore(state) {
  for (const [email, value] of Object.entries(state.credentials || {})) {
    if (isEncryptedCredential(value)) {
      state.credentials[email] = { sources: { legacy: value } };
    } else if (!value || typeof value !== 'object' || !value.sources || typeof value.sources !== 'object') {
      state.credentials[email] = { sources: {} };
    }
  }
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
    if (!state.credentialSnapshots || typeof state.credentialSnapshots !== 'object') {
      state.credentialSnapshots = {};
    }
    if (!state.credentials || typeof state.credentials !== 'object') {
      state.credentials = {};
    }
    if (!state.credentialHealth || typeof state.credentialHealth !== 'object') {
      state.credentialHealth = {};
    }
    normalizeCredentialStore(state);
    if (!Array.isArray(state.events)) {
      state.events = [];
    }
    if (!Number.isFinite(Number(state.eventSeq))) {
      state.eventSeq = state.events.reduce((max, event) => Math.max(max, Number(event.id || 0)), 0);
    }
    return state;
  } catch {
    return { leases: {}, usageSnapshots: {}, credentialSnapshots: {}, credentials: {}, credentialHealth: {}, events: [], eventSeq: 0 };
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

function logEvent(message) {
  console.log(`[coord] ${new Date().toISOString()} ${message}`);
}

function writeSse(res, event) {
  res.write(`id: ${event.id}\n`);
  res.write(`event: ${event.type}\n`);
  res.write(`data: ${JSON.stringify(event)}\n\n`);
}

function emitEvent(state, type, payload) {
  const event = {
    id: String(Number(state.eventSeq || 0) + 1),
    type,
    ...payload,
    emittedAt: Date.now(),
  };
  state.eventSeq = Number(event.id);
  state.events = [...(state.events || []), event].slice(-Math.max(1, EVENT_LIMIT));
  logEvent(`event_emit id=${event.id} type=${type} email=${event.email || '-'} version=${event.credentialUpdatedAt || 0} clients=${sseClients.size}`);
  for (const client of sseClients) {
    try {
      writeSse(client, event);
    } catch {
      sseClients.delete(client);
    }
  }
  return event;
}

function eventAlreadyEmitted(state, type, email, sourceServer, credentialUpdatedAt) {
  return (state.events || []).some(event =>
    event.type === type && event.email === email && event.sourceServer === sourceServer &&
    Number(event.credentialUpdatedAt || 0) === Number(credentialUpdatedAt || 0));
}

function healthEventAlreadyEmitted(state, email, sourceServer, status, fingerprint, observedAt, type = 'credential.health.updated') {
  return (state.events || []).some(event =>
    event.type === type && event.email === email &&
    event.sourceServer === sourceServer && event.status === status &&
    event.fingerprint === fingerprint && Number(event.observedAt || 0) === Number(observedAt || 0));
}

function credentialSources(state, email) {
  const entry = state.credentials[email];
  if (!entry) return {};
  if (isEncryptedCredential(entry)) return { legacy: entry };
  return entry.sources || {};
}

function credentialHealth(state, email, sourceServer) {
  return state.credentialHealth[email]?.[sourceServer] || { status: 'unknown' };
}

function snapshotFor(state, email, sourceServer, fingerprint, now = Date.now()) {
  const snapshot = state.credentialSnapshots[email]?.[sourceServer]?.[fingerprint];
  if (!snapshot) return null;
  const age = now - Number(snapshot.observedAt || 0);
  if (Number(snapshot.observedAt || 0) <= 0 || age < 0 || age > SNAPSHOT_MAX_AGE_MS) return null;
  return snapshot;
}

function snapshotFingerprint(accessToken) {
  return crypto.createHash('sha256').update(accessToken).digest('hex');
}

function credentialVersion(record) {
  try {
    return Number(decryptCredential(record).credentialUpdatedAt || 0);
  } catch {
    return 0;
  }
}

function credentialHealthView(state, email) {
  return Object.entries(credentialSources(state, email)).map(([sourceServer, record]) => {
    const health = credentialHealth(state, email, sourceServer);
    return {
      sourceServer,
      status: health.status || 'unknown',
      reason: health.reason || null,
      fingerprint: health.fingerprint || null,
      observedAt: Number(health.observedAt || 0),
      credentialUpdatedAt: credentialVersion(record),
      snapshot: snapshotFor(state, email, sourceServer, health.fingerprint || ''),
    };
  });
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

    if (req.method === 'GET' && url.pathname === '/v1/events') {
      const after = Number(url.searchParams.get('after') || 0);
      const replay = (state.events || []).filter(event => Number(event.id) > after);
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no',
      });
      res.write(': connected\n\n');
      for (const event of replay) writeSse(res, event);
      logEvent(`sse_connect after=${after} replay=${replay.length} clients=${sseClients.size + 1}`);
      const heartbeat = setInterval(() => {
        if (!res.destroyed) res.write(': heartbeat\n\n');
      }, 25000);
      sseClients.add(res);
      req.on('close', () => {
        clearInterval(heartbeat);
        sseClients.delete(res);
        logEvent(`sse_close clients=${sseClients.size}`);
      });
      return;
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
      const refreshTokenExpiresAt = Number(body.refreshTokenExpiresAt || 0);
      const credentialUpdatedAt = Number(body.credentialUpdatedAt || 0);
      const sourceServer = String(body.sourceServer || body.serverId || 'legacy').trim() || 'legacy';
      const scopes = Array.isArray(body.scopes) ? body.scopes : [];
      const manualLogin = body.publishReason === 'manual_login';
      const forceReplace = body.forceReplace === true;
      if (!email || !accessToken || !refreshToken) {
        return send(res, 400, { error: 'email, accessToken, refreshToken required' });
      }
      // Reload fresh AFTER the await, mutate+save synchronously — same
      // atomic-claim pattern as /v1/leases/claim, closes the same race.
      const fresh = loadState();
      const sources = credentialSources(fresh, email);
      const existing = sources[sourceServer];
      // Freshness is the client-observed refresh event, not OAuth expiry.
      // OAuth tokens can be revoked before expiresAt, and expiry is not a
      // reliable ordering signal for rotated refresh tokens.
      if (existing && !manualLogin) {
        const existingPlain = decryptCredential(existing);
        if (Number(existingPlain.credentialUpdatedAt || 0) >= credentialUpdatedAt) {
          return send(res, 200, { ok: true, accepted: false, sourceServer, reason: 'existing credential is fresher or equal' });
        }
      }
      if (!fresh.credentials[email] || isEncryptedCredential(fresh.credentials[email])) {
        fresh.credentials[email] = { sources: sources };
      }
      const fingerprint = snapshotFingerprint(accessToken);
      let previousFingerprint = String(fresh.credentialHealth[email]?.[sourceServer]?.fingerprint || '');
      if (existing) {
        try {
          previousFingerprint = snapshotFingerprint(decryptCredential(existing).accessToken);
        } catch {
          previousFingerprint = '';
        }
      }
      fresh.credentials[email].sources[sourceServer] = encryptCredential({ accessToken, refreshToken, expiresAt, refreshTokenExpiresAt, scopes, credentialUpdatedAt, updatedAt: now });
      if (existing && previousFingerprint !== fingerprint) {
        delete fresh.credentialSnapshots[email]?.[sourceServer];
      }
      fresh.credentialHealth[email] = fresh.credentialHealth[email] || {};
      const healthStatus = body.healthStatus === 'healthy' ? 'healthy' : 'unknown';
      fresh.credentialHealth[email][sourceServer] = {
        ...(fresh.credentialHealth[email][sourceServer] || {}),
        status: healthStatus,
        reason: healthStatus === 'healthy' ? 'publish_health_proof' : null,
        fingerprint,
        observedAt: now,
        updatedAt: now,
      };
      const eventType = existing || manualLogin || forceReplace ? 'credential.updated' : 'credential.add';
      if (manualLogin || forceReplace || !eventAlreadyEmitted(fresh, eventType, email, sourceServer, credentialUpdatedAt)) {
        emitEvent(fresh, eventType, { email, sourceServer, credentialUpdatedAt });
      }
      saveState(fresh);
      return send(res, 200, { ok: true, accepted: true, sourceServer, event: eventType });
    }

    if (req.method === 'GET' && url.pathname === '/v1/credentials/health') {
      const email = String(url.searchParams.get('email') || '').trim();
      if (!email) return send(res, 400, { error: 'email required' });
      return send(res, 200, { email, sources: credentialHealthView(state, email) });
    }

    if (req.method === 'POST' && url.pathname === '/v1/credentials/health') {
      const body = await readJson(req);
      const email = String(body.email || '').trim();
      const sourceServer = String(body.sourceServer || body.serverId || 'legacy').trim() || 'legacy';
      let status = String(body.status || '').trim();
      if (status === 'transient') {
        status = 'unknown';
      }
      if (!email || !['healthy', 'invalid', 'throttled', 'unknown'].includes(status)) {
        return send(res, 400, { error: 'email and valid status required' });
      }
      const fresh = loadState();
      fresh.credentialHealth[email] = fresh.credentialHealth[email] || {};
      fresh.credentialHealth[email][sourceServer] = {
        status,
        reason: String(body.reason || '').slice(0, 200) || null,
        fingerprint: String(body.fingerprint || '').slice(0, 128) || null,
        observedAt: Number(body.observedAt || Date.now()),
        updatedAt: Date.now(),
      };
      const health = fresh.credentialHealth[email][sourceServer];
      if (!healthEventAlreadyEmitted(fresh, email, sourceServer, status, health.fingerprint, health.observedAt)) {
        emitEvent(fresh, 'credential.health.updated', {
          email,
          sourceServer,
          status,
          reason: health.reason,
          fingerprint: health.fingerprint,
          observedAt: health.observedAt,
        });
      }
      saveState(fresh);
      return send(res, 200, { ok: true, email, sourceServer, status });
    }

    if (req.method === 'POST' && url.pathname === '/v1/credentials/snapshot') {
      const body = await readJson(req);
      const email = String(body.email || '').trim();
      const sourceServer = String(body.sourceServer || body.serverId || 'legacy').trim() || 'legacy';
      const fingerprint = String(body.fingerprint || '').trim().slice(0, 128);
      let status = String(body.status || 'unknown').trim();
      if (status === 'transient') status = 'unknown';
      if (!email || !fingerprint || !['healthy', 'invalid', 'throttled', 'unknown'].includes(status)) {
        return send(res, 400, { error: 'email, fingerprint and valid status required' });
      }
      const usage = body.usage && typeof body.usage === 'object' ? {
        activeLimit: Number(body.usage.activeLimit || 0),
        fiveHour: Number(body.usage.fiveHour || 0),
        sevenDay: Number(body.usage.sevenDay || 0),
        resetAt5h: body.usage.resetAt5h || null,
        resetAt7d: body.usage.resetAt7d || null,
      } : null;
      let observedAt = Number(body.observedAt || Date.now());
      if (observedAt > 0 && observedAt < 1e12) observedAt *= 1000;
      const fresh = loadState();
      const currentHealth = credentialHealth(fresh, email, sourceServer);
      const currentFingerprint = String(currentHealth.fingerprint || '');
      if (currentFingerprint && currentFingerprint !== fingerprint) {
        return send(res, 409, { error: 'credential fingerprint mismatch' });
      }
      fresh.credentialSnapshots[email] = fresh.credentialSnapshots[email] || {};
      fresh.credentialSnapshots[email][sourceServer] = fresh.credentialSnapshots[email][sourceServer] || {};
      const snapshot = {
        status,
        reason: String(body.reason || '').slice(0, 200) || null,
        fingerprint,
        observedAt,
        usage,
        updatedAt: Date.now(),
      };
      fresh.credentialSnapshots[email][sourceServer][fingerprint] = snapshot;
      fresh.credentialHealth[email] = fresh.credentialHealth[email] || {};
      fresh.credentialHealth[email][sourceServer] = {
        ...currentHealth,
        status,
        reason: snapshot.reason,
        fingerprint,
        observedAt,
        updatedAt: Date.now(),
      };
      if (!healthEventAlreadyEmitted(fresh, email, sourceServer, status, fingerprint, observedAt, 'credential.snapshot.updated')) {
        emitEvent(fresh, 'credential.snapshot.updated', {
          email, sourceServer, status, reason: snapshot.reason, fingerprint, observedAt, usage,
        });
      }
      saveState(fresh);
      return send(res, 200, { ok: true, email, sourceServer, fingerprint, status, observedAt });
    }

    if (req.method === 'GET' && url.pathname === '/v1/credentials/fetch') {
      if (!CRED_KEY) {
        return send(res, 501, { error: 'credential store not configured (CCS_COORD_CRED_KEY unset)' });
      }
      const email = String(url.searchParams.get('email') || '').trim();
      const requestedSource = String(url.searchParams.get('sourceServer') || '').trim();
      if (!email) {
        return send(res, 400, { error: 'email required' });
      }
      const sources = credentialSources(state, email);
      const candidates = Object.entries(sources)
        .filter(([sourceServer]) => !requestedSource || sourceServer === requestedSource)
        .filter(([sourceServer]) => credentialHealth(state, email, sourceServer).status !== 'invalid')
        .sort(([a, recordA], [b, recordB]) => {
          const aHealthy = credentialHealth(state, email, a).status === 'healthy' ? 1 : 0;
          const bHealthy = credentialHealth(state, email, b).status === 'healthy' ? 1 : 0;
          return bHealthy - aHealthy || credentialVersion(recordB) - credentialVersion(recordA);
        });
      if (candidates.length === 0) {
        return send(res, 404, { error: 'not found' });
      }
      const [sourceServer, record] = candidates[0];
      const credential = decryptCredential(record);
      const health = credentialHealth(state, email, sourceServer);
      return send(res, 200, { ...credential, sourceServer, health, snapshot: snapshotFor(state, email, sourceServer, health.fingerprint || ''), updatedAt: Number(credential.updatedAt || 0) });
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
