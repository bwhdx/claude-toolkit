#!/usr/bin/env bash
# claude-toolkit shared process utilities — PID liveness, process info

# Check if a PID is alive
pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Get the command line for a PID
pid_cmdline() {
  local pid="$1"
  ps -p "$pid" -o args= 2>/dev/null
}

# Get the command name for a PID
pid_comm() {
  local pid="$1"
  ps -p "$pid" -o comm= 2>/dev/null
}

# Get the start time of a PID (epoch seconds, macOS)
pid_start_epoch() {
  local pid="$1"
  if is_macos; then
    ps -p "$pid" -o lstart= 2>/dev/null | xargs -I{} date -j -f "%c" "{}" +%s 2>/dev/null
  else
    stat -c %Z "/proc/$pid" 2>/dev/null
  fi
}

# Find all PIDs matching a pattern
find_pids() {
  local pattern="$1"
  pgrep -f "$pattern" 2>/dev/null
}

# Get elapsed seconds since a timestamp (epoch ms or epoch s)
elapsed_since() {
  local started="$1"
  local now
  now=$(now_epoch)
  # If timestamp is in milliseconds (> 1e12), convert to seconds
  if [[ "$started" -gt 1000000000000 ]] 2>/dev/null; then
    started=$(( started / 1000 ))
  fi
  echo $(( now - started ))
}

# Format seconds as human-readable duration
format_duration() {
  local secs="$1"
  if [[ "$secs" -lt 60 ]]; then
    echo "${secs}s"
  elif [[ "$secs" -lt 3600 ]]; then
    echo "$(( secs / 60 ))m"
  elif [[ "$secs" -lt 86400 ]]; then
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    echo "${h}h${m}m"
  else
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    echo "${d}d${h}h"
  fi
}
