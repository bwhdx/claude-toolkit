#!/usr/bin/env bats
# Tests for cc-auth usage: header parsing, token handling, `usage`, `setup-longterm`, `onboard`.
# The API is replaced by a fake curl; no request leaves this machine.

setup() {
  export CC_AUTH_DIR="$(mktemp -d)"
  export CC_AUTH_VAULT_DIR="$CC_AUTH_DIR/vault"
  export CC_AUTH_VAULT_KEY="$CC_AUTH_DIR/vault.key"
  export CC_AUTH_ACCOUNTS_FILE="$CC_AUTH_DIR/accounts.json"
  export CC_AUTH_STATE_FILE="$CC_AUTH_DIR/state.json"
  export CC_AUTH_LOCK_DIR="$CC_AUTH_DIR/.cycle.lock"
  export FAKE_DIR="$CC_AUTH_DIR/fake"
  mkdir -p "$FAKE_DIR/bin"

  TOOLKIT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CC_AUTH="$TOOLKIT_ROOT/cc-auth/cc-auth"
  source "$TOOLKIT_ROOT/lib/common.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/keychain.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/vault.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/usage.bash"

  # Fake API. The token (from the Authorization header on stdin) picks the response:
  #   good-<org>     200, allowed, 5h 24% / 7d 31%, weekly reset in 3 days
#   soon-<org>     the same, weekly reset in 1 day
  #   limited-<org>  429, rejected on the weekly window
  #   anything else  401, no rate-limit headers
  cat > "$FAKE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/argv"
stdin=$(cat); printf '%s\n' "$stdin" >> "$FAKE_DIR/stdin"
hdr=""; while [[ $# -gt 0 ]]; do [[ "$1" == -D ]] && hdr="$2"; shift; done
tok=$(sed -n 's/^Authorization: Bearer //p' <<< "$stdin")
reset5=$(( $(date +%s) + 7200 )); reset7=$(( $(date +%s) + 3 * 86400 ))
case "$tok" in
  good-*|soon-*)
    [[ "$tok" == soon-* ]] && reset7=$(( $(date +%s) + 86400 ))
    printf 'HTTP/2 200\r\nAnthropic-Organization-Id: %s\r\nanthropic-ratelimit-unified-status: allowed\r\nanthropic-ratelimit-unified-representative-claim: five_hour\r\nanthropic-ratelimit-unified-5h-utilization: 0.24\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-7d-utilization: 0.31\r\nanthropic-ratelimit-unified-7d-reset: %s\r\nanthropic-ratelimit-unified-7d-status: allowed\r\n\r\n' \
      "${tok#*-}" "$reset5" "$reset7" > "$hdr"
    printf 200 ;;
  limited-*)
    printf 'HTTP/2 429\r\nanthropic-organization-id: %s\r\nanthropic-ratelimit-unified-status: rejected\r\nanthropic-ratelimit-unified-representative-claim: seven_day\r\nanthropic-ratelimit-unified-5h-utilization: 0.5\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-utilization: 1.0\r\nanthropic-ratelimit-unified-7d-reset: %s\r\nanthropic-ratelimit-unified-7d-status: rejected\r\n\r\n' \
      "${tok#limited-}" "$reset5" "$reset7" > "$hdr"
    printf 429 ;;
  *) printf 'HTTP/2 401\r\n\r\n' > "$hdr"; printf 401 ;;
esac
EOF
  # Fake claude: records calls; onboard must not reach it when the list is invalid.
  printf '#!/usr/bin/env bash\necho "$*" >> "$FAKE_DIR/claude-calls"\n' > "$FAKE_DIR/bin/claude"
  chmod +x "$FAKE_DIR/bin/curl" "$FAKE_DIR/bin/claude"
  export PATH="$FAKE_DIR/bin:$PATH"
  export NO_COLOR=1

  vault_init >/dev/null 2>&1
}

teardown() {
  teardown_keychain
  rm -rf "$CC_AUTH_DIR"
}

