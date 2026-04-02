#!/usr/bin/env bash
# cc-auth vault operations — encrypted storage for multiple account credentials

CC_AUTH_DIR="${CC_AUTH_DIR:-$HOME/.cc-auth}"
CC_AUTH_VAULT_DIR="$CC_AUTH_DIR/vault"
CC_AUTH_VAULT_KEY="$CC_AUTH_DIR/vault.key"
CC_AUTH_ACCOUNTS_FILE="$CC_AUTH_DIR/accounts.json"
CC_AUTH_STATE_FILE="$CC_AUTH_DIR/state.json"
CC_AUTH_LOCK_DIR="$CC_AUTH_DIR/.cycle.lock"

# Initialize the vault directory structure and encryption key
vault_init() {
  if [[ -d "$CC_AUTH_DIR" ]] && [[ -f "$CC_AUTH_VAULT_KEY" ]]; then
    log_warn "Vault already initialized at $CC_AUTH_DIR"
    return 0
  fi

  log_info "Initializing cc-auth vault at $CC_AUTH_DIR"

  mkdir -p "$CC_AUTH_DIR" "$CC_AUTH_VAULT_DIR"
  chmod 700 "$CC_AUTH_DIR" "$CC_AUTH_VAULT_DIR"

  # Generate encryption key
  if [[ ! -f "$CC_AUTH_VAULT_KEY" ]]; then
    openssl rand -base64 32 > "$CC_AUTH_VAULT_KEY"
    chmod 400 "$CC_AUTH_VAULT_KEY"
  fi

  # Initialize accounts registry
  if [[ ! -f "$CC_AUTH_ACCOUNTS_FILE" ]]; then
    json_write "$CC_AUTH_ACCOUNTS_FILE" '{"accounts":[]}'
  fi

  # Initialize state
  if [[ ! -f "$CC_AUTH_STATE_FILE" ]]; then
    json_write "$CC_AUTH_STATE_FILE" '{"active_account":null,"accounts":{}}'
  fi

  log_ok "Vault initialized"
}

# Check if vault is initialized
vault_is_initialized() {
  [[ -d "$CC_AUTH_DIR" ]] && [[ -f "$CC_AUTH_VAULT_KEY" ]] && [[ -f "$CC_AUTH_ACCOUNTS_FILE" ]]
}

# Encrypt and store a credential JSON blob
# Args: $1 = account name, $2 = credential JSON
vault_write() {
  local name="$1" cred_json="$2"
  local enc_file="$CC_AUTH_VAULT_DIR/${name}.enc"

  echo "$cred_json" | openssl enc -aes-256-cbc -salt -pbkdf2 \
    -pass "file:$CC_AUTH_VAULT_KEY" \
    -out "$enc_file" 2>/dev/null || {
    log_error "Failed to encrypt credentials for '$name'"
    return 1
  }
  chmod 600 "$enc_file"
}

# Decrypt and read a credential JSON blob
# Args: $1 = account name
# Returns: JSON on stdout
vault_read() {
  local name="$1"
  local enc_file="$CC_AUTH_VAULT_DIR/${name}.enc"

  if [[ ! -f "$enc_file" ]]; then
    log_error "No vault entry for '$name'"
    return 1
  fi

  openssl enc -d -aes-256-cbc -pbkdf2 \
    -pass "file:$CC_AUTH_VAULT_KEY" \
    -in "$enc_file" 2>/dev/null || {
    log_error "Failed to decrypt credentials for '$name'"
    return 1
  }
}

# Delete a vault entry
# Args: $1 = account name
vault_delete() {
  local name="$1"
  local enc_file="$CC_AUTH_VAULT_DIR/${name}.enc"
  rm -f "$enc_file"
}

# Check if a vault entry exists
# Args: $1 = account name
vault_exists() {
  local name="$1"
  [[ -f "$CC_AUTH_VAULT_DIR/${name}.enc" ]]
}

# ── Accounts registry ─────────────────────────────────────────────────────────

# Add an account to the registry
# Args: $1 = name, $2 = email, $3 = subscriptionType, $4 = rateLimitTier
accounts_add() {
  local name="$1" email="$2" sub_type="${3:-}" rate_tier="${4:-}"
  local now
  now=$(now_iso)

  json_edit "$CC_AUTH_ACCOUNTS_FILE" \
    --arg name "$name" \
    --arg email "$email" \
    --arg sub "$sub_type" \
    --arg tier "$rate_tier" \
    --arg now "$now" \
    '.accounts += [{
      name: $name,
      email: $email,
      subscriptionType: $sub,
      rateLimitTier: $tier,
      added_at: $now,
      last_verified: $now
    }]'
}

# Remove an account from the registry
# Args: $1 = name
accounts_remove() {
  local name="$1"
  json_edit "$CC_AUTH_ACCOUNTS_FILE" \
    --arg name "$name" \
    '.accounts |= map(select(.name != $name))'
}

