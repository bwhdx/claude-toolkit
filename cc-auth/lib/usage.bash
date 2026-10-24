#!/usr/bin/env bash
# cc-auth usage — read rate limit headroom for accounts without swapping the keychain
#
# Anthropic returns unified rate limit headers on every inference response, so a
# single cheap request with an account's long-term token reveals that account's
# session (5h) and weekly (7d) headroom. That is the only usage signal available
# to a long-term token: the richer /api/oauth/usage endpoint (which also breaks
# usage down per model) requires the user:profile scope, which tokens minted by
# `claude setup-token` do not carry.

CC_USAGE_ENDPOINT="${CC_USAGE_ENDPOINT:-https://api.anthropic.com/v1/messages}"
CC_USAGE_MODEL="${CC_USAGE_MODEL:-claude-haiku-4-5-20251001}"
CC_USAGE_TIMEOUT="${CC_USAGE_TIMEOUT:-20}"

# ── Header parsing ────────────────────────────────────────────────────────────

# Read one header value from a curl header dump (case-insensitive, CR stripped)
# Args: $1 = header file, $2 = header name
_usage_header() {
  local file="$1" name="$2"
  grep -i "^${name}:" "$file" 2>/dev/null \
    | tail -1 \
    | cut -d: -f2- \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Final HTTP status code in a curl header dump (curl appends one block per hop)
_usage_http_code() {
  grep -i '^HTTP/' "$1" 2>/dev/null | tail -1 | awk '{print $2}'
}

# Format an epoch as ISO 8601 UTC, on either BSD or GNU date
_usage_epoch_to_iso() {
  local epoch="$1"
  [[ -z "$epoch" || "$epoch" == "0" ]] && { echo ""; return; }
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo ""
}

# Build the JSON object for one rate limit window
# Args: $1 = header file, $2 = header infix (5h|7d), $3 = now epoch
_usage_window_json() {
  local file="$1" infix="$2" now="$3"
  local util reset wstatus
  util=$(_usage_header "$file" "anthropic-ratelimit-unified-${infix}-utilization")
  reset=$(_usage_header "$file" "anthropic-ratelimit-unified-${infix}-reset")
  wstatus=$(_usage_header "$file" "anthropic-ratelimit-unified-${infix}-status")

  [[ -z "$util" ]] && { echo "null"; return; }

  # Utilization is a 0..1 fraction but can exceed 1 once a window is blown
  local used
  used=$(awk -v u="$util" 'BEGIN{p=int(u*100+0.5); if(p<0)p=0; if(p>100)p=100; print p}')
  local left=$(( 100 - used ))

  local remaining=0
  if [[ "$reset" =~ ^[0-9]+$ ]]; then
    remaining=$(( reset - now ))
    (( remaining < 0 )) && remaining=0
  else
    reset=0
  fi

  jq -n \
    --argjson used "$used" \
    --argjson left "$left" \
    --argjson reset "${reset:-0}" \
    --arg reset_iso "$(_usage_epoch_to_iso "$reset")" \
    --argjson remaining "$remaining" \
    --arg status "${wstatus:-unknown}" \
    --arg severity "$(usage_severity "$left")" \
    --arg surpassed "$(_usage_header "$file" "anthropic-ratelimit-unified-${infix}-surpassed-threshold")" \
    '{percent_used:$used, percent_left:$left, resets_at_epoch:$reset,
      resets_at:$reset_iso, resets_in_seconds:$remaining,
      status:$status, severity:$severity, surpassed_threshold:$surpassed}'
}

