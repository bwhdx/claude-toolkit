#!/usr/bin/env bats
# Tests for cc-auth vault operations — encrypt/decrypt, account registry, state management

setup() {
  export CC_AUTH_DIR="$(mktemp -d)"
  export CC_AUTH_VAULT_DIR="$CC_AUTH_DIR/vault"
  export CC_AUTH_VAULT_KEY="$CC_AUTH_DIR/vault.key"
  export CC_AUTH_ACCOUNTS_FILE="$CC_AUTH_DIR/accounts.json"
  export CC_AUTH_STATE_FILE="$CC_AUTH_DIR/state.json"
  export CC_AUTH_LOCK_DIR="$CC_AUTH_DIR/.cycle.lock"

  # Source libraries
  TOOLKIT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  source "$TOOLKIT_ROOT/lib/common.bash"
  source "$TOOLKIT_ROOT/lib/process.bash"
  source "$TOOLKIT_ROOT/cc-auth/lib/vault.bash"
}

teardown() {
  rm -rf "$CC_AUTH_DIR"
}

@test "vault_init creates directory structure" {
  vault_init
  [ -d "$CC_AUTH_DIR" ]
  [ -d "$CC_AUTH_VAULT_DIR" ]
  [ -f "$CC_AUTH_VAULT_KEY" ]
  [ -f "$CC_AUTH_ACCOUNTS_FILE" ]
  [ -f "$CC_AUTH_STATE_FILE" ]
}

@test "vault_init sets correct permissions" {
  vault_init
  local dir_perms=$(stat -f %Lp "$CC_AUTH_DIR")
  local key_perms=$(stat -f %Lp "$CC_AUTH_VAULT_KEY")
  [ "$dir_perms" = "700" ]
  [ "$key_perms" = "400" ]
}

@test "vault_init is idempotent" {
  vault_init
  local key1=$(cat "$CC_AUTH_VAULT_KEY")
  vault_init
  local key2=$(cat "$CC_AUTH_VAULT_KEY")
  [ "$key1" = "$key2" ]
}

@test "vault_write and vault_read round-trip" {
  vault_init
  local test_json='{"claudeAiOauth":{"accessToken":"test-token-123","refreshToken":"refresh-456"}}'
  vault_write "testacct" "$test_json"
  local result=$(vault_read "testacct")
  [ "$result" = "$test_json" ]
}

@test "vault_write creates encrypted file" {
  vault_init
  local test_json='{"secret":"data"}'
  vault_write "testacct" "$test_json"
  [ -f "$CC_AUTH_VAULT_DIR/testacct.enc" ]
  # Encrypted file should NOT contain plaintext
  ! grep -q "secret" "$CC_AUTH_VAULT_DIR/testacct.enc"
}

@test "vault_read fails for nonexistent account" {
  vault_init
  run vault_read "nonexistent"
  [ "$status" -ne 0 ]
}

@test "vault_delete removes encrypted file" {
  vault_init
  vault_write "testacct" '{"data":"test"}'
  [ -f "$CC_AUTH_VAULT_DIR/testacct.enc" ]
  vault_delete "testacct"
  [ ! -f "$CC_AUTH_VAULT_DIR/testacct.enc" ]
}

@test "vault_exists returns correct status" {
  vault_init
  run vault_exists "testacct"
  [ "$status" -ne 0 ]
  vault_write "testacct" '{"data":"test"}'
  run vault_exists "testacct"
  [ "$status" -eq 0 ]
}

@test "accounts_add and accounts_get" {
  vault_init
  accounts_add "acct1" "user@test.com" "max" "default_claude_max_20x"
  local result=$(accounts_get "acct1" | jq -r '.email')
  [ "$result" = "user@test.com" ]
}

@test "accounts_remove deletes account" {
  vault_init
  accounts_add "acct1" "user@test.com" "max" "tier"
  accounts_remove "acct1"
  run accounts_get "acct1"
  [ "$status" -ne 0 ]
}

@test "accounts_count tracks correctly" {
  vault_init
  [ "$(accounts_count)" = "0" ]
  accounts_add "a1" "a@b.com" "max" "tier"
  [ "$(accounts_count)" = "1" ]
  accounts_add "a2" "b@b.com" "max" "tier"
  [ "$(accounts_count)" = "2" ]
  accounts_remove "a1"
  [ "$(accounts_count)" = "1" ]
}

@test "accounts_name_exists" {
  vault_init
  run accounts_name_exists "nope"
  [ "$status" -ne 0 ]
  accounts_add "exists" "e@b.com" "max" "tier"
  run accounts_name_exists "exists"
  [ "$status" -eq 0 ]
}
