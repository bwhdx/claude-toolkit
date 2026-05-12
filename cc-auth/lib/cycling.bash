#!/usr/bin/env bash
# cc-auth cycling — pool-aware account selection, activation, and round-robin
# rotation. All operations are scoped to a single pool; the legacy
# single-pool world is preserved via the "interactive" pool which is created
# automatically by pools_migrate_if_needed.

# Cycle to the next available account WITHIN a pool.
# Strategy: deterministic round-robin among pool members that aren't currently
# limited (and aren't the pool's current active). Returns 0 on success.
# Args: $1 = pool name (default: interactive)
cycle_pool() {
  local pool="${1:-$POOLS_INTERACTIVE}"
  pools_exists "$pool" || { log_error "Pool '$pool' does not exist"; return 1; }

  if ! acquire_lock "$CC_AUTH_LOCK_DIR" 60; then
    log_error "Another cycle operation is in progress"
    return 1
  fi

  state_clear_expired

  local current
  current=$(pools_active "$pool")

  # Pool members
  local -a all_names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && all_names+=("$name")
  done < <(pools_list_members "$pool")

  if [[ ${#all_names[@]} -lt 2 ]]; then
    log_error "Pool '$pool' needs at least 2 members to cycle (has ${#all_names[@]})"
    release_lock "$CC_AUTH_LOCK_DIR"
    return 1
  fi

  # Candidates: in pool, not current, not limited
  local -a candidates=()
  for name in ${all_names[@]+"${all_names[@]}"}; do
    [[ "$name" == "$current" ]] && continue
    if state_is_limited "$name"; then
      local remaining
      remaining=$(state_limit_remaining "$name")
      log_dim "$name — limited ($(format_duration "$remaining") remaining)"
      continue
    fi
    candidates+=("$name")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_error "All accounts in pool '$pool' are limited"
    release_lock "$CC_AUTH_LOCK_DIR"
    return 1
  fi

  # Deterministic round-robin: pick next available after current, wrap around.
  local -a ordered=()
  local found_current=false
  for name in ${all_names[@]+"${all_names[@]}"}; do
    if [[ "$found_current" == "true" ]]; then
      for c in ${candidates[@]+"${candidates[@]}"}; do
        [[ "$c" == "$name" ]] && ordered+=("$name") && break
      done
    fi
    [[ "$name" == "$current" ]] && found_current=true
  done
  for name in ${all_names[@]+"${all_names[@]}"}; do
    [[ "$name" == "$current" ]] && break
    for c in ${candidates[@]+"${candidates[@]}"}; do
      [[ "$c" == "$name" ]] && ordered+=("$name") && break
    done
  done

  for name in ${ordered[@]+"${ordered[@]}"}; do
    local util
    util=$(state_get_utilization "$name")
    if [[ "$util" != "999" ]]; then
      local pct
      pct=$(printf '%.0f' "$(echo "$util * 100" | bc 2>/dev/null || echo "?")")
      log_dim "$name — utilization ${pct}%"
    fi

    if _do_activate_in_pool "$pool" "$name"; then
      log_ok "Cycled in pool '$pool': $current → $name"
      emit_event "$CC_AUTH_DIR" "account_cycled" "pool=$pool" "from=$current" "to=$name"
      release_lock "$CC_AUTH_LOCK_DIR"
      return 0
    else
      log_warn "Failed to activate $name, trying next..."
    fi
  done

  log_error "All accounts in pool '$pool' failed to activate"
  release_lock "$CC_AUTH_LOCK_DIR"
  return 1
}

# Activate a specific account within a pool.
# Args: $1 = pool, $2 = account name
activate_in_pool() {
  local pool="$1" name="$2"
  pools_exists "$pool" || { log_error "Pool '$pool' does not exist"; return 1; }
  pools_is_member "$pool" "$name" || {
    log_error "Account '$name' is not a member of pool '$pool'"
    log_dim "Hint: cc-auth pool add $pool $name"
    return 1
  }
  if ! acquire_lock "$CC_AUTH_LOCK_DIR" 60; then
    log_error "Another cycle operation is in progress"
    return 1
  fi
  _do_activate_in_pool "$pool" "$name"
  local rc=$?
  release_lock "$CC_AUTH_LOCK_DIR"
  return $rc
}

# Internal: activate an account within a pool. Updates pool's active pointer;
# writes keychain only if pool.writes_keychain=true. Caller must hold cycle lock.
_do_activate_in_pool() {
  local pool="$1" name="$2"

  if pools_writes_keychain "$pool"; then
    # Interactive-style: swap keychain entry so Claude Code picks it up.
    local cred_json
    cred_json=$(vault_read "$name") || return 1

    if keychain_cred_expired "$cred_json"; then
      log_warn "Token for '$name' appears expired — attempting anyway (Claude Code may refresh it)"
    fi

    keychain_write "$cred_json" || {
      log_error "Failed to write credentials for '$name' to keychain"
      return 1
    }

    if ! keychain_verify_token "$cred_json"; then
      log_error "Keychain token mismatch after write for '$name'"
      return 1
    fi

    local email
    email=$(accounts_get "$name" | jq -r '.email // "?"')
    pools_set_active "$pool" "$name"
    accounts_touch_verified "$name"
    log_dim "Verified: $name ($email) in pool '$pool'"
    return 0
  else
    # Background-style: long-term tokens are read directly via vault_read_longterm
    # at get-token time; we just record the pointer. No keychain mutation.
    if ! vault_has_longterm "$name"; then
      log_warn "Account '$name' has no long-term token stored (use 'cc-auth setup-longterm $name <token>')"
      # Don't fail — fallback path uses OAuth access token from vault.
    fi
    pools_set_active "$pool" "$name"
    local email
    email=$(accounts_get "$name" | jq -r '.email // "?"')
    log_dim "Active in pool '$pool': $name ($email)"
    return 0
  fi
}

# Returns 0 if at least one account in the pool is not limited.
# Args: $1 = pool (default: interactive)
has_available_in_pool() {
  local pool="${1:-$POOLS_INTERACTIVE}"
  pools_exists "$pool" || return 1
  state_clear_expired
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    state_is_limited "$name" || return 0
  done < <(pools_list_members "$pool")
  return 1
}
