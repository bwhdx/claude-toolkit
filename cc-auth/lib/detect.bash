#!/usr/bin/env bash
# cc-auth limit detection — detect rate/subscription limits from Claude Code output

# Patterns that indicate a subscription limit hit
SUBSCRIPTION_LIMIT_PATTERNS=(
  "hit your limit"
  "usage limit"
  "resets 7am"
  "resets 2pm"
  "resets at"
  "rate limit exceeded"
  "you've reached"
  "limit has been reached"
)

# Check if a Claude Code output file indicates a subscription limit
# Args: $1 = path to output file (raw stream-json or text)
# Returns: 0 if limited, 1 if not
detect_subscription_limit() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  local pattern
  for pattern in "${SUBSCRIPTION_LIMIT_PATTERNS[@]}"; do
    if grep -qi "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Check if a Claude Code output file indicates a rate limit (429)
# Args: $1 = path to output file
# Returns: 0 if rate limited, 1 if not
detect_rate_limit() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qE '"error":"rate_limit"|"error_status":429' "$file" 2>/dev/null
}

# Check if a Claude Code output file indicates an auth failure
# Args: $1 = path to output file
# Returns: 0 if auth failed, 1 if not
detect_auth_failure() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qiE '"error":"authentication"|"error":"invalid_api_key"|"error":"unauthorized"|authentication.failed' "$file" 2>/dev/null
}

# Parse the reset time from a subscription limit message
# Args: $1 = path to output file
# Returns: seconds until reset on stdout, or empty if can't parse
parse_reset_wait() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  # Look for "resets Xam" or "resets Xpm" patterns
  local reset_match
  reset_match=$(grep -oiE 'resets\s+[0-9]{1,2}\s*(am|pm)' "$file" 2>/dev/null | head -1)

  if [[ -n "$reset_match" ]]; then
    local hour ampm
    hour=$(echo "$reset_match" | grep -oE '[0-9]+')
    ampm=$(echo "$reset_match" | grep -oiE '(am|pm)')

    # Convert to 24h
    if [[ "${ampm,,}" == "pm" && "$hour" -ne 12 ]]; then
      hour=$(( hour + 12 ))
    elif [[ "${ampm,,}" == "am" && "$hour" -eq 12 ]]; then
      hour=0
    fi

    # Calculate seconds until that time
    local now_epoch_val target_epoch
    now_epoch_val=$(now_epoch)

    if is_macos; then
      # Get today's date with the target hour
      local today
      today=$(date +%Y-%m-%d)
      target_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "${today} ${hour}:00:00" +%s 2>/dev/null)
    else
      local today
      today=$(date +%Y-%m-%d)
      target_epoch=$(date -d "${today} ${hour}:00:00" +%s 2>/dev/null)
    fi

    if [[ -n "$target_epoch" ]]; then
      local wait_secs=$(( target_epoch - now_epoch_val ))
      # If target is in the past, add 24 hours
      [[ "$wait_secs" -lt 0 ]] && wait_secs=$(( wait_secs + 86400 ))
      echo "$wait_secs"
      return 0
    fi
  fi

  # Default: 4 hours if we can't parse
  echo "14400"
}
