#!/usr/bin/env bash
# claude-toolkit Claude Code interaction layer
# Stream-JSON parsing, rate/subscription limit detection, auth queries.
# Source this in any consumer that spawns or interacts with Claude Code.

# ── Stream-JSON output parsing ────────────────────────────────────────────────

# Extract the final result JSON line from a Claude Code stream-json output file.
# The result line has "type":"result" and contains cost, duration, session info.
# Args: $1 = raw output file, $2 = destination file for extracted result
claude_extract_result() {
  local output_file="$1" result_file="$2"
  grep '"type":"result"' "$output_file" 2>/dev/null | tail -1 > "$result_file"
  if [[ ! -s "$result_file" ]]; then
    echo '{"type":"result","is_error":true,"result":"No result line found in stream output","total_cost_usd":0}' > "$result_file"
  fi
}

# Extract session ID from Claude Code stream-json output.
# Args: $1 = raw output file
# Returns: session ID on stdout, or empty
claude_extract_session_id() {
  local raw_file="${1:-}"
  [[ -n "$raw_file" && -f "$raw_file" ]] || return 0
  grep -o '"session_id":"[^"]*"' "$raw_file" 2>/dev/null | tail -1 | sed 's/"session_id":"//;s/"//'
}

# Extract total cost (USD) from an extracted result JSON file.
# Args: $1 = result JSON file (output of claude_extract_result)
# Returns: cost as number on stdout (0 if unavailable)
claude_extract_cost() {
  local result_file="${1:-}"
  [[ -n "$result_file" && -f "$result_file" ]] || { echo "0"; return; }
  jq -r '.total_cost_usd // 0' "$result_file" 2>/dev/null || echo "0"
}

# Extract duration (milliseconds) from an extracted result JSON file.
# Args: $1 = result JSON file (output of claude_extract_result)
# Returns: duration in ms on stdout (0 if unavailable)
claude_extract_duration() {
  local result_file="${1:-}"
  [[ -n "$result_file" && -f "$result_file" ]] || { echo "0"; return; }
  jq -r '.duration_ms // 0' "$result_file" 2>/dev/null || echo "0"
}

# Check if a result JSON indicates an error.
# Args: $1 = result JSON file (output of claude_extract_result)
# Returns: 0 if error, 1 if success
claude_is_error() {
  local result_file="${1:-}"
  [[ -n "$result_file" && -f "$result_file" ]] || return 0
  jq -e '.is_error == true' "$result_file" >/dev/null 2>&1
}

# Extract the result text/summary from a result JSON file.
# Args: $1 = result JSON file
# Returns: result text on stdout
claude_extract_result_text() {
  local result_file="${1:-}"
  [[ -n "$result_file" && -f "$result_file" ]] || { echo "No output"; return; }
  jq -r '.result // "No output"' "$result_file" 2>/dev/null || cat "$result_file"
}

# ── Rate limit detection ─────────────────────────────────────────────────────

# Check if Claude Code output contains a rate limit error (HTTP 429).
# Args: $1 = path to raw output file
# Returns: 0 if rate limited, 1 if not
claude_is_rate_limited() {
  local raw_file="$1"
  [[ -f "$raw_file" ]] || return 1
  grep -qE '"error":"rate_limit"|"error_status":429' "$raw_file" 2>/dev/null
}

# Extract wait time (seconds) from the last rate limit event in output.
# Scales up by 3x since Claude Code already exhausted its internal retries.
# Args: $1 = raw output file
# Returns: seconds on stdout
claude_rate_limit_wait() {
  local raw_file="$1"
  local default_cooldown="${2:-600}"
  local wait_ms
  wait_ms=$(grep '"error":"rate_limit"' "$raw_file" 2>/dev/null | tail -1 \
    | grep -o '"retry_delay_ms":[0-9]*' | grep -o '[0-9]*')
  if [[ -n "$wait_ms" && "$wait_ms" -gt 0 ]]; then
    echo $(( (wait_ms / 1000) * 3 ))
  else
    echo "$default_cooldown"
  fi
}

# ── Subscription limit detection ─────────────────────────────────────────────

