#!/usr/bin/env bash
# cc-jobs launchd operations — plist parsing, launchctl queries

# Convention: toolkit jobs match these plist name patterns
TOOLKIT_PLIST_PATTERNS=("com.ax.*" "com.claude-toolkit.*")
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"

# Scan ~/Library/LaunchAgents for toolkit-related plists
# Returns: newline-separated list of plist file paths
scan_toolkit_plists() {
  local pattern
  for pattern in "${TOOLKIT_PLIST_PATTERNS[@]}"; do
    # shellcheck disable=SC2086
    for f in "$LAUNCHAGENTS_DIR"/${pattern}.plist; do
      [[ -f "$f" ]] && echo "$f"
    done
  done | sort -u
}

# Extract fields from a plist file using plutil
# Args: $1 = plist path
# Returns: JSON object with parsed fields on stdout
parse_plist() {
  local plist="$1"
  [[ -f "$plist" ]] || return 1

  local label="" interval=0 stdout_log="" stderr_log=""
  local -a command=()

  # Label
  label=$(plutil -extract Label raw -o - "$plist" 2>/dev/null || echo "")

  # ProgramArguments → command array
  local prog_json
  prog_json=$(plutil -extract ProgramArguments json -o - "$plist" 2>/dev/null || echo "[]")

  # StartInterval
  interval=$(plutil -extract StartInterval raw -o - "$plist" 2>/dev/null || echo "0")

  # Log paths
  stdout_log=$(plutil -extract StandardOutPath raw -o - "$plist" 2>/dev/null || echo "")
  stderr_log=$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null || echo "")

  # Build JSON
  jq -n \
    --arg label "$label" \
    --argjson command "$prog_json" \
    --argjson interval "$interval" \
    --arg plist_path "$plist" \
    --arg log_stdout "$stdout_log" \
    --arg log_stderr "$stderr_log" \
    '{
      label: $label,
      command: $command,
      interval_seconds: $interval,
      plist_path: $plist_path,
      log_stdout: $log_stdout,
      log_stderr: $log_stderr
    }'
}

# Query launchctl for a job's runtime state
# Args: $1 = job label
# Returns: JSON with pid, last_exit_code, status on stdout
query_launchctl() {
  local label="$1"

  # launchctl list output format: PID	Status	Label
  local line
  line=$(launchctl list 2>/dev/null | grep -F "$label" || true)

  if [[ -z "$line" ]]; then
    jq -n '{status: "not loaded", pid: null, last_exit_code: null}'
    return
  fi

  local pid exit_code
  pid=$(echo "$line" | awk '{print $1}')
  exit_code=$(echo "$line" | awk '{print $2}')

  local status="loaded"
  [[ "$pid" != "-" && -n "$pid" ]] && status="running"

  [[ "$pid" == "-" ]] && pid="null" || pid="$pid"
  [[ "$exit_code" == "-" ]] && exit_code="null"

  jq -n \
    --arg status "$status" \
    --argjson pid "$pid" \
    --argjson exit_code "${exit_code:-null}" \
    '{status: $status, pid: $pid, last_exit_code: $exit_code}'
}

# Query launchctl print for detailed metrics
# Args: $1 = job label
# Returns: JSON with runs count, state on stdout
query_launchctl_detail() {
  local label="$1"
  local uid
  uid=$(id -u)

  local detail
  detail=$(launchctl print "gui/$uid/$label" 2>/dev/null || true)

  if [[ -z "$detail" ]]; then
    jq -n '{runs: null, state: "unknown"}'
    return
  fi

  local runs state
  runs=$(echo "$detail" | grep -E '^\s*runs\s*=' | head -1 | awk '{print $3}' || echo "null")
  state=$(echo "$detail" | grep -E '^\s*state\s*=' | head -1 | awk '{print $3}' || echo "unknown")

  [[ -z "$runs" || "$runs" == "" ]] && runs="null"

  jq -n \
    --argjson runs "${runs}" \
    --arg state "${state:-unknown}" \
    '{runs: $runs, state: $state}'
}

# Get the last modification time of a log file as a proxy for "last run"
# Args: $1 = log file path
# Returns: epoch seconds, or empty
log_last_modified() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  stat -f %m "$log_file" 2>/dev/null
}

# Build a complete job info JSON by combining plist + launchctl data
# Args: $1 = plist path
# Returns: merged JSON on stdout
build_job_info() {
  local plist="$1"

  local plist_info runtime_info detail_info
  plist_info=$(parse_plist "$plist") || return 1
  local label
  label=$(echo "$plist_info" | jq -r '.label')

  runtime_info=$(query_launchctl "$label")
  detail_info=$(query_launchctl_detail "$label")

  # Determine last run from log file mtime
  local log_file last_run_epoch
  log_file=$(echo "$plist_info" | jq -r '.log_stdout // .log_stderr // empty')
  last_run_epoch=""
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    last_run_epoch=$(log_last_modified "$log_file")
  fi

  # Merge all info
  echo "$plist_info" "$runtime_info" "$detail_info" | jq -s '
    .[0] + .[1] + .[2]
  ' | jq \
    --argjson last_run "${last_run_epoch:-null}" \
    '. + {last_run_epoch: $last_run}'
}

# Scan crontab for toolkit-related entries
# Returns: JSON array of cron entries
scan_crontab() {
  local cron_output
  cron_output=$(crontab -l 2>/dev/null || true)

  if [[ -z "$cron_output" ]]; then
    echo "[]"
    return
  fi

  local entries="[]"
  while IFS= read -r line; do
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    # Check if line references toolkit tools
    if echo "$line" | grep -qE 'cc-|ax |claude-toolkit'; then
      entries=$(echo "$entries" | jq --arg line "$line" '. + [{type: "cron", entry: $line}]')
    fi
  done <<< "$cron_output"

  echo "$entries"
}
