#!/usr/bin/env bats
# Tests for cc-auth usage parsing — turns curl response headers into usage JSON

setup() {
  export CC_AUTH_DIR="$(mktemp -d)"
  export CC_AUTH_VAULT_DIR="$CC_AUTH_DIR/vault"
  export CC_AUTH_VAULT_KEY="$CC_AUTH_DIR/vault.key"
  export CC_AUTH_ACCOUNTS_FILE="$CC_AUTH_DIR/accounts.json"
  export CC_AUTH_STATE_FILE="$CC_AUTH_DIR/state.json"

  TOOLKIT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  source "$TOOLKIT_ROOT/lib/common.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/vault.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/usage.bash"

  # Freeze "now" so reset countdowns are deterministic.
  # 1788380400 is the 5h reset in the fixture below.
  export CC_USAGE_NOW=1788376800  # exactly 1h before the 5h reset

  HDR="$CC_AUTH_DIR/headers.txt"
}

teardown() {
  rm -rf "$CC_AUTH_DIR"
}

# Writes a realistic curl header dump, CRLF line endings included.
write_headers() {
  local status="${1:-200}"
  {
    printf 'HTTP/2 %s \r\n' "$status"
    printf 'date: Tue, 02 Sep 2026 17:00:00 GMT\r\n'
    printf 'content-type: application/json\r\n'
    printf 'anthropic-ratelimit-unified-status: allowed\r\n'
    printf 'anthropic-ratelimit-unified-5h-status: allowed\r\n'
    printf 'anthropic-ratelimit-unified-5h-reset: 1788380400\r\n'
    printf 'anthropic-ratelimit-unified-5h-utilization: 0.84\r\n'
    printf 'anthropic-ratelimit-unified-7d-status: allowed\r\n'
    printf 'anthropic-ratelimit-unified-7d-reset: 1788415200\r\n'
    printf 'anthropic-ratelimit-unified-7d-utilization: 0.15\r\n'
    printf 'anthropic-ratelimit-unified-fallback: available\r\n'
    printf 'anthropic-ratelimit-unified-fallback-percentage: 0.5\r\n'
    printf 'anthropic-ratelimit-unified-overage-status: rejected\r\n'
    printf 'anthropic-ratelimit-unified-overage-disabled-reason: org_level_disabled\r\n'
    printf 'anthropic-ratelimit-unified-representative-claim: five_hour\r\n'
    printf 'anthropic-ratelimit-unified-5h-surpassed-threshold: 1.0\r\n'
    printf 'anthropic-organization-id: 53745887-676c-4947-a3b3-48663e813ce0\r\n'
    printf 'anthropic-workspace-id: ws-abc123\r\n'
    printf '\r\n'
  } > "$HDR"
}

@test "usage_parse_headers reports ok for a 200 response" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.ok')" = "true" ]
}

@test "usage_parse_headers converts utilization fractions to percent used" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.percent_used')" = "84" ]
  [ "$(echo "$output" | jq -r '.weekly.percent_used')" = "15" ]
}

@test "usage_parse_headers reports percent remaining" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "16" ]
  [ "$(echo "$output" | jq -r '.weekly.percent_left')" = "85" ]
}

@test "usage_parse_headers clamps percent_left at zero when over the limit" {
  write_headers 200
  sed -i.bak 's/5h-utilization: 0.84/5h-utilization: 1.01/' "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "0" ]
  [ "$(echo "$output" | jq -r '.session.percent_used')" = "100" ]
}

@test "usage_parse_headers computes seconds until reset from CC_USAGE_NOW" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.resets_in_seconds')" = "3600" ]
  [ "$(echo "$output" | jq -r '.weekly.resets_in_seconds')" = "38400" ]
}

@test "usage_parse_headers renders reset times as ISO 8601 UTC" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.resets_at')" = "2026-09-02T20:20:00Z" ]
  [ "$(echo "$output" | jq -r '.weekly.resets_at')" = "2026-09-03T06:00:00Z" ]
}