# Check if Claude Code output indicates a subscription usage limit.
# Matches patterns like "You've hit your limit · resets 7am"
# Args: $1 = path to raw output file
# Returns: 0 if limited, 1 if not
claude_is_subscription_limited() {
  local raw_file="$1"
  [[ -f "$raw_file" ]] || return 1
  grep -qiE 'hit your limit|usage limit|resets [0-9]+[ap]m|rate limit exceeded|you.ve reached|limit has been reached' "$raw_file" 2>/dev/null
}

# Parse the subscription reset time from Claude Code output.
# Looks for "resets Xam" or "resets Xpm" and calculates seconds until that time.
# Args: $1 = path to raw output file
# Returns: seconds until reset on stdout (default 14400 = 4h if unparseable)
claude_subscription_reset_wait() {
  local raw_file="$1"
  [[ -f "$raw_file" ]] || { echo "14400"; return; }

  local reset_match
  reset_match=$(grep -oiE 'resets\s+[0-9]{1,2}\s*(am|pm)' "$raw_file" 2>/dev/null | head -1)

  if [[ -n "$reset_match" ]]; then
    local hour ampm
    hour=$(echo "$reset_match" | grep -oE '[0-9]+')
    ampm=$(echo "$reset_match" | grep -oiE '(am|pm)')

    # Convert to 24h
    [[ "${ampm,,}" == "pm" && "$hour" -ne 12 ]] && hour=$((hour + 12))
    [[ "${ampm,,}" == "am" && "$hour" -eq 12 ]] && hour=0

    # Calculate seconds until that time (local timezone)
    local now_epoch target_epoch
    now_epoch=$(now_epoch)
    if is_macos; then
      target_epoch=$(date -j -f "%H:%M:%S" "${hour}:00:00" "+%s" 2>/dev/null || echo 0)
    else
      target_epoch=$(date -d "today ${hour}:00:00" "+%s" 2>/dev/null || echo 0)
    fi

    if [[ "$target_epoch" -gt 0 ]]; then
      local wait_secs=$(( target_epoch - now_epoch ))
      [[ "$wait_secs" -le 0 ]] && wait_secs=$(( wait_secs + 86400 ))
      echo "$wait_secs"
      return
    fi
  fi

  # Default: 4 hours if we can't parse
  echo "14400"
}

# ── Auth failure detection ────────────────────────────────────────────────────

# Check if Claude Code output indicates an authentication failure.
# Args: $1 = path to raw output file
# Returns: 0 if auth failed, 1 if not
claude_is_auth_failure() {
  local raw_file="$1"
  [[ -f "$raw_file" ]] || return 1
  grep -qiE '"error":"authentication"|"error":"invalid_api_key"|"error":"unauthorized"|authentication.failed' "$raw_file" 2>/dev/null
}

# ── Rate limit cooldown (file-based global state) ────────────────────────────

# Set a global rate limit cooldown. Writes epoch timestamp to a file.
# Args: $1 = cooldown directory (e.g. $LOGS_DIR), $2 = wait seconds
claude_set_cooldown() {
  local cooldown_dir="$1" wait_secs="$2"
  local until_epoch=$(( $(now_epoch) + wait_secs ))
  mkdir -p "$cooldown_dir"
  local tmp
  tmp=$(mktemp "$cooldown_dir/.rate_limited_until.XXXXXX")
  echo "$until_epoch" > "$tmp"
  mv "$tmp" "$cooldown_dir/.rate_limited_until"
}

# Check if a global rate limit cooldown is active.
# Args: $1 = cooldown directory
# Returns: 0 if active (still limited), 1 if expired/not set
claude_is_cooldown_active() {
  local cooldown_file="$1/.rate_limited_until"
  [[ -f "$cooldown_file" ]] || return 1
  local until_epoch
  until_epoch=$(cat "$cooldown_file" 2>/dev/null || echo 0)
  local now
  now=$(now_epoch)
  if [[ "$now" -lt "$until_epoch" ]]; then
    return 0
  fi
  rm -f "$cooldown_file"
  return 1
}

# Get human-readable time remaining on cooldown.
# Args: $1 = cooldown directory
# Returns: string like "45s" or "2m" on stdout
claude_cooldown_remaining() {
  local cooldown_file="$1/.rate_limited_until"
  [[ -f "$cooldown_file" ]] || { echo "0s"; return; }
  local until_epoch
  until_epoch=$(cat "$cooldown_file" 2>/dev/null || echo 0)
  local now
  now=$(now_epoch)
  local remaining=$(( until_epoch - now ))
  [[ $remaining -lt 0 ]] && remaining=0
  echo "${remaining}s"
}

