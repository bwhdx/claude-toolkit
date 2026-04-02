#!/usr/bin/env bash
# cc-auth cycling logic — account selection, deterministic cycling, availability checks

# Cycle to the next available account.
# Strategy: if utilization data exists, pick lowest utilization.
# Otherwise, deterministic round-robin (next after current, wrapping around).
# Returns: 0 on success (new account activated), 1 if no accounts available
cycle_account() {
  if ! acquire_lock "$CC_AUTH_LOCK_DIR" 60; then
    log_error "Another cycle operation is in progress"
    return 1
  fi

  # Clear any expired limits first
  state_clear_expired

  local current
  current=$(state_active_account)

  # Build full account list
  local -a all_names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && all_names+=("$name")
  done < <(accounts_list_names)

  if [[ ${#all_names[@]} -lt 2 ]]; then
    log_error "Need at least 2 accounts to cycle (have ${#all_names[@]})"
    release_lock "$CC_AUTH_LOCK_DIR"
    return 1
  fi

  # Build candidates: not current, not limited
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
    log_error "All accounts are limited or failed to activate"
    release_lock "$CC_AUTH_LOCK_DIR"
    return 1
  fi

  # Deterministic round-robin: always pick the NEXT available account after current.
  # This guarantees every account gets used before any account is reused.
  # Utilization data is logged for visibility but doesn't affect order.
  local -a ordered=()
  local found_current=false
  # Start after current, wrap around
  for name in ${all_names[@]+"${all_names[@]}"}; do
    if [[ "$found_current" == "true" ]]; then
      for c in ${candidates[@]+"${candidates[@]}"}; do
        [[ "$c" == "$name" ]] && ordered+=("$name") && break
      done
    fi
    [[ "$name" == "$current" ]] && found_current=true
  done
  # Wrap around: accounts before current
  for name in ${all_names[@]+"${all_names[@]}"}; do
    [[ "$name" == "$current" ]] && break
    for c in ${candidates[@]+"${candidates[@]}"}; do
      [[ "$c" == "$name" ]] && ordered+=("$name") && break
    done
  done

  # Try each candidate in order
  for name in ${ordered[@]+"${ordered[@]}"}; do
    local util
    util=$(state_get_utilization "$name")
    if [[ "$util" != "999" ]]; then
      local pct
      pct=$(printf '%.0f' "$(echo "$util * 100" | bc 2>/dev/null || echo "?")")
      log_dim "$name — utilization ${pct}%"
    fi

    if _do_activate "$name"; then
      log_ok "Cycled: $current → $name"
      emit_event "$CC_AUTH_DIR" "account_cycled" "from=$current" "to=$name"
      release_lock "$CC_AUTH_LOCK_DIR"
      return 0
    else
      log_warn "Failed to activate $name, trying next..."
    fi
  done

  log_error "All accounts are limited or failed to activate"
  release_lock "$CC_AUTH_LOCK_DIR"
  return 1
}

# Activate a specific account by name
# Args: $1 = account name
activate_account() {
  local name="$1"

  if ! accounts_name_exists "$name"; then
    log_error "Unknown account: $name"
    return 1
  fi

  if ! acquire_lock "$CC_AUTH_LOCK_DIR" 60; then
    log_error "Another cycle operation is in progress"
    return 1
  fi

  _do_activate "$name"
  local rc=$?
  release_lock "$CC_AUTH_LOCK_DIR"
  return $rc
}

# Internal: perform the actual activation (swap keychain + verify)
# Caller must hold the cycle lock
_do_activate() {
  local name="$1"

  # Read credentials from vault
  local cred_json
  cred_json=$(vault_read "$name") || return 1

  # Check if token is expired
  if keychain_cred_expired "$cred_json"; then
    log_warn "Token for '$name' appears expired — attempting anyway (Claude Code may refresh it)"
  fi

  # Swap keychain entry
  keychain_write "$cred_json" || {
    log_error "Failed to write credentials for '$name' to keychain"
    return 1
  }

  # Verify the keychain now holds this account's token (token-level comparison)
  if keychain_verify_token "$cred_json"; then
    local email
    email=$(accounts_get "$name" | jq -r '.email // "?"')
    state_set_active "$name"
    accounts_touch_verified "$name"
    log_dim "Verified: $name ($email)"
    return 0
  else
    log_error "Keychain token mismatch after write for '$name'"
    return 1
  fi
}

# Check if any account is available (not limited)
# Returns: 0 if at least one is available, 1 if all limited
has_available_account() {
  state_clear_expired

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! state_is_limited "$name"; then
      return 0
    fi
  done < <(accounts_list_names)

  return 1
}

# Get the name of the currently active account
get_active_name() {
  state_active_account
}
