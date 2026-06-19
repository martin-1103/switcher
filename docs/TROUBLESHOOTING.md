# Troubleshooting

## 1. `rate-check --refresh` fails

Example:

```text
Error: Failed to fetch usage data and no cache available
```

Check:

```bash
ccs status
ccs ls
```

Then inspect:

```bash
jq . ~/.claude-switch-backup/sequence.json
jq . ~/.claude.json
```

Common causes:

- active account auth is stale
- usage endpoint returns `429`
- refresh token endpoint also returns `429`

## 2. Statusline is blank after switch

Usually transient.

Check manually:

```bash
CCS_PATH=/usr/local/bin/ccs /usr/local/bin/statusline/ccs-statusline.sh
```

Healthy output:

```text
ccs user@example.com · use 19% · 5h 6% · 7d 19%
```

If manual output works, blank UI was likely a temporary post-switch render before cache refill.

## 3. Hook seems not to switch

Check config:

```bash
jq '{statusLine, hooks: .hooks.PreToolUse}' ~/.claude/settings.json
```

Manual hook probe:

```bash
printf '{"tool_name":"Bash","input":{}}' | CCS_PATH=/usr/local/bin/ccs /usr/local/bin/hooks/ccs-rate-hook.sh
```

If the hook returns deny JSON, the hook is active.

## 4. Non-active account usage fails

This fork has seen host behavior where:

- active account usage works
- backup credential usage fetch for non-active accounts returns `429`

Treat non-active usage as unreliable.

Preferred workflow:

1. switch account
2. observe active usage
3. store snapshot

## 5. All accounts are above threshold

Expected output:

```text
All accounts are above the threshold
```

In hook mode, this becomes a deny response instead of switching.

## 6. Account switch says success but status still shows old account

If this happens during parallel checks, re-run serially:

```bash
ccs ls
ccs status
```

Verify both:

```bash
jq -r '.oauthAccount.emailAddress' ~/.claude.json
jq -r '.accounts[(.activeAccountNumber|tostring)].email' ~/.claude-switch-backup/sequence.json
```

They should match.

## 7. Root shell usage

If your server runs Claude Code as root:

```bash
export CCSWITCH_ALLOW_ROOT=1
export CCS_PATH=/usr/local/bin/ccs
```

Without that, manual commands may be blocked.
