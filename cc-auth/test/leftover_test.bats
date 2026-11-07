#!/usr/bin/env bats
# Tests for `cc-auth pick` and the leftover policy: which account a background agent should use to
# spend what sessions leave behind. The API is replaced by a fake curl and every token is a made-up
# string; no request leaves this machine.

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
  # The policy tests below use a wide band (sessions leave at 95%, the agent stops at 99%) so the
  # figures read clearly; the defaults have their own test.
  export CC_AUTH_SWITCH_AT=0.95 CC_AUTH_LEFTOVER_STOP=0.99
  source "$TOOLKIT_ROOT/lib/common.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/keychain.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/vault.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/usage.bash"

  # Fake API. The token (from the Authorization header on stdin) sets the response:
  #   w<weekly>-h<5-hour>-d<days to weekly reset>-<org>   200 with those figures
  #   limited-<org>                                       429, rejected on the weekly window
  #   down-<org>                                          no response
  cat > "$FAKE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
stdin=$(cat)
hdr=""; while [[ $# -gt 0 ]]; do [[ "$1" == -D ]] && hdr="$2"; shift; done
tok=$(sed -n 's/^Authorization: Bearer //p' <<< "$stdin")
now=$(date +%s)
if [[ "$tok" =~ ^w([0-9.]+)-h([0-9.]+)-d([0-9]+)-(.+)$ ]]; then
  printf 'HTTP/2 200\r\nanthropic-organization-id: %s\r\nanthropic-ratelimit-unified-status: allowed\r\nanthropic-ratelimit-unified-representative-claim: seven_day\r\nanthropic-ratelimit-unified-5h-utilization: %s\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-utilization: %s\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n\r\n' \
    "${BASH_REMATCH[4]}" "${BASH_REMATCH[2]}" "$(( now + 3600 ))" "${BASH_REMATCH[1]}" "$(( now + BASH_REMATCH[3] * 86400 + 60 ))" > "$hdr"
  printf 200
elif [[ "$tok" == limited-* ]]; then
  printf 'HTTP/2 429\r\nanthropic-organization-id: %s\r\nanthropic-ratelimit-unified-status: rejected\r\nanthropic-ratelimit-unified-representative-claim: seven_day\r\nanthropic-ratelimit-unified-5h-utilization: 0.5\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-utilization: 1.0\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n\r\n' \
    "${tok#limited-}" "$(( now + 3600 ))" "$(( now + 3600 ))" > "$hdr"
  printf 429
else
  printf '000'; exit 7
fi
EOF
  chmod +x "$FAKE_DIR/bin/curl"
  export PATH="$FAKE_DIR/bin:$PATH"
  export NO_COLOR=1
  vault_init >/dev/null 2>&1
}

teardown() {
  rm -rf "$CC_AUTH_DIR"
}

# Args: name, org, long-term token
add_account() {
  accounts_add "$1" "$1@example.com" max tier >/dev/null 2>&1
  accounts_set_org "$1" "$2" >/dev/null 2>&1
  vault_write_longterm "$1" "$3"
}

# One usage_account-shaped result. Args: name, weekly, 5-hour, weekly reset, [status], [http]
res() {
  jq -cn --arg n "$1" --argjson w "$2" --argjson h "$3" --argjson r "$4" --arg s "${5:-allowed}" \
    --argjson http "${6:-200}" '{name: $n, ok: ($http != 0), http: $http, source: "longterm", status: $s,
      organization_mismatch: false, five_hour: {utilization: $h, resets_at: 1}, seven_day: {utilization: $w, resets_at: $r}}'
}

arr() { jq -cs . <<< "$(printf '%s\n' "$@")"; }

pick() { usage_pick_leftover "$1" "${2:-}" | jq -r '"\(.account) \(.reason)"'; }

@test "leftover: takes the left-over account whose weekly window resets soonest" {
  local r
  r=$(arr "$(res fresh 0.10 0.0 100)" "$(res later 0.96 0.0 400)" "$(res sooner 0.97 0.0 300)" \
          "$(res capped 1.0 0.0 50 rejected)")
  [ "$(pick "$r")" = "sooner leftover" ]
}

@test "leftover: an account full only on its 5-hour window is not left over" {
  local r
  r=$(arr "$(res busy 0.40 0.97 100)" "$(res fresh 0.10 0.0 300)")
  [ "$(pick "$r")" = "fresh fallback" ]
}

@test "leftover: an account past the stop ceiling is left alone" {
  local r
  r=$(arr "$(res brim 0.99 0.0 100)" "$(res left 0.96 0.0 300)")
  [ "$(pick "$r")" = "left leftover" ]
  r=$(arr "$(res left 0.96 0.99 100)" "$(res fresh 0.10 0.0 300)")
  [ "$(pick "$r")" = "fresh fallback" ]
}

@test "leftover: stays on the current left-over account even when another resets sooner" {
  local r
  r=$(arr "$(res sooner 0.96 0.0 100)" "$(res mine 0.97 0.0 300)")
  [ "$(pick "$r" mine)" = "mine leftover" ]
}

@test "leftover: leaves the fallback for a left-over account as soon as one appears" {
  local r
  r=$(arr "$(res mine 0.20 0.0 100)" "$(res left 0.96 0.0 300)")
  [ "$(pick "$r" mine)" = "left leftover" ]
}

