# Operations

## Main paths

- Active auth:
  - `~/.claude.json`
- Claude settings:
  - `~/.claude/settings.json`
- ccs state:
  - `~/.claude-switch-backup/sequence.json`
- active usage cache:
  - `/tmp/claude-usage-cache.json`

## Common checks

```bash
ccs ls
ccs status
ccs rate-check --refresh
```

## Enable auto-switch

```bash
ccs rate-setup --threshold 95
ccs statusline-setup
```

## Disable auto-switch

```bash
ccs rate-setup --disable
ccs statusline-setup --disable
```

## Warm active account

```bash
ccs warm-check
ccs warm-loop
```

## Multi-server client setup

For another server that should join same coordinator:

```bash
ccs --allow-root coord-client-setup \
  --api-url https://ccs.dev.gass.web.id \
  --api-token 'YOUR_SHARED_TOKEN' \
  --server-id "$(hostname)" \
  --threshold 95
```

Then verify:

```bash
ccs status
ccs coord-sync
```

Useful helper commands on the coordinator server:

```bash
ccs coord-token
ccs coord-client-command
```

Notes:

- `warm-check` only trusts the active account
- `warm-loop` is a scheduler, not a spammer
- ping is only sent once after reset when needed

## Manual switch

```bash
ccs to 1
ccs to user@example.com
ccs sw
```

## Adaptive lease policy in this fork

- selection uses:
  - policy priority
  - known usage first
  - effective usage lowest first
- effective usage:
  - active limit first
  - else `max(5h, 7d)`
- if `resetAt5h` already passed on a non-active snapshot, stale 5h usage is treated as `0`
- normal mode prefers accounts not leased by other servers
- scarce fallback allows shared use only when no exclusive candidate is left

## Rollback

If you keep this fork in git:

```bash
git log --oneline -n 10
git checkout <commit>
```

If you need to disable only automation but keep `ccs` installed:

```bash
ccs rate-setup --disable
ccs statusline-setup --disable
```

## Current operating assumptions

- usage is reliable for the active account
- usage for non-active backup accounts may fail
- `resetAt` from provider is more trustworthy than local timer guesses
