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
