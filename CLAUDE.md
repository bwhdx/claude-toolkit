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
- `~/.cc-auth/usage-cache.json` — short-TTL cache of rate limit probes
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

### `cc-auth usage --json`

Rate limit headroom per account, probed via each account's long-term token. Read-only:
no keychain swap, no token rotation, no writes to cycling state.

```json
[
  {
    "account": "leadership",
    "email": "leadership@kash.bot",
    "subscription": "max",
    "rate_limit_tier": "default_claude_max_20x",
    "active": true,
    "recorded_active": false,
    "ok": true,
    "session": {
      "percent_used": 80,
      "percent_left": 20,
      "resets_at_epoch": 1788375000,
      "resets_at": "2026-09-02T18:50:00Z",
      "resets_in_seconds": 4035,
      "status": "allowed|rejected",
      "severity": "ok|warning|critical"
    },
    "weekly": { "...": "same shape as session" },
    "status": "allowed|rejected",
    "binding": "session|weekly",
    "representative_claim": "five_hour|seven_day",
    "fallback": "available",
    "fallback_percentage": 50,
    "overage_status": "rejected",
    "overage_disabled_reason": "org_level_disabled",
    "retry_after_seconds": 2319,
    "organization_id": "53745887-676c-4947-a3b3-48663e813ce0",
    "workspace_id": "wrkspc_01UqEaDazwA9MmTx9dmb6uVz",
    "cached": true
  }
]
```

When usage cannot be read, `ok` is `false` and `error` carries the reason
(`no_longterm_token`, `unauthorized`, `forbidden_scope`, `rate_limited`,
`server_error`, `no_response`, `no_rate_limit_headers`, `vault_read_failed`)
instead of `session`/`weekly`. One account failing never fails the others.

Notes:
- `active` is ground truth — the account the **keychain** is actually logged into,
  resolved via `claude auth status`. `recorded_active` is what cc-auth's
  `state.json` believes. They differ whenever someone runs `claude login`
  outside cc-auth, since only cc-auth's own activations write that state.
- `binding` names the window that is the live constraint, normalized from
  `representative_claim`. Each window also carries `surpassed_threshold` when it
  is the one that blew.
- `retry_after_seconds` and `fallback_percentage` are numbers when present and
  `null` otherwise; the string fields are `""` when the response omits them.
- `fallback_percentage` is a fixed policy constant (0.5, reported here on a
  0-100 scale) — identical across accounts and utilization levels, and its exact
  meaning is undocumented. It is exposed in JSON but deliberately not shown in
  the table, where it would read as a per-account measurement.
- Window `status` is the API's own verdict — `allowed`, `allowed_warning`
  (close to the limit), or `rejected` — and is independent of `severity`, which
  is derived locally from `percent_left`.
- `session` is the 5h window, `weekly` the 7d window — the two Anthropic reports
  through `anthropic-ratelimit-unified-*` response headers.
- An exhausted account answers HTTP 429 but still reports its utilization and
  reset, so that is parsed as data (`status: "rejected"`), not as an error.
- Per-model weekly breakdowns are NOT available here. They come from
  `/api/oauth/usage`, which requires the `user:profile` scope that
  `claude setup-token` long-term tokens do not carry.
- Each probe is a real (minimal) billed request against that account's own quota,
  so results are cached for `CC_USAGE_CACHE_TTL` seconds (default 60).
  `--refresh` bypasses the cache; `CC_USAGE_CACHE_TTL=0` disables it.

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
