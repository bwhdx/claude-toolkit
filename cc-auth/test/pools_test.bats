#!/usr/bin/env bats
# Tests for cc-auth pool management — multi-pool separation, migration, and
# pool-scoped active/cycle/keychain semantics.

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
  source "$TOOLKIT_ROOT/cc-auth/lib/pools.bash"

  vault_init

  # Seed three accounts so we have something to pool
  accounts_add "ops"  "ops@example.com"  "max" "default"
  accounts_add "tech" "tech@example.com" "max" "default"
  accounts_add "prod" "prod@example.com" "max" "default"
  state_init_account "ops"
  state_init_account "tech"
  state_init_account "prod"
  state_set_active "ops"
}

teardown() {
  rm -rf "$CC_AUTH_DIR"
}

@test "pools_migrate_if_needed creates interactive pool with all members" {
  pools_migrate_if_needed
  [ "$(pools_active interactive)" = "ops" ]
  run pools_is_member interactive ops
  [ "$status" -eq 0 ]
  run pools_is_member interactive tech
  [ "$status" -eq 0 ]
  run pools_is_member interactive prod
  [ "$status" -eq 0 ]
  run pools_writes_keychain interactive
  [ "$status" -eq 0 ]
}

@test "pools_migrate_if_needed is idempotent" {
  pools_migrate_if_needed
  pools_migrate_if_needed
  local count
  count=$(jq -r '.pools | keys | length' "$CC_AUTH_STATE_FILE")
  [ "$count" -eq 1 ]
}

@test "pools_create rejects duplicate" {
  pools_create background false
  run pools_create background false
  [ "$status" -ne 0 ]
}

@test "pools_create with no-keychain stores writes_keychain=false" {
  pools_create background false
  run pools_writes_keychain background
  [ "$status" -ne 0 ]
}

@test "pools_add_member sets active when pool was empty" {
  pools_create background false
  pools_add_member background tech
  [ "$(pools_active background)" = "tech" ]
}

@test "pools_add_member does not overwrite existing active" {
  pools_create background false
  pools_add_member background tech
  pools_add_member background prod
  [ "$(pools_active background)" = "tech" ]
}

@test "pools_add_member rejects unknown account" {
  pools_create background false
  run pools_add_member background ghost
  [ "$status" -ne 0 ]
}

@test "pools_remove_member rotates active when removing it" {
  pools_create background false
  pools_add_member background tech
  pools_add_member background prod
  pools_remove_member background tech
  [ "$(pools_active background)" = "prod" ]
}

@test "pools_remove_member clears active when removing last member" {
  pools_create background false
  pools_add_member background tech
  pools_remove_member background tech
  local a
  a=$(pools_active background)
  [ -z "$a" ]
}

@test "pools_set_active mirrors interactive pool to legacy active_account" {
  pools_migrate_if_needed
  pools_set_active interactive tech
  local legacy
  legacy=$(jq -r '.active_account' "$CC_AUTH_STATE_FILE")
  [ "$legacy" = "tech" ]
}

@test "pools_set_active on background does NOT mutate legacy active_account" {
  pools_migrate_if_needed
  pools_create background false
  pools_add_member background tech
  pools_set_active background prod
  pools_add_member background prod
  pools_set_active background prod
  local legacy
  legacy=$(jq -r '.active_account' "$CC_AUTH_STATE_FILE")
  [ "$legacy" = "ops" ]   # unchanged
}

@test "pools_for_account finds all containing pools" {
  pools_migrate_if_needed
  pools_create background false
  pools_add_member background tech
  local result
  result=$(pools_for_account tech)
  [[ "$result" == *"interactive"* ]]
  [[ "$result" == *"background"* ]]
}

@test "pools_infer_for_account returns single pool when unambiguous" {
  pools_migrate_if_needed
  pools_create background false
  pools_add_member background tech
  pools_remove_member interactive tech
  run pools_infer_for_account tech
  [ "$status" -eq 0 ]
  [ "$output" = "background" ]
}

@test "pools_infer_for_account fails when account in multiple pools" {
  pools_migrate_if_needed
  pools_create background false
  pools_add_member background tech
  run pools_infer_for_account tech
  [ "$status" -ne 0 ]
}

@test "pools_infer_for_account fails when account in no pool" {
  pools_migrate_if_needed
  pools_remove_member interactive tech
  run pools_infer_for_account tech
  [ "$status" -ne 0 ]
}

@test "pools_delete removes pool" {
  pools_create background false
  pools_delete background
  run pools_exists background
  [ "$status" -ne 0 ]
}

@test "pools_list_names returns all pools" {
  pools_migrate_if_needed
  pools_create background false
  pools_create ci false
  local result
  result=$(pools_list_names | sort | tr '\n' ' ')
  [ "$result" = "background ci interactive " ]
}
