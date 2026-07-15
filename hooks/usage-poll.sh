#!/usr/bin/env bash
# Focus Wall usage poller. Reads this machine's Claude OAuth token, calls
# Anthropic's /api/oauth/usage, reduces the response to the limit gauges, and
# POSTs ONLY the summary (never the token) to the Focus Wall server.
#
# PORTABILITY: macOS + Linux. No GNU-only date. Always exits 0 so a scheduler
# never surfaces failures. The token is NEVER logged.
#
# Usage:
#   usage-poll.sh                     # full flow (scheduled)
#   usage-poll.sh --reduce FILE [FW_HOST=x FW_LABEL=y]   # test/debug: reduce a raw file to stdout

set -u

FOCUSWALL_URL="${FOCUSWALL_URL:-http://focus-wall.local:5050/events}"
REPORT_URL="${FOCUSWALL_URL%/events}/usage/report"
USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# reduce RAW_JSON_FILE HOST LABEL TS  -> prints summary JSON (status ok)
reduce() {
  local file="$1" host="$2" label="$3" ts="$4"
  jq -c --arg host "$host" --arg label "$label" --arg ts "$ts" '
    {
      host: $host, label: $label, status: "ok", ts: $ts,
      limits: [ (.limits // [])[] | {
        kind, group, percent, severity, resets_at,
        model: (.scope.model.display_name // null),
        is_active
      } ]
    }' "$file"
}

# summary with no limits, given a status string
empty_summary() {
  local host="$1" label="$2" ts="$3" status="$4"
  jq -cn --arg host "$host" --arg label "$label" --arg ts "$ts" --arg status "$status" \
    '{host:$host, label:$label, status:$status, ts:$ts, limits:[]}'
}

# ── Test/debug mode ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--reduce" ]; then
  shift
  file="$1"; shift
  host="$(hostname)"; label="$host"
  for kv in "$@"; do
    case "$kv" in
      FW_HOST=*)  host="${kv#FW_HOST=}" ;;
      FW_LABEL=*) label="${kv#FW_LABEL=}" ;;
    esac
  done
  reduce "$file" "$host" "$label" "$(now_iso)"
  exit 0
fi

# ── Full flow ────────────────────────────────────────────────────────────────
HOST="$(hostname)"
LABEL="${FOCUSWALL_ACCOUNT_LABEL:-$HOST}"
TS="$(now_iso)"

read_token() {
  # macOS: login Keychain. Linux: ~/.claude/.credentials.json.
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
  elif [ -f "$HOME/.claude/.credentials.json" ]; then
    jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null
  fi
}

post_summary() {
  # Bounded (-m 5) and synchronous. Must NOT be backgrounded: launchd/systemd
  # tear down the job's process group the instant this script exits, which would
  # kill an orphaned background curl before it reaches the server (the POST would
  # silently never arrive on macOS). Nothing waits on this poller, so a bounded
  # blocking POST is correct here — unlike hook-send.sh, which must stay async.
  curl -s -m 5 -o /dev/null -X POST "$REPORT_URL" \
    -H 'Content-Type: application/json' --data-binary "$1" >/dev/null 2>&1
}

TOKEN="$(read_token)"
if [ -z "${TOKEN:-}" ]; then
  echo "usage-poll: no token available" >&2
  post_summary "$(empty_summary "$HOST" "$LABEL" "$TS" "no_token")"
  exit 0
fi

TMP="$(mktemp)"
CODE="$(curl -s -m 10 -o "$TMP" -w '%{http_code}' "$USAGE_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)"

if [ "$CODE" = "200" ]; then
  SUMMARY="$(reduce "$TMP" "$HOST" "$LABEL" "$TS")"
  [ -n "$SUMMARY" ] && post_summary "$SUMMARY"
elif [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "usage-poll: auth rejected (HTTP $CODE)" >&2
  post_summary "$(empty_summary "$HOST" "$LABEL" "$TS" "auth_expired")"
else
  echo "usage-poll: usage endpoint HTTP $CODE" >&2
fi

rm -f "$TMP"
exit 0
