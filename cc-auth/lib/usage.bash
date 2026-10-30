#!/usr/bin/env bash
# cc-auth usage — live subscription usage per account.
#
# A one-token request returns the account's unified rate-limit headers (5-hour and weekly
# utilization, reset times, allowed/rejected) and its organization id. Long-term tokens from
# `claude setup-token` only carry the user:inference scope, so they cannot read /api/oauth/usage,
# but they can make this request. Each probe costs one output token of the account's usage.

CC_AUTH_API_BASE="${CC_AUTH_API_BASE:-https://api.anthropic.com}"
CC_AUTH_PROBE_MODEL="${CC_AUTH_PROBE_MODEL:-claude-haiku-5-5}"
# Subscription tokens are only accepted on requests that identify as Claude Code.
CC_AUTH_PROBE_SYSTEM="You are Claude Code, Anthropic's official CLI for Claude."

# Turn a response's headers into usage JSON.
# Args: $1 = header file (curl -D), $2 = HTTP status ("000", reported as 0, when there was no response)
# Output: {http, ok, organization_id, status, representative, five_hour, seven_day}
#         where five_hour/seven_day = {utilization (0.0-1.0), resets_at (epoch), status}
usage_parse() {
  local hdr="$1" code="$2"
  tr -d '\r' < "$hdr" \
    | awk 'match($0, /^[^:]+: /) { k = tolower(substr($0, 1, RLENGTH - 2)); if (k ~ /^anthropic-(ratelimit-unified|organization-id)/) print k "\t" substr($0, RLENGTH + 1) }' \
    | jq -Rn --argjson code "$((10#$code))" '
        def n($k): .[$k] | if . == null then null else tonumber end;
        def window($p): {utilization: n("anthropic-ratelimit-unified-\($p)-utilization"),
                         resets_at: n("anthropic-ratelimit-unified-\($p)-reset"),
                         status: .["anthropic-ratelimit-unified-\($p)-status"]};
        ([inputs | split("\t") | {(.[0]): .[1]}] | add // {}) as $h
        | $h | {
            http: $code,
            ok: has("anthropic-ratelimit-unified-status"),
            organization_id: .["anthropic-organization-id"],
            status: .["anthropic-ratelimit-unified-status"],
            representative: .["anthropic-ratelimit-unified-representative-claim"],
            five_hour: window("5h"),
            seven_day: window("7d")
          }'
}

# Probe one token. The token reaches curl on stdin (-H @-), never in its argument list.
# Args: $1 = token
# Output: usage JSON (see usage_parse)
usage_probe() {
  local token="$1" tmp code body
  tmp=$(mktemp -d) || return 1
  : > "$tmp/h"
  body=$(jq -cn --arg m "$CC_AUTH_PROBE_MODEL" --arg s "$CC_AUTH_PROBE_SYSTEM" \
    '{model: $m, max_tokens: 1, system: $s, messages: [{role: "user", content: "."}]}')
  code=$(printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\nanthropic-version: 2023-06-01\ncontent-type: application/json\n' "$token" \
    | curl -sS --max-time 30 -H @- -D "$tmp/h" -o /dev/null -w '%{http_code}' \
        --data "$body" "$CC_AUTH_API_BASE/v1/messages" 2>/dev/null) || true
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  usage_parse "$tmp/h" "$code"
  rm -rf "$tmp"
}

# Token used to read an account's usage: its long-term token, else its stored sign-in while
# that is still valid (sign-ins last hours; long-term tokens a year).
# Args: $1 = account name
# Output: "<longterm|oauth><TAB><token>"; returns 1 when neither is usable.
usage_token() {
  local name="$1" tok cred
  if vault_has_longterm "$name" && tok=$(vault_read_longterm "$name") && [[ -n "$tok" ]]; then
    printf 'longterm\t%s\n' "$tok"
    return 0
  fi
  cred=$(vault_read "$name" 2>/dev/null) || return 1
  keychain_cred_expired "$cred" && return 1
  tok=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$cred")
  [[ -n "$tok" ]] || return 1
  printf 'oauth\t%s\n' "$tok"
}

# Usage JSON for one account, with its name, email, token source and an organization check.
# Args: $1 = account name
usage_account() {
  local name="$1" line="" res acct
  acct=$(accounts_get "$name")
  if line=$(usage_token "$name"); then
    res=$(usage_probe "${line#*$'\t'}")
  else
    res='{"http": null, "ok": false, "organization_id": null, "status": null, "representative": null,
          "five_hour": null, "seven_day": null}'
  fi
  jq -c --arg name "$name" --arg src "${line%%$'\t'*}" --argjson acct "$acct" '
    {name: $name, email: ($acct.email // null), source: (if $src == "" then "none" else $src end)}
    + .
    + {expected_organization_id: ($acct.organization_id // null)}
    | .organization_mismatch = (.expected_organization_id != null and .organization_id != null
                                and .expected_organization_id != .organization_id)' <<< "$res"
}

# Record a probe in state, so cycling and `status` use the live figures.
# The representative claim is the window that currently governs the account.
# Args: $1 = usage JSON from usage_account
usage_record() {
  local res="$1" name util resets status now
  [[ "$(jq -r '.ok' <<< "$res")" == true ]] || return 0
  name=$(jq -r '.name' <<< "$res")
  read -r util resets status < <(jq -r '
    (if .representative == "seven_day" then .seven_day else .five_hour end) as $w
    | "\($w.utilization // 0) \($w.resets_at // 0) \(.status)"' <<< "$res")
  state_update_utilization "$name" "$util" "$resets" false
  state_set_windows "$name" "$(jq -c '{five_hour: (.five_hour // {} | {utilization, resets_at}),
    seven_day: (.seven_day // {} | {utilization, resets_at}), status}' <<< "$res")"
  now=$(now_epoch)
  if [[ "$status" == rejected && "$resets" -gt "$now" ]]; then
    state_mark_limited "$name" $(( resets - now ))
  fi
}

# Local wall-clock time for an epoch, e.g. "Tue 08:00".
usage_local_time() {
  date -r "$1" '+%a %H:%M' 2>/dev/null || date -d "@$1" '+%a %H:%M'
}

# Usage of several accounts, probed in parallel. Prints a JSON array in the order given.
# Args: account names
usage_probe_all() {
  local tmp i=0 name results="[]"
  tmp=$(mktemp -d) || return 1
  for name in "$@"; do
    usage_account "$name" > "$tmp/$i.json" &
    i=$((i + 1))
  done
  wait
  for (( i = 0; i < $#; i++ )); do
    results=$(jq -c --slurpfile r "$tmp/$i.json" '. + $r' <<< "$results")
  done
  rm -rf "$tmp"
  echo "$results"
}

# Share of either window at which an account counts as full: switching just before the limit
# avoids a session being stopped mid-task.
CC_AUTH_SWITCH_AT="${CC_AUTH_SWITCH_AT:-0.95}"

# The account to use: of those with room (read, not rejected, both windows below the switch
# threshold, with a long-term token), the one whose weekly window resets soonest, so capacity
# about to reset is used first.
# Args: $1 = JSON array of usage_account results. Prints a name, or nothing when none has room.
usage_pick() {
  jq -r --argjson at "$CC_AUTH_SWITCH_AT" '
    [.[] | select(.ok and .source == "longterm" and .status != "rejected" and (.organization_mismatch | not)
                  and (.five_hour.utilization // 0) < $at and (.seven_day.utilization // 0) < $at)]
    | sort_by(.seven_day.resets_at // 1e18) | .[0].name // empty' <<< "$1"
}

# The account sessions should be on, judged from each account's last check alone (no requests):
# of the given accounts, the one with room whose weekly window resets soonest. A window whose reset
# time has passed counts as empty, and its next weekly reset as a week later. Accounts never
# checked are left out. Prints a name, or nothing.
# Args: account names
usage_preferred_cached() {
  [[ $# -gt 0 ]] || return 0
  # --args makes every word after the filter an argument, so the state file comes in on stdin.
  jq -r --argjson now "$(now_epoch)" --argjson at "$CC_AUTH_SWITCH_AT" \
    --args '
    def eff($w): if ($w.resets_at // 0) > 0 and $w.resets_at <= $now then 0 else ($w.utilization // 0) end;
    def wreset($w): ($w.resets_at // 1e18) | if . <= $now then . + 604800 else . end;
    . as $s
    | [$ARGS.positional[] as $n | $s.accounts[$n] as $a | select($a.windows)
       | select(($a.limited_until // 0) <= $now)
       | {n: $n, h: eff($a.windows.five_hour), w: eff($a.windows.seven_day), r: wreset($a.windows.seven_day)}
       | select(.h < $at and .w < $at)]
    | sort_by(.r) | .[0].n // empty' "$@" < "$CC_AUTH_STATE_FILE"
}
