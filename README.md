# Multi-Account Switcher for Claude Code

**[日本語版はこちら](README.ja.md)**

[![CI](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/fairy-pitta/cc-account-switcher?style=flat&color=blue)](https://github.com/fairy-pitta/cc-account-switcher/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-brightgreen)](https://github.com/fairy-pitta/cc-account-switcher)
[![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-89e051)](https://github.com/fairy-pitta/cc-account-switcher)

> Forked from [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher).

Manage multiple Claude Code accounts, switch quickly, and auto-rotate when usage gets high.

This fork also adds compatibility fixes for newer Claude Code credential formats and newer usage API behavior.

## What This Fork Adds

- Reads both legacy and current Claude Code credential layouts
- Reads usage from active limits first, then falls back to `max(5h, 7d)`
- Adds account types such as `team` and `max20`
- Prioritizes `team` accounts before `max20`
- Supports team ladder rotation: `20 -> 40 -> 60 -> 80 -> 95`
- Stores last known usage snapshots, including `resetAt5h` and `resetAt7d`
- Adds `warm-check` and `warm-loop` helpers for active-account usage refresh

## Quick Install

### Fast path

```bash
git clone https://github.com/fairy-pitta/cc-account-switcher.git
cd cc-account-switcher
sudo make install

sudo install -d /usr/local/bin/hooks /usr/local/bin/statusline
sudo install -m 755 hooks/ccs-rate-hook.sh /usr/local/bin/hooks/ccs-rate-hook.sh
sudo install -m 755 statusline/ccs-statusline.sh /usr/local/bin/statusline/ccs-statusline.sh
```

### Requirements

- Bash 3.2+
- `jq`
- `curl`
- Claude Code already installed
- Claude Code already logged into at least one account

### Root shells

By default `ccs` blocks `root`.

If your server runs Claude Code as `root`, use either:

```bash
ccs --allow-root ls
```

or:

```bash
export CCSWITCH_ALLOW_ROOT=1
export CCS_PATH=/usr/local/bin/ccs
```

## Source of Truth Files

Important on Linux servers:

- Active Claude auth/account:
  - `~/.claude.json`
- Claude Code hook and statusline config:
  - `~/.claude/settings.json`
- ccs state:
  - `~/.claude-switch-backup/sequence.json`
- Active usage cache:
  - `/tmp/claude-usage-cache.json`

## Initial Setup

### 1. Add accounts

```bash
ccs add
```

Repeat after logging into each account you want to manage.

### 2. Set account types

Example:

```bash
tmp=$(mktemp)
jq '.accounts["1"].accountType = "team"' ~/.claude-switch-backup/sequence.json > "$tmp" && mv "$tmp" ~/.claude-switch-backup/sequence.json
```

Common values in this fork:

- `team`
- `max20`

### 3. Enable auto-switch hook

```bash
ccs rate-setup --threshold 95
ccs statusline-setup
```

This writes:

- `hooks.PreToolUse` to `~/.claude/settings.json`
- `statusLine.command` to `~/.claude/settings.json`

### 4. Verify

```bash
ccs ls
ccs status
ccs rate-check --refresh
CCS_PATH=/usr/local/bin/ccs /usr/local/bin/statusline/ccs-statusline.sh
```

Expected signs:

- active account is shown correctly
- account type is shown
- statusline prints one line such as:
  - `ccs user@example.com · use 19% · 5h 6% · 7d 19%`

## Auto-switch Modes

### Directory mode

Map folders to accounts:

```bash
ccs dir ~/work 1
ccs auto
```

### Rate-limit mode

Switch when usage exceeds threshold:

```bash
ccs rate-check
ccs rate-check --auto-switch
```

The hook version runs automatically from Claude Code `PreToolUse`.

## Adaptive Multi-server Selection

This fork now uses adaptive lease-aware selection.

Behavior:

1. accounts are ranked by:
   - local policy priority
   - whether usage is known
   - effective usage ascending
2. effective usage means:
   - active limit first
   - else `max(5h, 7d)`
3. if a non-active snapshot has `resetAt5h` in the past, stale 5h usage is treated as `0`
4. normal mode prefers accounts that are **not** leased by other servers
5. if no exclusive candidate is left, fallback mode allows a shared candidate so both servers do not dead-end

This means:

- early in the pool, servers spread out
- late in the pool, servers may temporarily converge on the last usable account

## Active-first Usage Refresh

Important host behavior:

- usage for the currently active account is reliable
- usage reads from backup credentials of non-active accounts may fail or return `429`

Because of that, this fork now prefers:

- real-time usage for the active account
- historical snapshots for previously active accounts

Commands:

```bash
ccs warm-check
ccs warm-loop
```

Current meaning:

- `warm-check` refreshes the active account usage, updates snapshot, and sends a one-shot warm ping only when needed
- `warm-loop` runs `warm-check` every 60 seconds

This is a lightweight scheduler. It does **not** ping Claude every minute. It only checks state every minute.

## Multi-server Setup

If multiple servers share the same Claude accounts, use the HTTP coordinator.

### Coordinator server

This server already exposes:

- coordinator API:
  - `https://ccs.dev.gass.web.id`
- internal service:
  - `ccs-coordinator`
- internal port:
  - `19090`

The public endpoint is fronted by reverse proxy, so other servers should use the HTTPS domain, not the raw port.

### Other servers: 3 steps

1. install `ccs`
2. add all Claude accounts with `ccs add`
3. run one setup command:

```bash
ccs --allow-root coord-client-setup \
  --api-url https://ccs.dev.gass.web.id \
  --api-token 'YOUR_SHARED_TOKEN' \
  --server-id "$(hostname)" \
  --threshold 95
```

That one command will:

- configure HTTP coordination
- enable the rate hook
- enable the statusline
- keep the local threshold at `95`

Useful helper commands on the coordinator server:

```bash
ccs coord-token
ccs coord-client-command
```

- `coord-token` prints only the shared API token
- `coord-client-command` prints a full copy-paste command for another server

### Verify on another server

```bash
ccs status
ccs rate-check --refresh
ccs coord-sync
```

Healthy signs:

- `Coordination:    http (...)`
- hook and statusline already installed
- account lease appears on coordinator after `ccs coord-sync`

## Commands

### Account management

```bash
ccs add
ccs ls
ccs rm 2
ccs rm user@example.com
ccs profile 1 work
ccs to work
```

### Switching

```bash
ccs sw
ccs to 2
ccs to user@example.com
ccs sw --no-restart
```

### Auto-switch and warming

```bash
ccs rate-check
ccs rate-check --auto-switch
ccs rate-setup --threshold 95
ccs statusline-setup
ccs warm-check
ccs warm-loop
ccs coord-token
ccs coord-client-command
ccs coord-client-setup --api-url https://ccs.dev.gass.web.id --api-token 'YOUR_SHARED_TOKEN' --server-id "$(hostname)" --threshold 95
```

### Diagnostics

```bash
ccs check
ccs status
ccs stats
```

## Known Limits

- Auto-switch hook can rewrite auth automatically, but runtime hot-reload behavior depends on Claude Code build and host behavior
- Non-active account usage fetch may be unreliable on some hosts
- `0%` does not always mean reset time is known
- `resetAt` is authoritative when present; internal timers should not replace it

## Troubleshooting and Operations

- Troubleshooting:
  - [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Operations and recovery:
  - [docs/OPERATIONS.md](docs/OPERATIONS.md)

## Development

Run focused tests:

```bash
bats test/test_rate_check.bats
```

Run all tests:

```bash
bats test/*.bats
```
