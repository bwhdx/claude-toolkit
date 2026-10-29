# claude-toolkit

Modular CLI tools for power users (and agents) of [Claude Code](https://claude.com/claude-code). Manage multiple Claude accounts, discover running instances, and watch them in a TUI dashboard. Every tool exposes a stable JSON API so agents and scripts can drive them programmatically.

| Tool | Language | Purpose |
|---|---|---|
| [`cc-auth`](#cc-auth) | Bash | Multi-account OAuth/long-term token manager with pool-based isolation (interactive vs background) and automatic cycling on rate limits |
| [`cc-monitor`](#cc-monitor) | Go | Discover all running Claude Code instances on the machine (ax workers, headless, interactive, IDE) |
| [`cc-dashboard`](#cc-dashboard) | Go (Bubble Tea) | TUI showing live instance state, accounts, and rate-limit usage |
| [`cc-jobs`](#cc-jobs) | Bash | Inspect launchd agents & crontab entries owned by the toolkit |

## Install

### Prerequisites

- macOS (cc-jobs / cc-auth scheduling use `launchd`; cc-auth uses macOS Keychain)
- `bash` 4+, `jq`, `git`
- Go 1.22+ (only to build `cc-monitor` and `cc-dashboard`)
- Optional: `bats` (bash tests), `shellcheck` (lint)

### One-shot install

```bash
git clone https://github.com/bwhdx/claude-toolkit.git ~/Code/Personal/claude-toolkit
cd ~/Code/Personal/claude-toolkit
./install.sh                  # installs to ~/.local/bin by default
# or:  ./install.sh ~/bin
```

Make sure the install dir is on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The installer also writes `~/.claude-toolkit/env` so other tools can discover the toolkit location:

```bash
source ~/.claude-toolkit/env
echo "$CLAUDE_TOOLKIT_DIR"     # /Users/you/Code/Personal/claude-toolkit
```

### Make targets

```bash
make build       # build cc-monitor + cc-dashboard
make install     # build + copy/symlink to ~/.local/bin (override with INSTALL_DIR=...)
make test        # go test ./... + bats
make lint        # go vet + shellcheck
make uninstall   # remove installed binaries
make help        # list all targets
```

## Quick start

```bash
cc-auth init                          # create vault + encryption key
cc-auth add personal                  # browser OAuth, stored in macOS Keychain
cc-auth add work --email me@work.com
cc-auth list                          # see accounts and status
cc-auth activate work                 # switch active account
cc-monitor                            # show running Claude Code instances
cc-dashboard                          # live TUI
```

---

## cc-auth

Multi-account token manager. Stores OAuth credentials (and optional 1-year long-term tokens from `claude setup-token`) in an encrypted vault + macOS Keychain, and supports **pools** so an interactive session and background workers can hold different active accounts at the same time.

### Common commands

```bash
cc-auth init
cc-auth add <name> [--email <email>]
cc-auth list [--json]
cc-auth status [--json]
cc-auth activate <name> [--pool=<pool>]    # default pool: interactive
cc-auth cycle [--pool=<pool>]              # rotate to next available account
cc-auth verify [<name>|--all]
cc-auth refresh-all                        # refresh tokens expiring soon
cc-auth restore                            # restore pre-cc-auth credentials
```

### Several accounts and their usage

`onboard` adds every account in a list, each with its 1-year token, and can be re-run: accounts
and tokens already stored are skipped. Each account needs two browser sign-ins (one to add it, one
for `claude setup-token`); a token is only stored once it is shown to belong to that account's
organization.

```bash
cat > ~/accounts.txt <<'LIST'
# <name> <email>
ops1 operations@kash.bot
ops2 ops2@kash.bot
LIST
cc-auth onboard ~/accounts.txt
cc-auth setup-longterm ops1     # replace one token (pasted at a hidden prompt, or piped in)
```

`usage` shows each account's live weekly and 5-hour usage as bars, with when each resets, listing
the soonest weekly reset first. It makes a
one-token request per account (in parallel) and reads the rate-limit headers of the response, so it
works with long-term tokens and costs a negligible share of each account's usage. The figures are
also recorded for cycling and `status`.

```bash
cc-auth usage                   # table; exit 1 if any account could not be read
cc-auth usage ops1 --json
```

### One account for every session, switching when it runs out

With `cc-auth token` as Claude Code's `apiKeyHelper`, every session uses one shared account and
follows it when it changes, without a restart:

```json
{
  "apiKeyHelper": "$HOME/.local/bin/cc-auth token",
  "env": { "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "60000" }
}
```

Claude Code asks the helper for a token every minute. The helper checks the shared account's usage
at most every 2 minutes (`CC_AUTH_SESSION_CHECK_SECS`, one check for all sessions). Once the
account is limited or past 95% of either window (`CC_AUTH_SWITCH_AT`), every session moves to the
account with room whose weekly window resets soonest. Switches are logged as `session_switched`
in `~/.cc-auth/events.jsonl`.

```bash
cc-auth use                       # which account sessions use
cc-auth use product               # choose one; kept until it runs out of room
cc-auth use --auto                # pick the best account now
```

### Working as an account

```bash
cc-auth run technology            # Claude Code as technology@, in this terminal only
cc-auth run product -c            # extra arguments go to claude
cc-auth run --login               # the /login sign-in, with connectors and Claude in Chrome
```

`run <name>` keeps one terminal on an account whatever the shared account is: no browser sign-in,
nothing written to the keychain. Token sessions have no claude.ai connectors (Gmail, Drive, ...)
and no Claude in Chrome; `cc-auth run --login` starts a session on the normal `/login` sign-in
for those.

### Pools

Pools let you keep separate active accounts for different workloads — e.g. `interactive` for your terminal, `background` for queued workers — so an agent rotating accounts doesn't yank the credentials out from under you.

```bash
cc-auth pool list
cc-auth pool create background --no-keychain   # bg pool doesn't touch keychain
cc-auth pool add background worker-1
cc-auth pool add background worker-2
cc-auth get-token --pool=background            # print active long-term token
cc-auth cycle --pool=background                # cycle within that pool only
```

### Rate limiting

```bash
cc-auth mark-limited <name> <secs>         # record a subscription limit hit
cc-auth has-available [--pool=<pool>]      # exit 0 if any account is usable
```

Exit codes (from `pkg/exitcodes/`): `0` ok · `1` general · `2` usage · `10` auth · `11` auth expired · `75` rate limited · `76` subscription limited · `77` all accounts limited · `80` lock conflict · `90` not initialized.

### Token refresh schedule

```bash
cc-auth schedule install     # install launchd agent that refreshes tokens
cc-auth schedule status
cc-auth schedule remove
```

---

## cc-monitor

Discovers all running Claude Code instances on the machine and prints a unified view. Pulls together:

- live processes (`ps`)
- session files in `~/.claude/sessions/`
- optional `ax` worker registry (`registry.json`)

```bash
cc-monitor                # human table
cc-monitor --json         # JSON for scripts/agents
```

Output kinds: `ax-worker`, `ax-gate`, `ax-supervisor`, `ax-final-review`, `interactive`, `headless`, `ide`.

Go consumers can use the engine directly:

```go
import "github.com/bwhdx/claude-toolkit/cc-monitor/pkg/discovery"

instances, err := discovery.Discover(discovery.Config{
    AXRegistryPath: "/path/to/registry.json",  // optional
    IncludeDead:    false,
})
```

---

## cc-dashboard

Live TUI built on Bubble Tea. Shows running instances, account utilization, and rate-limit state in one screen.

```bash
cc-dashboard
```

Press `?` inside for keybindings.

---

## cc-jobs

Lists launchd agents and cron entries that match toolkit naming conventions (`com.ax.*`, `com.claude-toolkit.*`).

```bash
cc-jobs list [--json]
```

Use it to audit what's scheduled on the machine before changing things.

---

## For agents

This section is meant to be read by Claude Code / other agents driving the toolkit.

- **Every CLI supports `--json`.** Prefer it over scraping human output.
- **Exit codes are stable** — see `pkg/exitcodes/` and the cc-auth section above. They are the right thing to branch on.
- **JSON shapes** for `cc-auth list/status` and `cc-monitor` are documented in [`CLAUDE.md`](./CLAUDE.md).
- **Pools** are the right tool when an agent must rotate accounts without disturbing a human interactive session. Default the agent to a non-`interactive` pool (e.g. `background`).
- **Discover the toolkit at runtime** by sourcing `~/.claude-toolkit/env` and reading `$CLAUDE_TOOLKIT_DIR`.
- **Bash consumers** can `source "$CLAUDE_TOOLKIT_DIR/lib/common.bash"` and the cc-auth libs (`vault.bash`, `cycling.bash`, `pools.bash`) for direct function access — see [`CLAUDE.md`](./CLAUDE.md) for the function-level API.
- **Cycling pattern** for a worker that hit a limit:
  ```bash
  cc-auth mark-limited "$account" "$seconds"
  cc-auth has-available --pool=background || exit 77
  cc-auth cycle --pool=background
  ```

---

## Layout

```
claude-toolkit/
├── pkg/                    # Shared Go packages (config, exitcodes)
├── lib/                    # Shared bash libraries (common, process, claude, events, scheduler)
├── cc-auth/                # Multi-account token manager (bash)
├── cc-monitor/             # Instance discovery (Go)
├── cc-dashboard/           # TUI (Go + bubbletea)
├── cc-jobs/                # launchd/cron inspector (bash)
├── go.work                 # Go workspace
├── Makefile
└── install.sh
```

See [`CLAUDE.md`](./CLAUDE.md) for architecture, conventions, and the full JSON / Go / bash API contracts.

## License

MIT — see [`LICENSE`](./LICENSE).