# Get an account from the registry (JSON)
# Args: $1 = name
accounts_get() {
  local name="$1"
  jq -e --arg name "$name" '.accounts[] | select(.name == $name)' \
    "$CC_AUTH_ACCOUNTS_FILE" 2>/dev/null
}

# List all account names
accounts_list_names() {
  jq -r '.accounts[].name' "$CC_AUTH_ACCOUNTS_FILE" 2>/dev/null
}

# Get count of accounts
accounts_count() {
  jq '.accounts | length' "$CC_AUTH_ACCOUNTS_FILE" 2>/dev/null
}

# Check if an account name exists in the registry
accounts_name_exists() {
  local name="$1"
  jq -e --arg name "$name" '.accounts[] | select(.name == $name)' \
    "$CC_AUTH_ACCOUNTS_FILE" >/dev/null 2>&1
}

# Update last_verified for an account
accounts_touch_verified() {
  local name="$1"
  local now
  now=$(now_iso)
  json_edit "$CC_AUTH_ACCOUNTS_FILE" \
    --arg name "$name" \
    --arg now "$now" \
    '(.accounts[] | select(.name == $name)).last_verified = $now'
}

# ── State management ──────────────────────────────────────────────────────────

# Get the active account name
state_active_account() {
  jq -r '.active_account // empty' "$CC_AUTH_STATE_FILE" 2>/dev/null
}

# Set the active account
state_set_active() {
  local name="$1"
  local now
  now=$(now_iso)
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg name "$name" \
    --arg now "$now" \
    '.active_account = $name | .accounts[$name].last_used = $now'
}

# Mark an account as subscription-limited
# Args: $1 = name, $2 = seconds until reset
state_mark_limited() {
  local name="$1" wait_secs="$2"
  local until_epoch
  until_epoch=$(( $(now_epoch) + wait_secs ))
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg name "$name" \
    --argjson until "$until_epoch" \
    '.accounts[$name].limited_until = $until'
}

# Check if an account is currently limited
# Args: $1 = name
# Returns: 0 if limited, 1 if available
state_is_limited() {
  local name="$1"
  local until_epoch now
  until_epoch=$(jq -r --arg name "$name" '.accounts[$name].limited_until // 0' "$CC_AUTH_STATE_FILE" 2>/dev/null)
  [[ "$until_epoch" == "null" || "$until_epoch" == "0" ]] && return 1
  now=$(now_epoch)
  [[ "$until_epoch" -gt "$now" ]]
}

# Get seconds remaining on a limit
# Args: $1 = name
state_limit_remaining() {
  local name="$1"
  local until_epoch now
  until_epoch=$(jq -r --arg name "$name" '.accounts[$name].limited_until // 0' "$CC_AUTH_STATE_FILE" 2>/dev/null)
  [[ "$until_epoch" == "null" || "$until_epoch" == "0" ]] && echo 0 && return
  now=$(now_epoch)
  local remaining=$(( until_epoch - now ))
  [[ "$remaining" -lt 0 ]] && remaining=0
  echo "$remaining"
}

# Clear expired limits from state
state_clear_expired() {
  local now
  now=$(now_epoch)
  json_edit "$CC_AUTH_STATE_FILE" \
    --argjson now "$now" \
    '.accounts |= with_entries(
      if (.value.limited_until // 0) <= $now and (.value.limited_until // 0) > 0
      then .value.limited_until = null | .value.utilization = null | .value.resets_at = null | .value.using_overage = null
      else . end
    )'
}

# Initialize state entry for an account (idempotent)
state_init_account() {
  local name="$1"
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg name "$name" \
    'if .accounts[$name] then . else .accounts[$name] = {limited_until: null, last_used: null, utilization: null, utilization_updated: null} end'
}

# Update rate limit utilization for an account (from stream-json rate_limit_event).
# Args: $1 = name, $2 = utilization (0.0-1.0), $3 = resets_at (epoch), $4 = using_overage (true/false)
state_update_utilization() {
  local name="$1" util="$2" resets="${3:-0}" overage="${4:-false}"
  json_edit "$CC_AUTH_STATE_FILE" \
    --arg name "$name" \
    --argjson util "$util" \
    --argjson resets "$resets" \
    --argjson overage "$overage" \
    --arg updated "$(now_iso)" \
    '.accounts[$name].utilization = $util |
     .accounts[$name].resets_at = $resets |
     .accounts[$name].using_overage = $overage |
     .accounts[$name].utilization_updated = $updated'
}

# Get utilization for an account (0.0-1.0, or 999 if unknown).
state_get_utilization() {
  local name="$1"
  local util
  util=$(jq -r --arg name "$name" '.accounts[$name].utilization // empty' "$CC_AUTH_STATE_FILE" 2>/dev/null)
  if [[ -n "$util" && "$util" != "null" ]]; then
    echo "$util"
  else
    echo "999"  # unknown = highest priority to avoid
  fi
}