@test "leftover: with nothing left over, keeps the current account while it has room" {
  local r
  r=$(arr "$(res sooner 0.10 0.0 100)" "$(res mine 0.20 0.0 300)")
  [ "$(pick "$r" mine)" = "mine fallback" ]
  r=$(arr "$(res sooner 0.10 0.0 100)" "$(res mine 0.99 0.0 300)")
  [ "$(pick "$r" mine)" = "sooner fallback" ]
}

@test "leftover: keeps the current account when its check got no answer" {
  local r
  r=$(arr "$(res mine 0 0 0 null 0)" "$(res left 0.96 0.0 300)")
  [ "$(pick "$r" mine)" = "mine no-answer" ]
}

@test "leftover: nothing usable prints nothing" {
  local r
  r=$(arr "$(res a 1.0 0.0 100 rejected)" "$(res b 0.995 0.0 300)")
  [ -z "$(usage_pick_leftover "$r" "")" ]
  [ -z "$(usage_pick_leftover '[]' "")" ]
}

@test "leftover: the thresholds come from CC_AUTH_SWITCH_AT and CC_AUTH_LEFTOVER_STOP" {
  local r
  r=$(arr "$(res a 0.85 0.0 100)" "$(res b 0.10 0.0 300)")
  [ "$(pick "$r")" = "a fallback" ]
  # shellcheck disable=SC2034  # read by usage_pick_leftover
  CC_AUTH_SWITCH_AT=0.80
  [ "$(pick "$r")" = "a leftover" ]
  # shellcheck disable=SC2034  # read by usage_pick_leftover
  CC_AUTH_LEFTOVER_STOP=0.85
  [ "$(pick "$r")" = "b fallback" ]
}

@test "pick --leftover: checks every account live, records it, prints the name" {
  add_account fresh org1 w0.10-h0.0-d5-org1
  add_account later org2 w0.96-h0.0-d4-org2
  add_account sooner org3 w0.97-h0.0-d1-org3
  add_account capped org4 limited-org4
  run "$CC_AUTH" pick --leftover
  [ "$status" -eq 0 ]
  [ "$output" = sooner ]
  [ "$(jq -r '.accounts.later.windows.seven_day.utilization' "$CC_AUTH_STATE_FILE")" = 0.96 ]
  [ "$(jq -r '.accounts.capped.limited_until > 0' "$CC_AUTH_STATE_FILE")" = true ]
}

@test "pick --leftover --json: names the account and why, and never prints a token" {
  add_account mine org1 w0.97-h0.0-d4-org1
  add_account sooner org2 w0.96-h0.0-d1-org2
  run "$CC_AUTH" pick --leftover --current mine --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '"\(.account) \(.reason) \(.seven_day.utilization)"' <<< "$output")" = "mine leftover 0.97" ]
  [[ "$output" != *w0.97-h0.0* && "$output" != *w0.96-h0.0* ]]
}

@test "pick: without --leftover, the account sessions would pick" {
  add_account later org1 w0.10-h0.0-d5-org1
  add_account sooner org2 w0.20-h0.0-d2-org2
  add_account left org3 w0.96-h0.0-d1-org3
  run "$CC_AUTH" pick
  [ "$status" -eq 0 ]
  [ "$output" = sooner ]
}

@test "pick does not change the account sessions use" {
  add_account a org1 w0.10-h0.0-d5-org1
  add_account b org2 w0.96-h0.0-d1-org2
  state_set_session_account a
  run "$CC_AUTH" pick --leftover
  [ "$output" = b ]
  [ "$(state_session_account)" = a ]
}

@test "pick: exits 77 when no account is usable, 2 on bad arguments" {
  add_account a org1 limited-org1
  add_account b org2 down-org2
  run "$CC_AUTH" pick --leftover
  [ "$status" -eq 77 ]
  run "$CC_AUTH" pick --current a
  [ "$status" -eq 2 ]
  run "$CC_AUTH" pick --leftover --current nobody
  [ "$status" -eq 2 ]
  run "$CC_AUTH" pick --bogus
  [ "$status" -eq 2 ]
}

@test "defaults: sessions leave an account at 99%, the agent spends it to 100%" {
  run bash -c "unset CC_AUTH_SWITCH_AT CC_AUTH_LEFTOVER_STOP; source '$TOOLKIT_ROOT/cc-auth/lib/usage.bash'; echo \$CC_AUTH_SWITCH_AT \$CC_AUTH_LEFTOVER_STOP"
  [ "$output" = "0.99 1.0" ]
}

@test "defaults: the agent takes a 99% account, and shares the sessions' pick when none is left" {
  local r
  CC_AUTH_SWITCH_AT=0.99 CC_AUTH_LEFTOVER_STOP=1.0
  r=$(arr "$(res fresh 0.40 0.0 100)" "$(res brim 0.99 0.0 300)" "$(res full 1.0 0.0 50 rejected)")
  [ "$(pick "$r")" = "brim leftover" ]
  r=$(arr "$(res later 0.40 0.0 300)" "$(res sooner 0.97 0.0 100)" "$(res full 1.0 0.0 50 rejected)")
  [ "$(pick "$r")" = "sooner fallback" ]   # 97% is still the sessions' account: shared
  [ "$(usage_pick "$r")" = "sooner" ]
}
