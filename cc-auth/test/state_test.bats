#!/usr/bin/env bats
# Tests for cc-auth state management — active account, limit tracking, expiry

setup() {
  export CC_AUTH_DIR="$(mktemp -d)"
  export CC_AUTH_VAULT_DIR="$CC_AUTH_DIR/vault"
  export CC_AUTH_VAULT_KEY="$CC_AUTH_DIR/vault.key"
  export CC_AUTH_ACCOUNTS_FILE="$CC_AUTH_DIR/accounts.json"
  export CC_AUTH_STATE_FILE="$CC_AUTH_DIR/state.json"
  export CC_AUTH_LOCK_DIR="$CC_AUTH_DIR/.cycle.lock"

  TOOLKIT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  source "$TOOLKIT_ROOT/lib/common.bash"
  source "$TOOLKIT_ROOT/lib/process.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/vault.bash"

  vault_init
}

teardown() {
  rm -rf "$CC_AUTH_DIR"
}

@test "state_active_account returns empty initially" {
  local result=$(state_active_account)
  [ -z "$result" ]
}

@test "state_set_active and state_active_account" {
  state_init_account "acct1"
  state_set_active "acct1"
  [ "$(state_active_account)" = "acct1" ]
}

@test "state_mark_limited and state_is_limited" {
  state_init_account "acct1"
  # Mark limited for 60 seconds
  state_mark_limited "acct1" 60
  run state_is_limited "acct1"
  [ "$status" -eq 0 ]
}

@test "state_is_limited returns 1 for non-limited account" {
  state_init_account "acct1"
  run state_is_limited "acct1"
  [ "$status" -ne 0 ]
}

@test "state_limit_remaining returns seconds" {
  state_init_account "acct1"
  state_mark_limited "acct1" 120
  local remaining=$(state_limit_remaining "acct1")
  # Should be roughly 120 (allow 5s tolerance)
  [ "$remaining" -ge 115 ]
  [ "$remaining" -le 125 ]
}

@test "state_clear_expired removes expired limits" {
  state_init_account "acct1"
  # Mark limited for 0 seconds (already expired)
  local now=$(date +%s)
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg name "acct1" \
    --argjson until "$((now - 10))" \
    '.accounts[$name].limited_until = $until'

  # Should be expired
  state_clear_expired
  run state_is_limited "acct1"
  [ "$status" -ne 0 ]
}

@test "state_init_account is idempotent" {
  state_init_account "acct1"
  state_set_active "acct1"
  state_mark_limited "acct1" 60
  # Re-init should NOT overwrite existing state
  state_init_account "acct1"
  run state_is_limited "acct1"
  [ "$status" -eq 0 ]
}

@test "multiple accounts tracked independently" {
  state_init_account "a1"
  state_init_account "a2"
  state_init_account "a3"

  state_mark_limited "a1" 60
  state_set_active "a2"

  run state_is_limited "a1"
  [ "$status" -eq 0 ]
  run state_is_limited "a2"
  [ "$status" -ne 0 ]
  run state_is_limited "a3"
  [ "$status" -ne 0 ]
  [ "$(state_active_account)" = "a2" ]
}
