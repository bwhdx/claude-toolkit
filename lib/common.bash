#!/usr/bin/env bash
# claude-toolkit shared utilities — logging, colors, JSON helpers, platform detection, locks

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[0;31m'    GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'   CYAN=$'\033[0;36m'   BOLD=$'\033[1m'
  DIM=$'\033[2m'       NC=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" NC=""
fi

# ── Logging (level-gated) ─────────────────────────────────────────────────────
#
# LOG_LEVEL controls verbosity:
#   0 = errors only
#   1 = errors + warnings
#   2 = errors + warnings + info (default)
#   3 = all (including debug)
#
# Set DEBUG=1 for debug output. Set LOG_LEVEL=0 for quiet/headless operation.

LOG_LEVEL="${LOG_LEVEL:-2}"
[[ "${DEBUG:-}" == "1" ]] && LOG_LEVEL=3

log_error() { [[ "$LOG_LEVEL" -ge 0 ]] && echo -e "${RED}✗${NC} $*" >&2; }
log_warn()  { [[ "$LOG_LEVEL" -ge 1 ]] && echo -e "${YELLOW}⚠${NC} $*" >&2; }
log_info()  { [[ "$LOG_LEVEL" -ge 2 ]] && echo -e "${CYAN}▸${NC} $*" >&2; }
log_ok()    { [[ "$LOG_LEVEL" -ge 2 ]] && echo -e "${GREEN}✓${NC} $*" >&2; }
log_dim()   { [[ "$LOG_LEVEL" -ge 2 ]] && echo -e "${DIM}  $*${NC}" >&2; }
log_debug() { [[ "$LOG_LEVEL" -ge 3 ]] && echo -e "${DIM}debug:${NC} $*" >&2; }
log_fatal() { log_error "$@"; exit 1; }

# ── JSON helpers (requires jq) ────────────────────────────────────────────────

# Atomic JSON write: write to temp, then mv (prevents partial reads)
json_write() {
  local file="$1" content="$2"
  local tmp="${file}.tmp.$$"
  printf '%s\n' "$content" > "$tmp" && mv -f "$tmp" "$file"
}

# Safe jq edit: read file, apply jq filter, atomic write back
json_edit() {
  local file="$1"; shift
  local result
  result=$(jq "$@" "$file") || return 1
  json_write "$file" "$result"
}

# ── Platform detection ────────────────────────────────────────────────────────

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

# ── Timestamp helpers ─────────────────────────────────────────────────────────

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

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

# ── Lock helpers (flock with mkdir fallback) ──────────────────────────────────
#
# Uses flock (faster, kernel-level) when available.
# Falls back to mkdir (POSIX atomic) otherwise.
# Stale detection: checks PID liveness + creation timestamp age.

# Acquire lock. Returns 0 on success, 1 on failure.
# Usage: acquire_lock "/path/to/.lock" [max_age_seconds]
acquire_lock() {
  local lockdir="$1"
  local max_age="${2:-300}"  # default 5 min stale timeout

  # Strategy 1: flock (preferred — faster, no directory overhead)
  if command -v flock >/dev/null 2>&1; then
    local lockfile="${lockdir}.flock"
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
    exec 9>"$lockfile"
    if flock -n 9 2>/dev/null; then
      echo "$$" > "$lockfile"
      return 0
    fi
    # flock held by another process — check if stale
    local lock_pid
    lock_pid=$(head -1 "$lockfile" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
      # Holding process is dead — force acquire
      flock -n 9 2>/dev/null && echo "$$" > "$lockfile" && return 0
    fi
    exec 9>&- 2>/dev/null || true
    return 1
  fi

  # Strategy 2: mkdir atomicity (portable fallback)
  if mkdir "$lockdir" 2>/dev/null; then
    echo "$$" > "$lockdir/pid"
    date +%s > "$lockdir/created"
    return 0
  fi

  # Lock exists — check if stale
  if [[ -d "$lockdir" ]]; then
    local lock_pid
    lock_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")

    # Check if holding process is dead
    if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
      log_debug "Breaking stale lock (dead PID $lock_pid)"
      rm -rf "$lockdir"
      mkdir "$lockdir" 2>/dev/null && echo "$$" > "$lockdir/pid" && date +%s > "$lockdir/created" && return 0
    fi

    # Check if lock is too old (cross-platform)
    local lock_created
    if [[ -f "$lockdir/created" ]]; then
      lock_created=$(cat "$lockdir/created" 2>/dev/null || echo 0)
    elif is_macos; then
      lock_created=$(stat -f %m "$lockdir/pid" 2>/dev/null || echo 0)
    elif is_linux; then
      lock_created=$(stat -c %Y "$lockdir/pid" 2>/dev/null || echo 0)
    else
      lock_created=0
    fi

    local lock_age=$(( $(now_epoch) - lock_created ))
    if [[ "$lock_created" -gt 0 && "$lock_age" -gt "$max_age" ]]; then
      log_debug "Breaking stale lock (age ${lock_age}s > ${max_age}s, PID $lock_pid)"
      rm -rf "$lockdir"
      mkdir "$lockdir" 2>/dev/null && echo "$$" > "$lockdir/pid" && date +%s > "$lockdir/created" && return 0
    fi
  fi

  return 1
}

# Release lock (handles both flock and mkdir modes)
release_lock() {
  local lockdir="$1"

  # Release flock if held
  local lockfile="${lockdir}.flock"
  if [[ -f "$lockfile" ]]; then
    exec 9>&- 2>/dev/null || true
  fi

  # Remove mkdir lockdir if it exists
  rm -rf "$lockdir"
}

# ── Dependency check ──────────────────────────────────────────────────────────

require_cmd() {
  local cmd="$1" msg="${2:-Required command '$1' not found}"
  command -v "$cmd" >/dev/null 2>&1 || { log_error "$msg"; return 1; }
}