# ── Auth status queries ──────────────────────────────────────────────────────

# Get Claude Code auth status as JSON.
# Returns: JSON with loggedIn, email, subscriptionType, etc.
claude_auth_status() {
  claude auth status 2>/dev/null
}

# Get the email of the currently logged-in Claude Code account.
# Returns: email on stdout, or empty
claude_auth_email() {
  claude auth status 2>/dev/null | jq -r '.email // empty'
}

# ── Stream-JSON intelligence ─────────────────────────────────────────────────
# These functions parse Claude Code's --output-format stream-json output
# to extract rich operational data. Any consumer can use these.

# Parse rate limit info from stream output.
# Returns: JSON with utilization, reset time, overage status.
# Args: $1 = raw stream-json file
claude_parse_rate_limit_info() {
  local raw_file="${1:-}"
  [[ -n "$raw_file" && -f "$raw_file" ]] || { echo '{}'; return; }
  local info
  info=$(grep '"rate_limit_event"' "$raw_file" 2>/dev/null | tail -1 | jq -r '.rate_limit_info // empty' 2>/dev/null)
  if [[ -n "$info" ]]; then
    echo "$info" | jq '{
      utilization: .utilization,
      resets_at: .resetsAt,
      rate_limit_type: .rateLimitType,
      using_overage: (.isUsingOverage // false),
      status: .status,
      threshold: (.surpassedThreshold // null)
    }' 2>/dev/null
  else
    echo '{}'
  fi
}

# Parse tool use summary from stream output.
# Returns: JSON object with tool names as keys, counts as values.
# Args: $1 = raw stream-json file
claude_parse_tool_summary() {
  local raw_file="${1:-}"
  [[ -n "$raw_file" && -f "$raw_file" ]] || { echo '{}'; return; }
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' \
    "$raw_file" 2>/dev/null | sort | uniq -c | sort -rn | \
    awk 'BEGIN{printf "{"} NR>1{printf ","} {gsub(/"/,"",$2); printf "\"%s\":%d",$2,$1} END{printf "}"}' 2>/dev/null || echo '{}'
}

# Parse list of files touched (read, edited, or written) from stream output.
# Returns: JSON array of relative file paths (deduped).
# Args: $1 = raw stream-json file, $2 = optional repo root to strip
claude_parse_files_touched() {
  local raw_file="${1:-}" repo_root="${2:-}"
  [[ -n "$raw_file" && -f "$raw_file" ]] || { echo '[]'; return; }
  local files
  files=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") |
    select(.name == "Read" or .name == "Edit" or .name == "Write" or .name == "Grep" or .name == "Glob") |
    .input.file_path // .input.path // empty' "$raw_file" 2>/dev/null | sort -u)
  if [[ -n "$repo_root" ]]; then
    files=$(echo "$files" | sed "s|^${repo_root}/||")
  fi
  echo "$files" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]'
}

# Parse list of files modified (Edit or Write only) from stream output.
# Returns: JSON array of file paths (deduped).
# Args: $1 = raw stream-json file, $2 = optional repo root to strip
claude_parse_files_edited() {
  local raw_file="${1:-}" repo_root="${2:-}"
  [[ -n "$raw_file" && -f "$raw_file" ]] || { echo '[]'; return; }
  local files
  files=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") |
    select(.name == "Edit" or .name == "Write") |
    .input.file_path // empty' "$raw_file" 2>/dev/null | sort -u)
  if [[ -n "$repo_root" ]]; then
    files=$(echo "$files" | sed "s|^${repo_root}/||")
  fi
  echo "$files" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]'
}

# Parse session init metadata from stream output.
# Returns: JSON with model, version, session_id, tool count.
# Args: $1 = raw stream-json file
claude_parse_init_info() {
  local raw_file="${1:-}"
  [[ -n "$raw_file" && -f "$raw_file" ]] || { echo '{}'; return; }
  grep '"subtype":"init"' "$raw_file" 2>/dev/null | head -1 | jq '{
    model: .model,
    version: .claude_code_version,
    session_id: .session_id,
    cwd: .cwd,
    tools: (.tools // [] | length),
    mcp_servers: (.mcp_servers // [] | length)
  }' 2>/dev/null || echo '{}'
}