@test "usage_parse_headers never reports a negative countdown for a past reset" {
  write_headers 200
  export CC_USAGE_NOW=1788999999  # long after both resets
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.resets_in_seconds')" = "0" ]
}

@test "usage_parse_headers carries through unified status, fallback and overage" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.status')" = "allowed" ]
  [ "$(echo "$output" | jq -r '.fallback')" = "available" ]
  [ "$(echo "$output" | jq -r '.overage_status')" = "rejected" ]
}

@test "usage_parse_headers keeps per-window status separate from unified status" {
  write_headers 200
  sed -i.bak 's/unified-5h-status: allowed/unified-5h-status: rejected/' "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.status')" = "rejected" ]
  [ "$(echo "$output" | jq -r '.weekly.status')" = "allowed" ]
}

@test "usage_parse_headers maps 401 to an unauthorized error" {
  # A rejected token gets no rate limit headers back at all
  printf 'HTTP/2 401 \r\ncontent-type: application/json\r\n\r\n' > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.ok')" = "false" ]
  [ "$(echo "$output" | jq -r '.error')" = "unauthorized" ]
}

@test "usage_parse_headers maps 403 to a scope error" {
  printf 'HTTP/2 403 \r\ncontent-type: application/json\r\n\r\n' > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.error')" = "forbidden_scope" ]
}

@test "usage_parse_headers reads usage from a 429, which still carries the headers" {
  # An exhausted account answers 429 but reports its utilization and reset all
  # the same — the state we most want to surface, so it must not become an error.
  {
    printf 'HTTP/2 429 \r\n'
    printf 'anthropic-ratelimit-unified-status: rejected\r\n'
    printf 'anthropic-ratelimit-unified-5h-status: rejected\r\n'
    printf 'anthropic-ratelimit-unified-5h-reset: 1788380400\r\n'
    printf 'anthropic-ratelimit-unified-5h-utilization: 1.01\r\n'
    printf 'anthropic-ratelimit-unified-7d-status: allowed\r\n'
    printf 'anthropic-ratelimit-unified-7d-reset: 1788415200\r\n'
    printf 'anthropic-ratelimit-unified-7d-utilization: 0.2\r\n'
    printf 'retry-after: 2319\r\n'
    printf '\r\n'
  } > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.ok')" = "true" ]
  [ "$(echo "$output" | jq -r '.status')" = "rejected" ]
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "0" ]
  [ "$(echo "$output" | jq -r '.session.severity')" = "critical" ]
  [ "$(echo "$output" | jq -r '.session.resets_in_seconds')" = "3600" ]
  [ "$(echo "$output" | jq -r '.weekly.percent_left')" = "80" ]
}

@test "usage_parse_headers maps a 429 with no headers to a rate limited error" {
  printf 'HTTP/2 429 \r\ncontent-type: application/json\r\n\r\n' > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.ok')" = "false" ]
  [ "$(echo "$output" | jq -r '.error')" = "rate_limited" ]
}

@test "usage_parse_headers maps 500 to a server error" {
  printf 'HTTP/2 500 \r\ncontent-type: application/json\r\n\r\n' > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.error')" = "server_error" ]
}

@test "usage_parse_headers reports missing rate limit headers on an otherwise ok response" {
  printf 'HTTP/2 200 \r\ncontent-type: application/json\r\n\r\n' > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.ok')" = "false" ]
  [ "$(echo "$output" | jq -r '.error')" = "no_rate_limit_headers" ]
}

@test "usage_parse_headers reads the last status line when curl followed a redirect" {
  {
    printf 'HTTP/2 307 \r\nlocation: https://example.invalid\r\n\r\n'
    printf 'HTTP/2 401 \r\ncontent-type: application/json\r\n\r\n'
  } > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.error')" = "unauthorized" ]
}

