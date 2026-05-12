#!/usr/bin/env bash
# cc-auth pools — named subsets of accounts with their own active pointer and
# writes_keychain policy. Lets us separate interactive vs background token
# usage so e.g. ax workers can cycle through {technology,product,…} without
# touching the keychain entry your interactive Claude Code session uses.
#
# Pool record in state.json:
#   pools.<name>: { members: [...], active: <name>|null, writes_keychain: bool }
#
# Backward-compat: legacy state.json (no .pools key) is migrated lazily to a
# single "interactive" pool that contains every registered account and inherits
# the current .active_account.

POOLS_INTERACTIVE="interactive"
POOLS_BACKGROUND="background"

# ── Migration ─────────────────────────────────────────────────────────────────

# Idempotently create the "interactive" pool on first read if .pools is absent.
# Members default to every registered account; active = legacy .active_account.
pools_migrate_if_needed() {
  local has_pools
  has_pools=$(jq -r 'has("pools")' "$CC_AUTH_STATE_FILE" 2>/dev/null || echo "false")
  [[ "$has_pools" == "true" ]] && return 0

  local active members_json
  active=$(jq -r '.active_account // ""' "$CC_AUTH_STATE_FILE" 2>/dev/null)
  members_json=$(jq -c '[.accounts[].name]' "$CC_AUTH_ACCOUNTS_FILE" 2>/dev/null || echo '[]')

  json_edit "$CC_AUTH_STATE_FILE" \
    --argjson members "$members_json" \
    --arg active "$active" \
    --arg pool "$POOLS_INTERACTIVE" \
    '.pools = {($pool): {
       members: $members,
       active: (if $active == "" then null else $active end),
       writes_keychain: true
     }}'
}

# ── Pool CRUD ─────────────────────────────────────────────────────────────────

pools_list_names() {
  pools_migrate_if_needed
  jq -r '.pools | keys[]' "$CC_AUTH_STATE_FILE" 2>/dev/null
}

# Args: $1 = pool name; exit 0 if exists.
pools_exists() {
  local pool="$1"
  pools_migrate_if_needed
  jq -e --arg p "$pool" '.pools[$p] != null' "$CC_AUTH_STATE_FILE" >/dev/null 2>&1
}

# Args: $1 = name, $2 = writes_keychain ("true"/"false")
pools_create() {
  local pool="$1" wk="${2:-false}"
  pools_migrate_if_needed
  if pools_exists "$pool"; then
    log_error "Pool '$pool' already exists"
    return 1
  fi
  [[ "$wk" == "true" || "$wk" == "false" ]] || {
    log_error "writes_keychain must be 'true' or 'false', got: $wk"
    return 1
  }
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg p "$pool" \
    --argjson wk "$wk" \
    '.pools[$p] = {members: [], active: null, writes_keychain: $wk}'
}

pools_delete() {
  local pool="$1"
  pools_exists "$pool" || { log_error "Pool '$pool' does not exist"; return 1; }
  json_edit "$CC_AUTH_STATE_FILE" --arg p "$pool" 'del(.pools[$p])'
}

# Args: $1 = pool, $2 = account. Sets active to this account if pool was empty.
pools_add_member() {
  local pool="$1" name="$2"
  pools_exists "$pool" || { log_error "Pool '$pool' does not exist"; return 1; }
  accounts_name_exists "$name" || { log_error "Unknown account: $name"; return 1; }

  json_edit "$CC_AUTH_STATE_FILE" \
    --arg p "$pool" --arg n "$name" \
    '.pools[$p].members = (.pools[$p].members + [$n] | unique)'

  local active
  active=$(pools_active "$pool")
  if [[ -z "$active" || "$active" == "null" ]]; then
    pools_set_active "$pool" "$name"
  fi
}