# Parse a curl header dump into normalized usage JSON.
# Args: $1 = header file
# Returns: JSON on stdout. Always valid JSON, on every path.
usage_parse_headers() {
  local file="$1"
  local now="${CC_USAGE_NOW:-$(now_epoch)}"

  if [[ ! -f "$file" ]]; then
    jq -n '{ok:false, error:"no_response"}'
    return 0
  fi

  local code session weekly
  code=$(_usage_http_code "$file")
  session=$(_usage_window_json "$file" "5h" "$now")
  weekly=$(_usage_window_json "$file" "7d" "$now")

  # An exhausted account answers 429 but still reports its utilization and reset,
  # which is precisely the state worth surfacing. So whenever the headers are
  # present they win, and the status code only decides how to explain their absence.
  if [[ "$session" != "null" || "$weekly" != "null" ]]; then
    # Which window is actually binding right now, in our own vocabulary
    local claim binding=""
    claim=$(_usage_header "$file" 'anthropic-ratelimit-unified-representative-claim')
    case "$claim" in
      five_hour) binding="session" ;;
      seven_day) binding="weekly" ;;
    esac

    # Numeric extras are null when absent rather than an empty string
    local fb_pct="null" raw_pct retry="null" raw_retry
    raw_pct=$(_usage_header "$file" 'anthropic-ratelimit-unified-fallback-percentage')
    [[ -n "$raw_pct" ]] && fb_pct=$(awk -v v="$raw_pct" 'BEGIN{printf "%d", v*100+0.5}')
    raw_retry=$(_usage_header "$file" 'retry-after')
    [[ "$raw_retry" =~ ^[0-9]+$ ]] && retry="$raw_retry"

    jq -n \
      --argjson session "$session" \
      --argjson weekly "$weekly" \
      --arg status "$(_usage_header "$file" 'anthropic-ratelimit-unified-status')" \
      --arg fallback "$(_usage_header "$file" 'anthropic-ratelimit-unified-fallback')" \
      --argjson fallback_percentage "$fb_pct" \
      --arg overage "$(_usage_header "$file" 'anthropic-ratelimit-unified-overage-status')" \
      --arg overage_reason "$(_usage_header "$file" 'anthropic-ratelimit-unified-overage-disabled-reason')" \
      --arg claim "$claim" \
      --arg binding "$binding" \
      --arg org "$(_usage_header "$file" 'anthropic-organization-id')" \
      --arg ws "$(_usage_header "$file" 'anthropic-workspace-id')" \
      --argjson retry "$retry" \
      '{ok:true, session:$session, weekly:$weekly,
        status:$status,
        binding:$binding, representative_claim:$claim,
        fallback:$fallback, fallback_percentage:$fallback_percentage,
        overage_status:$overage, overage_disabled_reason:$overage_reason,
        retry_after_seconds:$retry,
        organization_id:$org, workspace_id:$ws}'
    return 0
  fi

  case "$code" in
    401) jq -n '{ok:false, error:"unauthorized"}' ;;
    403) jq -n '{ok:false, error:"forbidden_scope"}' ;;
    429) jq -n '{ok:false, error:"rate_limited"}' ;;
    5??) jq -n '{ok:false, error:"server_error"}' ;;
    200) jq -n '{ok:false, error:"no_rate_limit_headers"}' ;;
    "")  jq -n '{ok:false, error:"no_response"}' ;;
    *)   jq -n --arg c "$code" '{ok:false, error:("http_" + $c)}' ;;
  esac
}

# ── Presentation helpers ──────────────────────────────────────────────────────

# Classify remaining headroom. Args: $1 = percent left
usage_severity() {
  local left="${1:-0}"
  if   (( left <= 5 ));  then echo "critical"
  elif (( left <= 25 )); then echo "warning"
  else                        echo "ok"
  fi
}

# The API's own verdict for a window, as a short label.
# Distinct from usage_severity, which we derive from the percentage ourselves.
# Args: $1 = window status. Prints a label, or nothing when healthy/unknown.
usage_status_label() {
  case "${1:-}" in
    rejected)        echo "BLOCKED" ;;
    allowed_warning) echo "NEAR LIMIT" ;;
    *)               echo "" ;;
  esac
}

# Draw a meter. Args: $1 = percent left, $2 = width
usage_bar() {
  local left="${1:-0}" width="${2:-20}"
  local filled
  filled=$(awk -v l="$left" -v w="$width" 'BEGIN{f=int(l*w/100+0.5); if(f<0)f=0; if(f>w)f=w; print f}')
  local empty=$(( width - filled ))
  local bar=""
  (( filled > 0 )) && bar=$(printf '█%.0s' $(seq 1 "$filled"))
  (( empty  > 0 )) && bar="${bar}$(printf '░%.0s' $(seq 1 "$empty"))"
  echo "$bar"
}

# ── Probing ───────────────────────────────────────────────────────────────────

# Smallest request that still returns unified rate limit headers. The Claude Code
# system prompt is required for OAuth-token inference to be accepted.
_usage_probe_payload() {
  jq -n --arg model "$CC_USAGE_MODEL" \
    '{model:$model, max_tokens:1,
      system:[{type:"text", text:"You are Claude Code, Anthropic'\''s official CLI for Claude."}],
      messages:[{role:"user", content:"hi"}]}'
}