# An account with an optional long-term token and an optional sign-in valid for an hour.
add_account() {  # add_account NAME ORG [LONGTERM_TOKEN] [OAUTH_TOKEN]
  accounts_add "$1" "$1@example.com" max tier
  state_init_account "$1"
  [[ -n "$2" ]] && accounts_set_org "$1" "$2"
  [[ -n "${3:-}" ]] && vault_write_longterm "$1" "$3"
  if [[ -n "${4:-}" ]]; then
    vault_write "$1" "$(jq -cn --arg t "$4" --argjson e "$(( ($(date +%s) + 3600) * 1000 ))" \
      '{claudeAiOauth: {accessToken: $t, expiresAt: $e}}')"
  fi
}

@test "usage_parse reads mixed-case headers with CRLF line endings" {
  printf 'HTTP/2 200\r\nAnthropic-Organization-Id: org1\r\nanthropic-ratelimit-unified-status: allowed\r\nANTHROPIC-RATELIMIT-UNIFIED-5H-UTILIZATION: 0.24\r\nanthropic-ratelimit-unified-5h-reset: 100\r\nanthropic-ratelimit-unified-7d-utilization: 0.31\r\n' > "$CC_AUTH_DIR/h"
  run usage_parse "$CC_AUTH_DIR/h" 200
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<< "$output")" = true ]
  [ "$(jq -r '.organization_id' <<< "$output")" = org1 ]
  [ "$(jq -r '.five_hour.utilization' <<< "$output")" = 0.24 ]
  [ "$(jq -r '.five_hour.resets_at' <<< "$output")" = 100 ]
  [ "$(jq -r '.seven_day.utilization' <<< "$output")" = 0.31 ]
  [ "$(jq -r '.seven_day.resets_at' <<< "$output")" = null ]
}

@test "usage_parse marks a response without rate-limit headers as not ok" {
  : > "$CC_AUTH_DIR/h"
  run usage_parse "$CC_AUTH_DIR/h" 000
  [ "$(jq -r '.ok' <<< "$output")" = false ]
  [ "$(jq -r '.http' <<< "$output")" = 0 ]
}

@test "usage_probe sends the token on stdin, never in curl's arguments" {
  run usage_probe good-org1
  [ "$(jq -r '.ok' <<< "$output")" = true ]
  ! grep -q good-org1 "$FAKE_DIR/argv"
  grep -q 'Authorization: Bearer good-org1' "$FAKE_DIR/stdin"
}

@test "usage_token prefers the long-term token over the sign-in" {
  add_account a org1 good-org1 oauth-tok
  run usage_token a
  [ "$output" = $'longterm\tgood-org1' ]
}

@test "usage_token falls back to a valid sign-in and rejects an expired one" {
  add_account a org1 "" oauth-tok
  run usage_token a
  [ "$output" = $'oauth\toauth-tok' ]
  vault_write a '{"claudeAiOauth": {"accessToken": "old", "expiresAt": 1000}}'
  run usage_token a
  [ "$status" -eq 1 ]
}

@test "usage --json reports every account and records the figures in state" {
  add_account a org1 good-org1
  add_account b org2 limited-org2
  run "$CC_AUTH" usage --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].name] | join(",")' <<< "$output")" = a,b ]
  [ "$(jq -r '.[0].five_hour.utilization' <<< "$output")" = 0.24 ]
  [ "$(jq -r '.[1].status' <<< "$output")" = rejected ]
  [ "$(jq -r '.accounts.a.utilization' "$CC_AUTH_STATE_FILE")" = 0.24 ]
  [ "$(jq -r '.accounts.b.utilization' "$CC_AUTH_STATE_FILE")" = 1.0 ]
  state_is_limited b
  ! state_is_limited a
}

@test "usage flags a token from another organization and fails for an account without a token" {
  add_account a org1 good-orgX
  add_account b org2
  run "$CC_AUTH" usage --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.[0].organization_mismatch' <<< "$output")" = true ]
  [ "$(jq -r '.[1].source' <<< "$output")" = none ]
}

@test "usage table shows bars, percentages and what to do about a missing token" {
  add_account a org1 good-org1
  add_account b org2
  run "$CC_AUTH" usage
  [ "$status" -eq 1 ]
  # Weekly 31% of 20 cells is 6 filled; 5-hour 24% of 10 cells is 2.
  [[ "$output" == *"██████░░░░░░░░░░░░░░  31%"* ]]
  [[ "$output" == *"██░░░░░░░░  24%"* ]]
  [[ "$output" == *"no token: run cc-auth setup-longterm b"* ]]
}

