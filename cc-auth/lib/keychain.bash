#!/usr/bin/env bash
# cc-auth keychain operations — read/write/swap Claude Code credentials in macOS Keychain

CC_KEYCHAIN_SERVICE="Claude Code-credentials"
CC_KEYCHAIN_ACCOUNT="$(whoami)"

# Read current Claude Code credentials from macOS Keychain
# Returns: JSON string (the credential blob) on stdout, or empty + exit 1
keychain_read() {
  if ! is_macos; then
    log_error "Keychain operations require macOS"
    return 1
  fi
  local cred
  cred=$(security find-generic-password \
    -s "$CC_KEYCHAIN_SERVICE" \
    -a "$CC_KEYCHAIN_ACCOUNT" \
    -w 2>/dev/null) || return 1
  [[ -n "$cred" ]] && echo "$cred" || return 1
}

# Write credentials to macOS Keychain (replaces existing entry)
# Args: $1 = JSON credential string
keychain_write() {
  local cred_json="$1"
  if ! is_macos; then
    log_error "Keychain operations require macOS"
    return 1
  fi
  if [[ -z "$cred_json" ]]; then
    log_error "Cannot write empty credentials to keychain"
    return 1
  fi

  # Delete existing entry (ignore if not found, suppress output)
  security delete-generic-password \
    -s "$CC_KEYCHAIN_SERVICE" \
    -a "$CC_KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true

  # Add new entry
  security add-generic-password \
    -s "$CC_KEYCHAIN_SERVICE" \
    -a "$CC_KEYCHAIN_ACCOUNT" \
    -w "$cred_json" 2>/dev/null
}

# Verify that Claude Code recognizes the current keychain credentials
# Returns: 0 if logged in, 1 if not
keychain_verify() {
  local status
  status=$(claude auth status 2>/dev/null) || return 1
  echo "$status" | jq -e '.loggedIn == true' >/dev/null 2>&1
}

# Verify the keychain holds a specific credential by comparing token prefixes
# Args: $1 = expected credential JSON (from vault)
# Returns: 0 if keychain token matches, 1 if mismatch
keychain_verify_token() {
  local expected_cred="$1"
  local expected_prefix actual_prefix
  expected_prefix=$(echo "$expected_cred" | jq -r '.claudeAiOauth.accessToken[:20]' 2>/dev/null)
  local actual_cred
  actual_cred=$(keychain_read) || return 1
  actual_prefix=$(echo "$actual_cred" | jq -r '.claudeAiOauth.accessToken[:20]' 2>/dev/null)
  [[ -n "$expected_prefix" && "$expected_prefix" == "$actual_prefix" ]]
}

# Get the email of the currently logged-in account
keychain_current_email() {
  claude auth status 2>/dev/null | jq -r '.email // empty'
}

# Get full auth status as JSON
keychain_auth_status() {
  claude auth status 2>/dev/null
}

# Extract subscription info from credential JSON
keychain_cred_info() {
  local cred_json="$1"
  echo "$cred_json" | jq '{
    subscriptionType: .claudeAiOauth.subscriptionType,
    rateLimitTier: .claudeAiOauth.rateLimitTier,
    expiresAt: .claudeAiOauth.expiresAt
  }' 2>/dev/null
}

# Check if a credential JSON has an expired access token
keychain_cred_expired() {
  local cred_json="$1"
  local expires_at now_ms
  expires_at=$(echo "$cred_json" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)
  now_ms=$(( $(now_epoch) * 1000 ))
  [[ "$expires_at" -lt "$now_ms" ]]
}
