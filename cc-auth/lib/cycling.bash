#!/usr/bin/env bash
# cc-auth cycling logic — account selection, round-robin cycling, availability checks

# Cycle to the next available account (round-robin, skipping limited accounts)
# Returns: 0 on success (new account activated), 1 if no accounts available
cycle_account() {
  # Acquire cycle lock to prevent concurrent swaps
  if ! acquire_lock "$CC_AUTH_LOCK_DIR" 60; then
    log_error "Another cycle operation is in progress"
    return 1
  fi
  trap 'release_lock "$CC_AUTH_LOCK_DIR"' RETURN

  # Clear any expired limits first
  state_clear_expired

  local current
  current=$(state_active_account)

  # Build ordered list: accounts after current, then wrap around
  local -a all_names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && all_names+=("$name")
  done < <(accounts_list_names)

  if [[ ${#all_names[@]} -lt 2 ]]; then
    log_error "Need at least 2 accounts to cycle (have ${#all_names[@]})"
    return 1
  fi

  # Find current index and build rotation starting after it
  local -a candidates=()
  local found_current=false
  for name in "${all_names[@]}"; do
    if [[ "$found_current" == "true" ]]; then
      candidates+=("$name")
    fi
    if [[ "$name" == "$current" ]]; then
      found_current=true
    fi
  done
  # Wrap around: add accounts before (and including) current
  for name in "${all_names[@]}"; do
    [[ "$name" == "$current" ]] && break
    candidates+=("$name")
  done

  # Try each candidate, skip limited ones
  for name in "${candidates[@]}"; do
    if state_is_limited "$name"; then
      local remaining
      remaining=$(state_limit_remaining "$name")
      log_dim "$name — limited ($(format_duration "$remaining") remaining)"
      continue
    fi

    # Try to activate this account
    if _do_activate "$name"; then
      log_ok "Cycled: $current → $name"
      emit_event "$CC_AUTH_DIR" "account_cycled" "from=$current" "to=$name"
      return 0
    else
      log_warn "Failed to activate $name, trying next..."
    fi
  done

  log_error "All accounts are limited or failed to activate"
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

  # Acquire cycle lock
  if ! acquire_lock "$CC_AUTH_LOCK_DIR" 60; then
    log_error "Another cycle operation is in progress"
    return 1
  fi
  trap 'release_lock "$CC_AUTH_LOCK_DIR"' RETURN

  _do_activate "$name"
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

# Get the next account that would be cycled to (without actually cycling)
get_next_available() {
  state_clear_expired
  local current
  current=$(state_active_account)

  local -a all_names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && all_names+=("$name")
  done < <(accounts_list_names)

  local found_current=false
  for name in "${all_names[@]}"; do
    if [[ "$found_current" == "true" ]] && ! state_is_limited "$name"; then
      echo "$name"
      return 0
    fi
    [[ "$name" == "$current" ]] && found_current=true
  done
  # Wrap around
  for name in "${all_names[@]}"; do
    [[ "$name" == "$current" ]] && return 1
    if ! state_is_limited "$name"; then
      echo "$name"
      return 0
    fi
  done
  return 1
}
