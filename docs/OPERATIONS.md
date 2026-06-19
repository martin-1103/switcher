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

## Ladder policy in this fork

- priority:
  - `team`
  - then `max20`
- stages:
  - `20`
  - `40`
  - `60`
  - `80`
  - `95`
- next stage opens only after all team accounts reach current stage

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
