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

## Team Ladder Rotation

This fork supports staged team-first rotation.

Behavior:

1. `team` group is always preferred before `max20`
2. team ladder stages are:
   - `20`
   - `40`
   - `60`
   - `80`
   - `95`
3. the next stage only becomes active after all team accounts have reached the current stage
4. `max20` accounts are used only when team accounts have no lower-stage candidate left

Example with two team accounts:

- team A at `25%`
- team B at `10%`

Current target stage is still `20`, so team B is preferred first.

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
