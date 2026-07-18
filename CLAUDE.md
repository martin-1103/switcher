# cc-account-switcher — map for AI agents

Single-file bash CLI (`ccswitch.sh`, installed as `ccs`) managing multiple Claude Code
OAuth accounts: switch, auto-switch on rate limit, usage cache.

Kept as ONE file on purpose — packaged via Homebrew Formula, npm wrapper (`bin/ccswitch`),
and curl-install, all of which assume a single executable. Don't split it into lib/*.sh
without also updating `Formula/`, `bin/ccswitch`, and `Makefile install`.

## Where to look

| Concern | File | Notes |
|---|---|---|
| Everything core (switch, cred, cache, coord) | `ccswitch.sh` | grep `# ===== ` markers below to jump to a section |
| PreToolUse hook (per-tool-call rate check) | `hooks/ccs-rate-hook.sh` | fast-path reads cache only, never calls rate-check itself unless stale/over-threshold |
| Statusline render | `statusline/ccs-statusline.sh` | spawns `ccs rate-check --auto-switch` in background, throttled 10s, prints from cache |
| Multi-host coordination (leases, shared state) | `ccswitch.sh` `coord_*` functions | HTTP or MySQL backend, see `coord_mode()` |

Installed copies live at `/usr/local/bin/ccs`, `/usr/local/bin/hooks/...`,
`/usr/local/bin/statusline/...` — NOT symlinks, plain copies. Any edit to the repo file
must be `cp`'d there too or it's a no-op on this host.

## ccswitch.sh section map

Grep `^# ===== ` for exact boundaries; line numbers below are approximate and drift as
the file changes — use grep, don't trust these as gospel.

- **Platform/setup** (~47-180): container detection, config path resolution, deps check
- **Coordination** (~181-566): `coord_*` — multi-host lease/lock over HTTP or MySQL, so
  two hosts running ccs don't stomp the same account's credentials concurrently
- **Locking/cache helpers** (~566-870): switch lock (mkdir-based, atomic), usage cache
  freshness math, usage snapshot formatting
- **Usage fetch** (~870-1230): `fetch_usage_for_account`, `cmd_warm_check` — calls the
  Usage API (`GET /api/oauth/usage`), NOT the refresh endpoint. On 429 writes a
  synthetic "fully exhausted" cache instead of failing (see `write_limited_usage_cache`)
- **Account resolution/credentials** (~1230-1440): `get_current_account`,
  `usage_cache_file` (per-account cache path — always call this, never hardcode
  `/tmp/claude-usage-cache.json`), and `credential_*` helpers
- **Credential storage** (~1511-1970): read/write per-account credential files, coord
  publish/fetch, JWT decode
- **Process control** (~1965-2010): kill/restart Claude Code around a switch
- **cmd_* entrypoints** (~2009-3120): one function per subcommand (`check`, `status`,
  `stats`, `set-profile`, `add-account`, `remove-account`, `list`, `switch`,
  `switch-to`, `add-token`) — `perform_switch` (~2778) is the shared core all switch
  paths funnel through
- **Rate-check / auto-switch decision** (~3065-3396): `fetch_usage_data`,
  `cmd_rate_check` — the decision loop hooks/statusline delegate to; holds the switch
  lock for its whole run, not just the write
- **Setup wizards** (~3397-3660): `cmd_rate_setup`, `cmd_statusline_setup` — interactive
  first-time config
- **CLI dispatch** (~3660 to end): `show_usage`, `main` — argument parsing, subcommand
  routing

## Two API surfaces — don't confuse them

- **Usage API** (`GET /api/oauth/usage`) — read-only, how much quota is left. Called by
  statusline (every ~10s throttled), the hook (only when cache stale/over-threshold),
  every switch, and `cmd_warm_check`. High call volume by design; has its own 429 pool.

## Conventions this codebase enforces

- Usage cache is always per-account: `usage_cache_file(email)` →
  `/tmp/claude-usage-cache-<sanitized-email>.json`. A hardcoded shared path
  (`/tmp/claude-usage-cache.json`) is a bug, not a shortcut — it lets a stale fetch for
  account A get read back as account B's usage after a switch.
- Fail open in hooks/statusline (never block the user on our bugs); fail loud in
  switch (log to `credential-events.log` via `log_credential_event`).
- `set -uo pipefail` in hook/statusline scripts — an unset var referenced anywhere
  after removing a variable's assignment breaks the script silently under `trap 'exit
  0' ERR`. When removing/renaming a variable, grep every remaining reference first.
