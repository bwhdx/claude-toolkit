#!/usr/bin/env bash
# claude-toolkit shared event library — structured JSONL logging + process tracking
# Source this in any consumer for standardized event emission.

# Emit a structured event to a JSONL log file.
# Args: $1 = logs directory, $2 = event name, $3..N = key=value pairs
# Numeric values are stored as JSON numbers, everything else as strings.
# Example: emit_event "$logs" "account_cycled" "from=ops1" "to=ops2" "duration=12"
emit_event() {
  local logs_dir="$1" event_name="$2"
  shift 2

  mkdir -p "$logs_dir"

  local -a jq_args=(--arg ts "$(now_iso)" --arg event "$event_name")
  local jq_filter='{ts: $ts, event: $event'

  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    if [[ "$v" =~ ^-?[0-9]+\.?[0-9]*$ ]] && [[ "$v" != "" ]]; then
      jq_args+=(--argjson "$k" "$v")
    else
      jq_args+=(--arg "$k" "$v")
    fi
    jq_filter="$jq_filter, (\"$k\"): \$$k"
  done

  jq_filter="$jq_filter}"

  jq -c -n "${jq_args[@]}" "$jq_filter" >> "$logs_dir/events.jsonl"
}

# Read recent events from a JSONL log.
# Args: $1 = logs directory, $2 = number of events (default 20)
# Returns: JSON array on stdout
read_events() {
  local logs_dir="$1"
  local count="${2:-20}"
  local events_file="$logs_dir/events.jsonl"

  if [[ ! -f "$events_file" ]]; then
    echo "[]"
    return
  fi

  tail -n "$count" "$events_file" | jq -s '.'
}

# Track a running process with metadata.
# Creates a per-PID JSON file — no shared state, no races.
# Args: $1 = logs directory, $2 = PID, $3 = role, $4..N = key=value pairs
track_process() {
  local logs_dir="$1" pid="$2" role="$3"
  shift 3

  mkdir -p "$logs_dir"

  local -a jq_args=(
    --argjson pid "$pid"
    --arg role "$role"
    --arg started "$(now_iso)"
  )
  local jq_filter='{pid: $pid, role: $role, started: $started'

  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    jq_args+=(--arg "$k" "$v")
    jq_filter="$jq_filter, (\"$k\"): \$$k"
  done

  jq_filter="$jq_filter}"

  jq -n "${jq_args[@]}" "$jq_filter" > "$logs_dir/.process.${pid}.json"
}

# Remove process tracking file.
# Args: $1 = logs directory, $2 = PID
untrack_process() {
  local logs_dir="$1" pid="$2"
  rm -f "$logs_dir/.process.${pid}.json"
}

# Read all active tracked processes (validates PIDs are alive).
# Args: $1 = logs directory
# Returns: JSON array on stdout
read_active_processes() {
  local logs_dir="$1"
  local -a live=()

  for f in "$logs_dir"/.process.*.json; do
    [[ -f "$f" ]] || continue
    local pid
    pid=$(jq -r '.pid' "$f" 2>/dev/null) || continue
    if kill -0 "$pid" 2>/dev/null; then
      live+=("$(cat "$f")")
    else
      rm -f "$f"  # clean up dead process
    fi
  done

  if [[ ${#live[@]} -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "${live[@]}" | jq -s '.'
  fi
}