# Probe one token. Args: $1 = bearer token
# Returns: normalized usage JSON on stdout (never fails)
usage_probe_token() {
  local token="$1"
  [[ -z "$token" ]] && { jq -n '{ok:false, error:"no_token"}'; return 0; }

  local hdr body
  hdr=$(mktemp) || { jq -n '{ok:false, error:"no_response"}'; return 0; }
  body=$(mktemp)

  curl -sS --max-time "$CC_USAGE_TIMEOUT" -D "$hdr" -o "$body" "$CC_USAGE_ENDPOINT" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "content-type: application/json" \
    -d "$(_usage_probe_payload)" >/dev/null 2>&1 || true

  usage_parse_headers "$hdr"
  rm -f "$hdr" "$body"
}

# ── Cache ─────────────────────────────────────────────────────────────────────
# Each probe is a real (if tiny) billed request against the account's own quota,
# so repeated reads — a dashboard polling, a shell prompt — reuse a recent result
# instead of re-billing. Set CC_USAGE_CACHE_TTL=0 to disable.

CC_USAGE_CACHE_TTL="${CC_USAGE_CACHE_TTL:-60}"

usage_cache_file() { echo "${CC_AUTH_DIR}/usage-cache.json"; }

# Read a cached entry if it is younger than the TTL.
# Args: $1 = account name. Prints JSON and returns 0 on hit, returns 1 on miss.
usage_cache_get() {
  local name="$1" file entry age now
  file=$(usage_cache_file)

  [[ "${CC_USAGE_CACHE_TTL:-60}" -gt 0 ]] || return 1
  [[ -f "$file" ]] || return 1

  now="${CC_USAGE_NOW:-$(now_epoch)}"
  entry=$(jq -c --arg n "$name" '.[$n] // empty' "$file" 2>/dev/null) || return 1
  [[ -n "$entry" ]] || return 1

  age=$(echo "$entry" | jq -r --argjson now "$now" '$now - (.fetched_at // 0)' 2>/dev/null) || return 1
  [[ "$age" =~ ^-?[0-9]+$ ]] || return 1
  (( age >= 0 && age < CC_USAGE_CACHE_TTL )) || return 1

  echo "$entry" | jq -c '.usage'
}

# Store a probe result. Args: $1 = account name, $2 = usage JSON
# Accounts are probed concurrently, so the read-modify-write is serialised to
# stop parallel writers clobbering each other's entries.
usage_cache_put() {
  local name="$1" usage_json="$2" file tmp now lockdir attempts=0 rc=0
  file=$(usage_cache_file)
  lockdir="${file}.lock"
  now="${CC_USAGE_NOW:-$(now_epoch)}"

  while ! acquire_lock "$lockdir" 30; do
    attempts=$(( attempts + 1 ))
    (( attempts > 200 )) && return 1
    sleep 0.05
  done

  # A corrupt or absent cache is replaced rather than allowed to fail the write
  jq -e . "$file" >/dev/null 2>&1 || echo '{}' > "$file"

  tmp=$(mktemp)
  if jq --arg n "$name" --argjson u "$usage_json" --argjson t "$now" \
       '.[$n] = {fetched_at:$t, usage:$u}' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
  else
    rm -f "$tmp"
    rc=1
  fi

  release_lock "$lockdir"
  return $rc
}

# Probe one account by name via its long-term token, honouring the cache.
# Args: $1 = account name, $2 = "true" to bypass the cache
# Returns: usage JSON with a .cached flag (never fails)
usage_probe_account() {
  local name="$1" refresh="${2:-false}" cached token usage

  if [[ "$refresh" != "true" ]]; then
    if cached=$(usage_cache_get "$name"); then
      echo "$cached" | jq -c '. + {cached:true}'
      return 0
    fi
  fi

  if ! vault_has_longterm "$name"; then
    jq -n '{ok:false, error:"no_longterm_token", cached:false}'
    return 0
  fi

  token=$(vault_read_longterm "$name" 2>/dev/null) || {
    jq -n '{ok:false, error:"vault_read_failed", cached:false}'
    return 0
  }

  usage=$(usage_probe_token "$token")
  usage_cache_put "$name" "$usage" || true
  echo "$usage" | jq -c '. + {cached:false}'
}

# Pick the account with the most session headroom, breaking ties on weekly.
# Args: $1 = the results JSON array. Prints a name, or nothing if none usable.
usage_best_account() {
  echo "$1" | jq -r '
    [ .[] | select(.ok == true) | select((.session.percent_left // 0) > 0) ]
    | sort_by(.session.percent_left, .weekly.percent_left)
    | last | .account // empty' 2>/dev/null
}