@test "usage_parse_headers emits valid JSON on every path" {
  printf 'HTTP/2 403 \r\n\r\n' > "$HDR"
  run usage_parse_headers "$HDR"
  echo "$output" | jq -e . >/dev/null
}

@test "usage_severity flags a window as critical once it is exhausted" {
  run usage_severity 0
  [ "$output" = "critical" ]
}

@test "usage_severity flags a nearly exhausted window as warning" {
  run usage_severity 8
  [ "$output" = "warning" ]
}

@test "usage_severity flags a healthy window as ok" {
  run usage_severity 60
  [ "$output" = "ok" ]
}

@test "usage_bar draws a proportional meter" {
  run usage_bar 50 10
  [ "$output" = "█████░░░░░" ]
}

@test "usage_bar draws an empty meter at zero remaining" {
  run usage_bar 0 10
  [ "$output" = "░░░░░░░░░░" ]
}

@test "usage_bar draws a full meter at full remaining" {
  run usage_bar 100 10
  [ "$output" = "██████████" ]
}

# ── Cache ─────────────────────────────────────────────────────────────────────
# A probe costs a real request against the account's own quota, so repeat reads
# must be served from cache rather than re-billed.

@test "usage_cache_get misses when nothing has been cached" {
  run usage_cache_get "leadership"
  [ "$status" -ne 0 ]
}

@test "usage_cache_get returns an entry written within the TTL" {
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true,"session":{"percent_left":42}}'
  run usage_cache_get "leadership"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "42" ]
}

@test "usage_cache_get misses once the entry is older than the TTL" {
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true}'
  export CC_USAGE_NOW=$(( CC_USAGE_NOW + 61 ))
  run usage_cache_get "leadership"
  [ "$status" -ne 0 ]
}

@test "usage_cache_get still hits just inside the TTL boundary" {
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true}'
  export CC_USAGE_NOW=$(( CC_USAGE_NOW + 59 ))
  run usage_cache_get "leadership"
  [ "$status" -eq 0 ]
}

@test "usage_cache_get keeps accounts separate" {
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true,"session":{"percent_left":10}}'
  usage_cache_put "sales"      '{"ok":true,"session":{"percent_left":90}}'
  run usage_cache_get "sales"
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "90" ]
}

@test "usage_cache_put overwrites a previous entry for the same account" {
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true,"session":{"percent_left":10}}'
  usage_cache_put "leadership" '{"ok":true,"session":{"percent_left":20}}'
  run usage_cache_get "leadership"
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "20" ]
}

@test "usage_cache_get always misses when the TTL is zero" {
  export CC_USAGE_CACHE_TTL=0
  usage_cache_put "leadership" '{"ok":true}'
  run usage_cache_get "leadership"
  [ "$status" -ne 0 ]
}

@test "usage_cache_put writes the cache file with owner-only permissions" {
  usage_cache_put "leadership" '{"ok":true}'
  [ "$(stat -f %Lp "$CC_AUTH_DIR/usage-cache.json")" = "600" ]
}

@test "usage_cache_get survives a corrupt cache file instead of erroring" {
  echo 'not json at all' > "$CC_AUTH_DIR/usage-cache.json"
  run usage_cache_get "leadership"
  [ "$status" -ne 0 ]
}

@test "usage_probe_account reports accounts that have no long-term token" {
  vault_init
  run usage_probe_account "ghost"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.error')" = "no_longterm_token" ]
}

@test "usage_probe_account serves a cached result without probing" {
  vault_init
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true,"session":{"percent_left":42}}'
  # No long-term token exists, so a cache miss would report no_longterm_token.
  run usage_probe_account "leadership"
  [ "$(echo "$output" | jq -r '.session.percent_left')" = "42" ]
  [ "$(echo "$output" | jq -r '.cached')" = "true" ]
}

@test "usage_probe_account bypasses the cache when asked to refresh" {
  vault_init
  export CC_USAGE_CACHE_TTL=60
  usage_cache_put "leadership" '{"ok":true,"session":{"percent_left":42}}'
  run usage_probe_account "leadership" true
  [ "$(echo "$output" | jq -r '.error')" = "no_longterm_token" ]
}

