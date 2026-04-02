#!/usr/bin/env bash
# claude-toolkit shared scheduler — unified launchd/systemd/cron job management
# Source this in any consumer for standardized scheduled job install/remove/status.
#
# Supports: macOS (launchd), Linux (systemd timer → cron fallback)
# Features: environment variables, log paths, persistent timers

SCHEDULER_AGENTS_DIR="$HOME/Library/LaunchAgents"
SCHEDULER_SYSTEMD_DIR="$HOME/.config/systemd/user"

# Install a scheduled job (auto-detects platform).
# Args: label --interval SECS --command CMD [--log PATH] [--log-stderr PATH] [--env KEY=VALUE ...]
# Example:
#   scheduler_install "com.ax.dispatch" \
#     --interval 300 \
#     --command "/path/to/ax dispatch --foreground" \
#     --log "/path/to/log" \
#     --env "PATH=/usr/local/bin:/usr/bin:/bin"
scheduler_install() {
  local label="$1"; shift

  local interval="" command="" log_stdout="" log_stderr=""
  local -a env_vars=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval)    interval="$2"; shift 2 ;;
      --command)     command="$2"; shift 2 ;;
      --log)         log_stdout="$2"; shift 2 ;;
      --log-stderr)  log_stderr="$2"; shift 2 ;;
      --env)         env_vars+=("$2"); shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$label" || -z "$interval" || -z "$command" ]]; then
    log_error "scheduler_install requires: label --interval SECS --command CMD"
    return 1
  fi

  if is_macos; then
    _scheduler_install_launchd "$label" "$interval" "$command" "$log_stdout" "$log_stderr" "${env_vars[@]+"${env_vars[@]}"}"
  elif command -v systemctl >/dev/null 2>&1; then
    _scheduler_install_systemd "$label" "$interval" "$command" "$log_stdout" "${env_vars[@]+"${env_vars[@]}"}"
  else
    _scheduler_install_cron "$label" "$interval" "$command" "${env_vars[@]+"${env_vars[@]}"}"
  fi
}

# Remove a scheduled job.
# Args: $1 = label
scheduler_uninstall() {
  local label="$1"

  if is_macos; then
    _scheduler_uninstall_launchd "$label"
  elif [[ -f "$SCHEDULER_SYSTEMD_DIR/${label}.timer" ]]; then
    _scheduler_uninstall_systemd "$label"
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
  elif [[ -f "$SCHEDULER_SYSTEMD_DIR/${label}.timer" ]]; then
    _scheduler_status_systemd "$label"
  else
    _scheduler_status_cron "$label"
  fi
}

# ── macOS (launchd) implementation ────────────────────────────────────────────

_scheduler_install_launchd() {
  local label="$1" interval="$2" command="$3" log_stdout="$4" log_stderr="$5"
  shift 5
  local -a env_vars=("$@")
  local plist="$SCHEDULER_AGENTS_DIR/${label}.plist"

  mkdir -p "$SCHEDULER_AGENTS_DIR"

  # Split command into array for ProgramArguments
  local -a cmd_parts
  read -ra cmd_parts <<< "$command"

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
    log_entries+="    <key>StandardErrorPath</key>
    <string>${log_stdout}</string>
"
  fi

  # Build EnvironmentVariables block
  local env_block=""
  if [[ ${#env_vars[@]} -gt 0 ]]; then
    env_block="    <key>EnvironmentVariables</key>
    <dict>
"
    for ev in "${env_vars[@]}"; do
      local key="${ev%%=*}" val="${ev#*=}"
      env_block+="        <key>${key}</key>
        <string>${val}</string>
"
    done
    env_block+="    </dict>
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
${log_entries}${env_block}    <key>AbandonProcessGroup</key>
    <true/>
    <key>RunAtLoad</key>
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
    interval=$(plutil -extract StartInterval raw -o - "$plist" 2>/dev/null || echo "null")
    log_stdout=$(plutil -extract StandardOutPath raw -o - "$plist" 2>/dev/null || echo "")
    log_stderr=$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null || echo "")

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

# ── Linux (systemd) implementation ────────────────────────────────────────────

_scheduler_install_systemd() {
  local label="$1" interval="$2" command="$3" log_stdout="$4"
  shift 4
  local -a env_vars=("$@")

  mkdir -p "$SCHEDULER_SYSTEMD_DIR"

  # Build Environment lines
  local env_lines=""
  for ev in "${env_vars[@]+"${env_vars[@]}"}"; do
    env_lines+="Environment=${ev}
"
  done

  # Service unit
  cat > "$SCHEDULER_SYSTEMD_DIR/${label}.service" <<SEOF
[Unit]
Description=${label}

[Service]
Type=oneshot
ExecStart=${command}
${env_lines}
SEOF

  # Timer unit
  cat > "$SCHEDULER_SYSTEMD_DIR/${label}.timer" <<TEOF
[Unit]
Description=${label} timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=${interval}s
Persistent=true

[Install]
WantedBy=timers.target
TEOF

  systemctl --user daemon-reload
  systemctl --user enable --now "${label}.timer"
  log_ok "Scheduled $label via systemd (every $(format_duration "$interval"))"
}

_scheduler_uninstall_systemd() {
  local label="$1"
  systemctl --user disable --now "${label}.timer" 2>/dev/null || true
  rm -f "$SCHEDULER_SYSTEMD_DIR/${label}.timer"
  rm -f "$SCHEDULER_SYSTEMD_DIR/${label}.service"
  systemctl --user daemon-reload
  log_ok "Removed $label (systemd)"
}

_scheduler_status_systemd() {
  local label="$1"
  local status="not installed"

  if [[ -f "$SCHEDULER_SYSTEMD_DIR/${label}.timer" ]]; then
    if systemctl --user is-active "${label}.timer" >/dev/null 2>&1; then
      status="active"
    else
      status="installed (inactive)"
    fi
  fi

  jq -n \
    --arg label "$label" \
    --arg status "$status" \
    '{label: $label, status: $status, platform: "systemd"}'
}

# ── Linux (cron) fallback ─────────────────────────────────────────────────────

_scheduler_install_cron() {
  local label="$1" interval="$2" command="$3"
  shift 3
  local -a env_vars=("$@")

  local interval_min=$(( interval / 60 ))
  [[ "$interval_min" -lt 1 ]] && interval_min=1

  # Build env prefix
  local env_prefix=""
  for ev in "${env_vars[@]+"${env_vars[@]}"}"; do
    env_prefix+="${ev} "
  done

  local cron_line="*/${interval_min} * * * * ${env_prefix}${command} # ${label}"
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
    '{label: $label, status: $status, platform: "cron", cron_entry: $entry}'
}