@test "usage table lists the soonest weekly reset first, accounts without figures last" {
  add_account none org0
  add_account later org1 good-org1
  add_account sooner org2 soon-org2
  run "$CC_AUTH" usage
  local rows
  rows=$(printf '%s\n' "$output" | awk '$1 ~ /^(none|later|sooner)$/ {print $1}' | paste -sd, -)
  [ "$rows" = sooner,later,none ]
}

@test "usage bar marks any use with at least one cell and caps at full" {
  source "$TOOLKIT_ROOT/lib/common.bash"
  eval "$(sed -n '/^_usage_bar() {/,/^}/p' "$CC_AUTH")"
  [ "$(_usage_bar 0.01 10)" = "█░░░░░░░░░   1%" ]
  [ "$(_usage_bar 1.2 10)" = "██████████ 120%" ]
  [ "$(_usage_bar 0 10)" = "░░░░░░░░░░   0%" ]
}

@test "usage rejects an unknown account" {
  add_account a org1 good-org1
  run "$CC_AUTH" usage nobody
  [ "$status" -eq 1 ]
}

@test "setup-longterm refuses a token passed as an argument" {
  add_account a org1
  run "$CC_AUTH" setup-longterm a good-org1
  [ "$status" -eq 2 ]
  ! vault_has_longterm a
}

@test "setup-longterm stores a piped token of the right account" {
  add_account a org1
  run bash -c "printf 'good-org1\n' | '$CC_AUTH' setup-longterm a"
  [ "$status" -eq 0 ]
  [ "$(vault_read_longterm a)" = good-org1 ]
}

@test "setup-longterm refuses a token of another account" {
  add_account a org1
  run bash -c "printf 'good-org2\n' | '$CC_AUTH' setup-longterm a"
  [ "$status" -eq 10 ]
  [[ "$output" == *"different account"* ]]
  ! vault_has_longterm a
}

@test "setup-longterm refuses a token the API rejects" {
  add_account a org1
  run bash -c "printf 'bad\n' | '$CC_AUTH' setup-longterm a"
  [ "$status" -eq 10 ]
  ! vault_has_longterm a
}

@test "setup-longterm learns the organization from a valid sign-in when none is recorded" {
  add_account a "" "" good-org1
  run bash -c "printf 'good-org2\n' | '$CC_AUTH' setup-longterm a"
  [ "$status" -eq 10 ]
  [ "$(accounts_get a | jq -r .organization_id)" = org1 ]
}

@test "onboard checks the whole list before any sign-in" {
  printf '# accounts\na a@example.com\nb\n' > "$CC_AUTH_DIR/list"
  run "$CC_AUTH" onboard "$CC_AUTH_DIR/list"
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE_DIR/claude-calls" ]
}

@test "onboard skips accounts and tokens already stored" {
  add_account a org1 good-org1
  printf 'a a@example.com\n' > "$CC_AUTH_DIR/list"
  run "$CC_AUTH" onboard "$CC_AUTH_DIR/list"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_DIR/claude-calls" ]
  [[ "$output" == *"already added"*"already stored"* ]]
}

@test "usage with no accounts says how to add them" {
  run "$CC_AUTH" usage
  [ "$status" -eq 1 ]
  [[ "$output" == *"No accounts yet"* ]]
}