@test "usage_cache_put keeps every entry when accounts are probed concurrently" {
  export CC_USAGE_CACHE_TTL=600
  local n
  for n in alpha bravo charlie delta echo_acct; do
    usage_cache_put "$n" "{\"ok\":true,\"who\":\"$n\"}" &
  done
  wait
  local count
  count=$(jq -r 'keys | length' "$CC_AUTH_DIR/usage-cache.json")
  [ "$count" = "5" ]
}

@test "usage_cache_put leaves the cache file valid JSON after concurrent writes" {
  export CC_USAGE_CACHE_TTL=600
  local n
  for n in alpha bravo charlie delta echo_acct; do
    usage_cache_put "$n" "{\"ok\":true,\"who\":\"$n\"}" &
  done
  wait
  jq -e . "$CC_AUTH_DIR/usage-cache.json" >/dev/null
}

# ── Resolving the genuinely active account ────────────────────────────────────
# cc-auth's state.json records the last account IT activated. An external
# `claude login` changes the keychain without telling cc-auth, so the keychain —
# not state.json — is the source of truth for who is actually logged in.

@test "accounts_name_for_email maps a registered email to its account name" {
  vault_init
  accounts_add "product" "product@kash.bot" "max" "default_claude_max_20x"
  accounts_add "operations" "operations@kash.bot" "max" "default_claude_max_20x"
  run accounts_name_for_email "product@kash.bot"
  [ "$status" -eq 0 ]
  [ "$output" = "product" ]
}

@test "accounts_name_for_email fails for an email that is not registered" {
  vault_init
  accounts_add "product" "product@kash.bot" "max" "default_claude_max_20x"
  run accounts_name_for_email "stranger@kash.bot"
  [ "$status" -ne 0 ]
}

@test "accounts_name_for_email fails when given no email" {
  vault_init
  run accounts_name_for_email ""
  [ "$status" -ne 0 ]
}

@test "accounts_name_for_email matches regardless of email case" {
  vault_init
  accounts_add "product" "product@kash.bot" "max" "default_claude_max_20x"
  run accounts_name_for_email "Product@Kash.Bot"
  [ "$output" = "product" ]
}

@test "usage_best_account picks the account with the most session headroom" {
  local results='[
    {"account":"a","ok":true,"session":{"percent_left":10},"weekly":{"percent_left":90}},
    {"account":"b","ok":true,"session":{"percent_left":70},"weekly":{"percent_left":50}},
    {"account":"c","ok":true,"session":{"percent_left":40},"weekly":{"percent_left":90}}
  ]'
  run usage_best_account "$results"
  [ "$output" = "b" ]
}

@test "usage_best_account ignores accounts that could not be probed" {
  local results='[
    {"account":"a","ok":false,"error":"unauthorized"},
    {"account":"b","ok":true,"session":{"percent_left":30},"weekly":{"percent_left":50}}
  ]'
  run usage_best_account "$results"
  [ "$output" = "b" ]
}

@test "usage_best_account breaks a session tie on weekly headroom" {
  local results='[
    {"account":"a","ok":true,"session":{"percent_left":50},"weekly":{"percent_left":20}},
    {"account":"b","ok":true,"session":{"percent_left":50},"weekly":{"percent_left":80}}
  ]'
  run usage_best_account "$results"
  [ "$output" = "b" ]
}

@test "usage_best_account reports nothing when every account is exhausted" {
  local results='[
    {"account":"a","ok":true,"session":{"percent_left":0},"weekly":{"percent_left":50}},
    {"account":"b","ok":true,"session":{"percent_left":0},"weekly":{"percent_left":50}}
  ]'
  run usage_best_account "$results"
  [ -z "$output" ]
}

