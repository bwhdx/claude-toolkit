#!/usr/bin/env bash
# claude-toolkit shared utilities — logging, colors, JSON helpers, platform detection

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'    GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'   CYAN=$'\033[0;36m'   BOLD=$'\033[1m'
  DIM=$'\033[2m'       NC=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" NC=""
fi

# ── Logging ───────────────────────────────────────────────────────────────────

log_info()  { echo -e "${CYAN}▸${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}✓${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $*" >&2; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }
log_dim()   { echo -e "${DIM}  $*${NC}" >&2; }

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

# ── Lock helpers (mkdir-based atomic lock) ────────────────────────────────────

# Acquire lock. Returns 0 on success, 1 on failure.
# Usage: acquire_lock "/path/to/.lock" [max_age_seconds]
acquire_lock() {
  local lockdir="$1"
  local max_age="${2:-300}"  # default 5 min stale timeout

  # Try to create lockdir atomically
  if mkdir "$lockdir" 2>/dev/null; then
    echo "$$" > "$lockdir/pid"
    return 0
  fi

  # Lock exists — check if stale
  if [[ -f "$lockdir/pid" ]]; then
    local lock_pid
    lock_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
    # Check if holding process is dead
    if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -rf "$lockdir"
      mkdir "$lockdir" 2>/dev/null && echo "$$" > "$lockdir/pid" && return 0
    fi
    # Check if lock is too old
    if is_macos; then
      local lock_age
      lock_age=$(( $(now_epoch) - $(stat -f %m "$lockdir/pid" 2>/dev/null || echo 0) ))
      if [[ "$lock_age" -gt "$max_age" ]]; then
        rm -rf "$lockdir"
        mkdir "$lockdir" 2>/dev/null && echo "$$" > "$lockdir/pid" && return 0
      fi
    fi
  fi

  return 1
}

# Release lock
release_lock() {
  local lockdir="$1"
  rm -rf "$lockdir"
}

# ── Dependency check ──────────────────────────────────────────────────────────

require_cmd() {
  local cmd="$1" msg="${2:-Required command '$1' not found}"
  command -v "$cmd" >/dev/null 2>&1 || { log_error "$msg"; return 1; }
}
