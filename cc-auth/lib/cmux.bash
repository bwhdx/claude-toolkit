#!/usr/bin/env bash
# cc-auth -> cmux: publish every account's last known usage for the cmux sidebar.
#
# A cmux custom sidebar has no filesystem or network access; it only sees cmux's own workspace
# data. So the figures are written into the description of one workspace, "Claude accounts",
# which the areas sidebar hides and renders as its usage panel. Only processes started inside
# cmux may talk to it, so this is a no-op elsewhere (e.g. Alfred's gateway).

CC_AUTH_CMUX_TITLE="Claude accounts"

# Compact JSON for the sidebar: every registered account, soonest weekly reset first, accounts
# never checked last (with null figures, so they are listed rather than missing):
# {v, in (account sessions use), at (epoch), accounts: [{n, w, wr, h, hr, s, t}]}
#   w/h = weekly / 5-hour utilization (0-1), wr/hr = their resets (epoch), s = status, t = checked
cmux_usage_payload() {
  jq -cn --argjson now "$(now_epoch)" \
    --slurpfile reg "$CC_AUTH_ACCOUNTS_FILE" --slurpfile st "$CC_AUTH_STATE_FILE" '
    $st[0] as $s
    | {v: 1, in: ($s.session.account // null), at: $now,
       accounts: [$reg[0].accounts[].name as $n | ($s.accounts[$n].windows // {}) as $x
         | {n: $n, w: $x.seven_day.utilization, wr: $x.seven_day.resets_at,
            h: $x.five_hour.utilization, hr: $x.five_hour.resets_at, s: $x.status, t: $x.checked}]
         | sort_by(.wr // 1e18)}'
}

# Ref of the "Claude accounts" workspace, creating it (unfocused, in ~) if it is missing.
_cmux_accounts_ref() {
  local ref
  ref=$(cmux tree --all --json 2>/dev/null \
    | jq -r --arg t "$CC_AUTH_CMUX_TITLE" '[.windows[]?.workspaces[]? | select(.title == $t) | .ref][0] // empty')
  if [[ -z "$ref" ]]; then
    cmux new-workspace --name "$CC_AUTH_CMUX_TITLE" --cwd "$HOME" --focus false >/dev/null 2>&1 || return 1
    ref=$(cmux tree --all --json 2>/dev/null \
      | jq -r --arg t "$CC_AUTH_CMUX_TITLE" '[.windows[]?.workspaces[]? | select(.title == $t) | .ref][0] // empty')
  fi
  [[ -n "$ref" ]] && echo "$ref"
}

# Publish once; one publisher at a time, so two never both create the workspace.
cmux_publish_usage() {
  [[ -n "${CMUX_WORKSPACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1 || return 0
  local lock="$CC_AUTH_DIR/.publish.lock" ref payload
  acquire_lock "$lock" 60 || return 0
  payload=$(cmux_usage_payload) && ref=$(_cmux_accounts_ref) \
    && cmux workspace-action --action set-description --workspace "$ref" --description "$payload" >/dev/null 2>&1
  release_lock "$lock"
}

# Publish in the background, so a caller (Claude Code waiting on its token) never waits for cmux.
cmux_publish_usage_async() {
  [[ -n "${CMUX_WORKSPACE_ID:-}" ]] || return 0
  ( cmux_publish_usage ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