# Args: $1 = pool, $2 = account. If removing the active, picks first remaining or null.
pools_remove_member() {
  local pool="$1" name="$2"
  pools_exists "$pool" || { log_error "Pool '$pool' does not exist"; return 1; }
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg p "$pool" --arg n "$name" \
    '.pools[$p].members = (.pools[$p].members - [$n])'

  local active
  active=$(pools_active "$pool")
  if [[ "$active" == "$name" ]]; then
    local next
    next=$(jq -r --arg p "$pool" '.pools[$p].members[0] // ""' "$CC_AUTH_STATE_FILE")
    pools_set_active "$pool" "$next"
  fi
}

pools_list_members() {
  local pool="$1"
  pools_exists "$pool" || return 1
  jq -r --arg p "$pool" '.pools[$p].members[]' "$CC_AUTH_STATE_FILE" 2>/dev/null
}

# Args: $1 = pool, $2 = account; exit 0 if member.
pools_is_member() {
  local pool="$1" name="$2"
  jq -e --arg p "$pool" --arg n "$name" \
    '.pools[$p].members | any(. == $n)' \
    "$CC_AUTH_STATE_FILE" >/dev/null 2>&1
}

# ── Active pointer ────────────────────────────────────────────────────────────

# Get a pool's active account name (empty if unset).
pools_active() {
  local pool="$1"
  jq -r --arg p "$pool" '.pools[$p].active // ""' "$CC_AUTH_STATE_FILE" 2>/dev/null
}

# Set a pool's active account. Pass "" to clear.
# NOTE: does NOT touch keychain — callers that need keychain updates
# (i.e. _do_activate_in_pool when pool.writes_keychain=true) must do that.
# For the interactive pool, mirrors to legacy top-level .active_account so older
# code that reads state_active_account() keeps working.
pools_set_active() {
  local pool="$1" name="$2"
  pools_exists "$pool" || { log_error "Pool '$pool' does not exist"; return 1; }

  if [[ -z "$name" ]]; then
    json_edit "$CC_AUTH_STATE_FILE" --arg p "$pool" '.pools[$p].active = null'
  else
    local now
    now=$(now_iso)
    json_edit "$CC_AUTH_STATE_FILE" \
      --arg p "$pool" --arg n "$name" --arg now "$now" \
      '.pools[$p].active = $n | .accounts[$n].last_used = $now'
  fi

  if [[ "$pool" == "$POOLS_INTERACTIVE" ]]; then
    json_edit "$CC_AUTH_STATE_FILE" \
      --arg n "${name:-}" \
      '.active_account = (if $n == "" then null else $n end)'
  fi
}

# Returns 0 if pool's writes_keychain flag is true.
pools_writes_keychain() {
  local pool="$1"
  local wk
  wk=$(jq -r --arg p "$pool" '.pools[$p].writes_keychain // false' "$CC_AUTH_STATE_FILE" 2>/dev/null)
  [[ "$wk" == "true" ]]
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Pools containing this account, space-separated on stdout.
pools_for_account() {
  local name="$1"
  pools_migrate_if_needed
  jq -r --arg n "$name" \
    '[.pools | to_entries[] | select(.value.members | any(. == $n)) | .key] | join(" ")' \
    "$CC_AUTH_STATE_FILE" 2>/dev/null
}

# Decide which pool a bare `activate <name>` (no --pool) should target.
# Echos pool name on success, errors out if ambiguous or none.
pools_infer_for_account() {
  local name="$1"
  local pools
  pools=$(pools_for_account "$name")
  # Count tokens
  local -a parts=()
  read -r -a parts <<< "$pools"
  case "${#parts[@]}" in
    0)
      log_error "Account '$name' is not a member of any pool"
      log_dim "Hint: cc-auth pool add <pool> $name"
      return 1
      ;;
    1)
      echo "${parts[0]}"
      ;;
    *)
      log_error "Account '$name' is in multiple pools: $pools"
      log_dim "Specify which with --pool=<name>"
      return 1
      ;;
  esac
}