@test "usage_best_account reports nothing when no account could be probed" {
  run usage_best_account '[{"account":"a","ok":false,"error":"no_longterm_token"}]'
  [ -z "$output" ]
}

# ── Fields already present in the response but not previously surfaced ────────

@test "usage_parse_headers exposes the organization and workspace ids" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.organization_id')" = "53745887-676c-4947-a3b3-48663e813ce0" ]
  [ "$(echo "$output" | jq -r '.workspace_id')" = "ws-abc123" ]
}

@test "usage_parse_headers normalizes a five_hour representative claim to the session window" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.representative_claim')" = "five_hour" ]
  [ "$(echo "$output" | jq -r '.binding')" = "session" ]
}

@test "usage_parse_headers normalizes a seven_day representative claim to the weekly window" {
  write_headers 200
  sed -i.bak 's/representative-claim: five_hour/representative-claim: seven_day/' "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.binding')" = "weekly" ]
}

@test "usage_parse_headers leaves an unrecognised representative claim unmapped" {
  write_headers 200
  sed -i.bak 's/representative-claim: five_hour/representative-claim: some_new_window/' "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.representative_claim')" = "some_new_window" ]
  [ "$(echo "$output" | jq -r '.binding')" = "" ]
}

@test "usage_parse_headers reports the fallback percentage on the same 0-100 scale as utilization" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.fallback')" = "available" ]
  [ "$(echo "$output" | jq -r '.fallback_percentage')" = "50" ]
}

@test "usage_parse_headers reports why overage is unavailable" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.overage_status')" = "rejected" ]
  [ "$(echo "$output" | jq -r '.overage_disabled_reason')" = "org_level_disabled" ]
}

@test "usage_parse_headers reports the surpassed threshold on the window that blew" {
  write_headers 200
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.surpassed_threshold')" = "1.0" ]
  [ "$(echo "$output" | jq -r '.weekly.surpassed_threshold')" = "" ]
}

@test "usage_parse_headers reports retry-after seconds when the API sends one" {
  write_headers 200
  printf 'retry-after: 2319\r\n' >> "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.retry_after_seconds')" = "2319" ]
}

@test "usage_parse_headers leaves the new fields empty when the response omits them" {
  {
    printf 'HTTP/2 200 \r\n'
    printf 'anthropic-ratelimit-unified-5h-utilization: 0.10\r\n'
    printf 'anthropic-ratelimit-unified-5h-reset: 1788380400\r\n'
    printf '\r\n'
  } > "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.ok')" = "true" ]
  [ "$(echo "$output" | jq -r '.organization_id')" = "" ]
  [ "$(echo "$output" | jq -r '.binding')" = "" ]
  [ "$(echo "$output" | jq -r '.retry_after_seconds')" = "null" ]
  [ "$(echo "$output" | jq -r '.fallback_percentage')" = "null" ]
}

# ── Window status labels ──────────────────────────────────────────────────────
# The API reports its own verdict per window, separately from our percent-based
# severity: "allowed_warning" means it considers the window close to its limit.

@test "usage_status_label marks a rejected window as blocked" {
  run usage_status_label "rejected"
  [ "$output" = "BLOCKED" ]
}

@test "usage_status_label marks an allowed_warning window as near limit" {
  run usage_status_label "allowed_warning"
  [ "$output" = "NEAR LIMIT" ]
}

@test "usage_status_label says nothing for a healthy window" {
  run usage_status_label "allowed"
  [ -z "$output" ]
}

@test "usage_status_label says nothing for an unknown or missing status" {
  run usage_status_label ""
  [ -z "$output" ]
  run usage_status_label "some_future_status"
  [ -z "$output" ]
}

@test "usage_parse_headers preserves an allowed_warning window status verbatim" {
  write_headers 200
  sed -i.bak 's/unified-5h-status: allowed/unified-5h-status: allowed_warning/' "$HDR"
  run usage_parse_headers "$HDR"
  [ "$(echo "$output" | jq -r '.session.status')" = "allowed_warning" ]
}
