# Plan: Credential Update SSE Pub/Sub

## Goal

Propagate Claude credential rotations between hosts without calling the blocked
OAuth refresh endpoint. A publish writes encrypted credential state and emits a
metadata-only event. Clients fetch the credential over the authenticated
coordinator API.

## Scope

- Add coordinator SSE endpoint with replayable in-memory/state-backed event
  outbox.
- Emit `credential.updated` events containing only event id, email, and
  `credentialUpdatedAt`.
- Add `ccs coord-listen` reconnecting client with durable event cursor and
  fetch-on-event reconciliation.
- Install listener as a systemd service; keep existing rate-check polling as
  fallback.
- Do not call or restore OAuth refresh-token API.

## Acceptance

- Publish returns accepted and emits one metadata-only event.
- A client reconnecting with its last event id receives missed events.
- Event consumer fetches and stores only a strictly newer credential.
- SSE disconnect reconnects without exiting the listener.
- Shell and Node syntax checks pass; existing tests remain runnable.

## Rollback

Stop/disable the listener service. Existing HTTP publish/fetch and rate-check
polling remain usable; remove SSE endpoint/client in a later cleanup if needed.
