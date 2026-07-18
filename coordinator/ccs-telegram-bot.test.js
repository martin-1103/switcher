'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseCcsAddResult } = require('./ccs-telegram-bot');

const email = 'user@example.com';
const local = `Updated Account 3: ${email}`;

test('accepts only local add plus coordinator accepted', () => {
  assert.deepEqual(parseCcsAddResult(
    `${local}\nCoordinator publish accepted for ${email} (reason=manual_login)`, email
  ), { localAdded: true, coordinator: 'accepted' });
});

test('distinguishes coordinator rejection and failure without exposing output', () => {
  assert.deepEqual(parseCcsAddResult(
    `${local}\nCoordinator publish rejected for ${email} (reason=existing credential is fresher or equal)\naccessToken=SECRET`, email
  ), { localAdded: true, coordinator: 'rejected' });
  assert.deepEqual(parseCcsAddResult(
    `${local}\nCoordinator publish failed for ${email} (reason=network_or_http_error)`, email
  ), { localAdded: true, coordinator: 'unreachable' });
  assert.deepEqual(parseCcsAddResult(
    `${local}\nCoordinator publish skipped for ${email} (reason=not_configured_or_unusable)`, email
  ), { localAdded: true, coordinator: 'unreachable' });
});

test('does not accept local success without coordinator acceptance', () => {
  assert.deepEqual(parseCcsAddResult(local, email), { localAdded: true, coordinator: 'unknown' });
  assert.deepEqual(parseCcsAddResult(
    `Coordinator publish accepted for ${email}`, email
  ), { localAdded: false, coordinator: 'unknown' });
});
