#!/usr/bin/env bash
# claude-toolkit shared scheduler — unified launchd/cron job management
# Source this in any consumer for standardized scheduled job install/remove/status.

SCHEDULER_AGENTS_DIR="$HOME/Library/LaunchAgents"

# Install a scheduled job.
# Args: label --interval SECS --command CMD [--log PATH] [--log-stderr PATH]
# Example: scheduler_install "com.claude-toolkit.my-tool" --interval 300 --command "/usr/local/bin/my-tool run" --log "/tmp/my-tool.log"
scheduler_install() {
  local label="$1"; shift

  local interval="" command="" log_stdout="" log_stderr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval)    interval="$2"; shift 2 ;;
      --command)     command="$2"; shift 2 ;;
      --log)         log_stdout="$2"; shift 2 ;;
      --log-stderr)  log_stderr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$label" || -z "$interval" || -z "$command" ]]; then
    log_error "scheduler_install requires: label --interval SECS --command CMD"
    return 1
  fi

  if is_macos; then
    _scheduler_install_launchd "$label" "$interval" "$command" "$log_stdout" "$log_stderr"
  else
    _scheduler_install_cron "$label" "$interval" "$command"
  fi
}

# Remove a scheduled job.
# Args: $1 = label
scheduler_uninstall() {
  local label="$1"

  if is_macos; then
    _scheduler_uninstall_launchd "$label"
  else
    _scheduler_uninstall_cron "$label"
  fi
}

# Show status of a scheduled job (JSON on stdout).
# Args: $1 = label
scheduler_status() {
  local label="$1"

  if is_macos; then
    _scheduler_status_launchd "$label"
  else
    _scheduler_status_cron "$label"
  fi
}

# ── macOS (launchd) implementation ────────────────────────────────────────────

_scheduler_install_launchd() {
  local label="$1" interval="$2" command="$3" log_stdout="$4" log_stderr="$5"
  local plist="$SCHEDULER_AGENTS_DIR/${label}.plist"

  mkdir -p "$SCHEDULER_AGENTS_DIR"

  # Split command into array for ProgramArguments
  local -a cmd_parts
  read -ra cmd_parts <<< "$command"

  # Build plist
  local prog_args=""
  for part in "${cmd_parts[@]}"; do
    prog_args+="        <string>${part}</string>
"
  done

  local log_entries=""
  if [[ -n "$log_stdout" ]]; then
    log_entries+="    <key>StandardOutPath</key>
    <string>${log_stdout}</string>
"
  fi
  if [[ -n "$log_stderr" ]]; then
    log_entries+="    <key>StandardErrorPath</key>
    <string>${log_stderr}</string>
"
  elif [[ -n "$log_stdout" ]]; then
    # Default stderr to same as stdout
    log_entries+="    <key>StandardErrorPath</key>
    <string>${log_stdout}</string>
"
  fi

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
${prog_args}    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
${log_entries}    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  log_ok "Scheduled $label (every $(format_duration "$interval"))"
  log_dim "Plist: $plist"
}

_scheduler_uninstall_launchd() {
  local label="$1"
  local plist="$SCHEDULER_AGENTS_DIR/${label}.plist"

  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    log_ok "Removed $label"
  else
    log_warn "No plist found for $label"
  fi
}

_scheduler_status_launchd() {
  local label="$1"
  local plist="$SCHEDULER_AGENTS_DIR/${label}.plist"

  local status="not installed"
  local pid="null" exit_code="null" interval="null"
  local log_stdout="" log_stderr=""

  if [[ -f "$plist" ]]; then
    # Extract config from plist
    interval=$(plutil -extract StartInterval raw -o - "$plist" 2>/dev/null || echo "null")
    log_stdout=$(plutil -extract StandardOutPath raw -o - "$plist" 2>/dev/null || echo "")
    log_stderr=$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null || echo "")

    # Query runtime state
    local line
    line=$(launchctl list 2>/dev/null | grep -F "$label" || true)
    if [[ -n "$line" ]]; then
      pid=$(echo "$line" | awk '{print $1}')
      exit_code=$(echo "$line" | awk '{print $2}')
      [[ "$pid" == "-" ]] && pid="null"
      [[ "$exit_code" == "-" ]] && exit_code="null"
      status="loaded"
      [[ "$pid" != "null" ]] && status="running"
    else
      status="installed (not loaded)"
    fi
  fi

  jq -n \
    --arg label "$label" \
    --arg status "$status" \
    --argjson interval "${interval:-null}" \
    --argjson pid "$pid" \
    --argjson exit_code "$exit_code" \
    --arg plist "$plist" \
    --arg log_stdout "$log_stdout" \
    --arg log_stderr "$log_stderr" \
    '{
      label: $label,
      status: $status,
      interval_seconds: $interval,
      pid: $pid,
      last_exit_code: $exit_code,
      plist_path: $plist,
      log_stdout: $log_stdout,
      log_stderr: $log_stderr
    }'
}

# ── Linux (cron) implementation — stubs ───────────────────────────────────────

_scheduler_install_cron() {
  local label="$1" interval="$2" command="$3"
  local interval_min=$(( interval / 60 ))
  [[ "$interval_min" -lt 1 ]] && interval_min=1

  # Add cron entry with label comment
  local cron_line="*/${interval_min} * * * * ${command} # ${label}"
  (crontab -l 2>/dev/null | grep -v "# ${label}"; echo "$cron_line") | crontab -
  log_ok "Scheduled $label via cron (every ${interval_min}m)"
}

_scheduler_uninstall_cron() {
  local label="$1"
  crontab -l 2>/dev/null | grep -v "# ${label}" | crontab -
  log_ok "Removed $label from crontab"
}

_scheduler_status_cron() {
  local label="$1"
  local entry
  entry=$(crontab -l 2>/dev/null | grep "# ${label}" || true)

  local status="not installed"
  [[ -n "$entry" ]] && status="active"

  jq -n \
    --arg label "$label" \
    --arg status "$status" \
    --arg entry "$entry" \
    '{label: $label, status: $status, cron_entry: $entry}'
}
