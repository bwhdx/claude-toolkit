# claude-toolkit

Monorepo of modular tools for Claude Code power users. Each tool is independently usable but they share a common foundation.

## Architecture

```
claude-toolkit/
├── pkg/                    # Shared Go packages (config, exitcodes)
├── lib/                    # Shared bash libraries (common, process)
├── cc-auth/                # Multi-account token manager (bash)
├── cc-monitor/             # Instance discovery CLI (Go)
├── cc-dashboard/           # TUI dashboard (Go + bubbletea)
├── go.work                 # Go workspace for multi-module dev
└── Makefile                # build, test, install, lint
```

### Layered design

- **Layer 1** — Libraries: bash `lib/*.bash` and Go `pkg/*` — for direct import/sourcing
- **Layer 2** — CLIs: `cc-auth`, `cc-monitor` — JSON stdout is the universal API
- **Layer 3** — TUI: `cc-dashboard` — consumer of Layer 1/2

### Language conventions

- **Foundational/shell-interop tools**: Bash + jq (cc-auth). These can be sourced by other bash tools like `ax`.
- **Systems/data tools**: Go (cc-monitor, cc-dashboard). Type-safe, compiled, single binary.
- All tools output JSON with `--json` flag for programmatic consumption.
- All tools use standardized exit codes from `pkg/exitcodes/`.

## Development

```bash
make build          # Build all Go binaries
make test           # Run all tests
make install        # Install to ~/.local/bin
make lint           # Run go vet + shellcheck
make help           # Show all targets
```

### Adding a new tool

1. Create `<tool-name>/` directory with `cmd/<tool-name>/main.go` or entry script
2. For Go: add `go.mod`, add to `go.work`, import `pkg/*` for shared config/exitcodes
3. For Bash: source `../../lib/common.bash` and `../../lib/process.bash`
4. Add build/install targets to `Makefile`
5. All CLIs must support `--json` output and `--help`

### Key paths

- `~/.cc-auth/` — cc-auth vault (encrypted credentials, state)
- `~/.claude/sessions/` — Claude Code session files (read by cc-monitor)
- `~/.claude-toolkit/` — Shared config directory (future use, from `pkg/config`)

### Testing

- Go: `go test ./...` in each module
- Bash: bats tests in `cc-auth/test/`
- Integration: `make test`

### Exit codes

All tools use codes from `pkg/exitcodes/`:
- `0` success, `1` general error, `2` usage error
- `10` auth error, `11` auth expired
- `75` rate limited, `76` subscription limited, `77` all accounts limited
- `80` lock conflict, `90` not initialized

## JSON API Contracts

These are the stable output shapes consumers can depend on. All tools support `--json`.

### `cc-auth list --json`

```json
[
  {
    "name": "leadership",
    "email": "leadership@kash.bot",
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_20x",
    "added_at": "2026-04-01T22:16:26Z",
    "last_verified": "2026-04-01T22:16:26Z",
    "status": "active|available|limited",
    "limited": false,
    "limit_remaining": 0
  }
]
```

### `cc-auth status --json`

```json
{
  "active_account": "leadership",
  "total": 4,
  "available": 3,
  "limited": 1
}
```

### `cc-monitor --json`

```json
[
  {
    "pid": 8861,
    "alive": true,
    "kind": "ax-worker|ax-gate|ax-supervisor|ax-final-review|interactive|headless|ide",
    "cwd": "/Users/user/project",
    "session_id": "uuid",
    "started_at": "2026-04-01T15:55:00Z",
    "duration_seconds": 3600,
    "account": "leadership",
    "model": "sonnet",
    "status": "active|working|dead",
    "ax": {
      "initiative": "my-initiative",
      "phase": "2",
      "session": "2A",
      "role": "worker",
      "budget_usd": 50.0,
      "debug_file": "/path/to/debug.out"
    }
  }
]
```

The `ax` field is only present for ax-managed instances. The `kind` field determines which fields are populated.

### Go package API

For Go consumers, import the discovery engine directly:

```go
import "github.com/bwhdx/claude-toolkit/cc-monitor/pkg/discovery"

instances, err := discovery.Discover(discovery.Config{
    AXRegistryPath: "/path/to/registry.json",  // optional
    IncludeDead:    false,
})
// instances is []discovery.Instance — same shape as the JSON above
```

### Bash library API

For bash consumers, source the libraries:

```bash
source /path/to/claude-toolkit/lib/common.bash
source /path/to/claude-toolkit/cc-auth/lib/vault.bash
source /path/to/claude-toolkit/cc-auth/lib/cycling.bash

# Direct function access
cycle_account          # returns 0 on success
has_available_account  # returns 0 if any account is available
state_active_account   # prints active account name
```