# A scratch keychain standing in for the login keychain, and a fake claude whose sign-in writes
# credentials for the given email into it (access token "good-<org>" so the fake API accepts it).
use_scratch_keychain() {
  export CC_KEYCHAIN_FILE="$CC_AUTH_DIR/scratch.keychain-db"
  security create-keychain -p pw "$CC_KEYCHAIN_FILE"
  security unlock-keychain -p pw "$CC_KEYCHAIN_FILE"
  cat > "$FAKE_DIR/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/claude-calls"
case "$1 $2" in
  "auth login")
    security delete-generic-password -s "Claude Code-credentials" -a "$(whoami)" "$CC_KEYCHAIN_FILE" >/dev/null 2>&1
    security add-generic-password -s "Claude Code-credentials" -a "$(whoami)" \
      -w "{\"claudeAiOauth\":{\"accessToken\":\"good-org-$4\",\"expiresAt\":99999999999999}}" "$CC_KEYCHAIN_FILE" ;;
  "auth status") echo "{\"loggedIn\":true,\"email\":\"$(sed -n 's/.*"good-org-\([^"]*\)".*/\1/p' <<< "$(security find-generic-password -s "Claude Code-credentials" -w "$CC_KEYCHAIN_FILE")")\",\"subscriptionType\":\"max\"}" ;;
esac
exit 0
FAKE
  chmod +x "$FAKE_DIR/bin/claude"
}

teardown_keychain() {
  [[ -n "${CC_KEYCHAIN_FILE:-}" && -f "$CC_KEYCHAIN_FILE" ]] && security delete-keychain "$CC_KEYCHAIN_FILE"
  return 0
}

@test "keychain_write round-trips credentials with quotes and backslashes" {
  use_scratch_keychain
  local cred='{"claudeAiOauth":{"accessToken":"a\"b\\c","scopes":["x"]}}'
  keychain_write "$cred"
  [ "$(keychain_read)" = "$cred" ]
  keychain_write '{"replaced":true}'
  [ "$(keychain_read)" = '{"replaced":true}' ]
}

@test "keychain_write never puts the credentials in security's arguments" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE_DIR/security-argv"; [ "$1" = -i ] && cat > /dev/null; exit 0\n' > "$FAKE_DIR/bin/security"
  chmod +x "$FAKE_DIR/bin/security"
  keychain_write '{"claudeAiOauth":{"accessToken":"secret-tok"}}'
  ! grep -q secret-tok "$FAKE_DIR/security-argv"
}

@test "onboard adds accounts with tokens and leaves Claude Code's own sign-in as it was" {
  use_scratch_keychain
  keychain_write '{"claudeAiOauth":{"accessToken":"mine","expiresAt":99999999999999}}'
  printf 'a a@example.com\nb b@example.com\n' > "$CC_AUTH_DIR/list"
  run bash -c "printf 'good-org-a@example.com\ngood-org-b@example.com\n' | '$CC_AUTH' onboard '$CC_AUTH_DIR/list'"
  [ "$status" -eq 0 ]
  [ "$(vault_read_longterm a)" = good-org-a@example.com ]
  [ "$(vault_read_longterm b)" = good-org-b@example.com ]
  [ "$(accounts_get b | jq -r .organization_id)" = org-b@example.com ]
  [ "$(keychain_read | jq -r .claudeAiOauth.accessToken)" = mine ]
  [ -z "$(state_active_account)" ]
}

@test "onboard stores nothing for a token of the wrong account" {
  use_scratch_keychain
  printf 'a a@example.com\n' > "$CC_AUTH_DIR/list"
  run bash -c "printf 'good-org-z@example.com\nn\n' | '$CC_AUTH' onboard '$CC_AUTH_DIR/list'"
  [ "$status" -eq 1 ]
  ! vault_has_longterm a
  [[ "$output" == *"different account"* ]]
}

@test "run starts claude with the account's token in its environment, not its arguments" {
  add_account a org1 good-org1
  printf '#!/usr/bin/env bash\necho "args=$*"\necho "token=$CLAUDE_CODE_OAUTH_TOKEN"\necho "apikey=${ANTHROPIC_API_KEY:-unset}"\n' > "$FAKE_DIR/bin/claude"
  chmod +x "$FAKE_DIR/bin/claude"
  ANTHROPIC_API_KEY=sk-test run "$CC_AUTH" run a --model haiku
  [ "$status" -eq 0 ]
  [ "$(grep '^args=' <<< "$output")" = "args=--model haiku" ]
  [[ "$output" == *"token=good-org1"* ]]
  [[ "$output" == *"apikey=unset"* ]]
}

@test "run refuses an account without a long-term token" {
  add_account a org1
  run "$CC_AUTH" run a
  [ "$status" -eq 1 ]
  [[ "$output" == *"no long-term token"* ]]
  [ ! -e "$FAKE_DIR/claude-calls" ]
}
