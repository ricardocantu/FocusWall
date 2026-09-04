#!/usr/bin/env bash
# Reads hook JSON on stdin, filters it down to the fields the wall uses, adds
# host metadata, and POSTs it to focus-wall.
# Usage in settings.json: "command": "/abs/path/to/hook-send.sh"
# Test/debug:             hook-send.sh --transform-only < payload.json
#                         (prints the filtered payload, sends nothing)
#
# Once the server lives on the Pi, change the default URL below — editing it
# here (one place) beats a shell-rc env var, which GUI-launched Claude Code
# sessions (e.g. the VS Code extension) may never see.
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default http://localhost:5050/events
#   FOCUSWALL_TIMEOUT  curl --max-time in seconds, 1..10, default 2
#
# Privacy: only an allowlist of fields leaves this machine (see the jq filter).
# If the filter cannot run — no jq, malformed input — NOTHING is sent: the wall
# missing one event beats shipping a raw payload.

set -u
URL="${FOCUSWALL_URL:-http://localhost:5050/events}"
TIMEOUT="${FOCUSWALL_TIMEOUT:-2}"
case "$TIMEOUT" in
  [1-9]|10) ;;
  *) TIMEOUT=2 ;;
esac

transform_only=false
[ "${1:-}" = "--transform-only" ] && transform_only=true

input=$(cat)

# Host metadata. The git branch is silent + guarded so a non-repo cwd or a
# missing git just omits the field; it never blocks the hook. The
# FOCUSWALL_TEST_* overrides give tests/hook-send.test.sh deterministic output.
# The timestamp format is portable (BSD/macOS date has no GNU %N).
host="${FOCUSWALL_TEST_HOST:-$(hostname -s)}"
cwd="${FOCUSWALL_TEST_CWD:-$PWD}"
branch="${FOCUSWALL_TEST_BRANCH:-$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
ts="${FOCUSWALL_TEST_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Allowlist: keep exactly what the server and the views read — hook_event_name,
# session_id, message, tool_name, prompt, error, tool_input.file_path — and
# nothing else. tool_response (file contents, Bash stdout), transcript_path,
# error_details, permission_mode, the raw tool_input command line: all stay on
# this machine. A prompt is cut to its first line, <=60 chars. Any free-text
# field that looks credential-shaped (api key / password / token / bearer /
# private key / sk-…) is replaced by a fixed label instead of forwarded.
filtered=$(jq -ce \
  --arg host "$host" \
  --arg cwd "$cwd" \
  --arg ts "$ts" \
  --arg branch "$branch" '
  def credential_shaped:
    type == "string" and
    test("(?i)(api[_-]?key|password|passwd|secret|token|credential|authorization|bearer|private[_-]?key|(^|[_:-])sk[_-])");
  def text_or($fallback; $limit):
    if type != "string" then null
    elif credential_shaped then $fallback
    else .[:$limit] end;
  if (.hook_event_name | type) != "string" then empty else . end
  | {
      hook_event_name,
      session_id: (.session_id | if type == "string" then .[:128] else null end),
      message:    (.message | text_or("Notification"; 200)),
      tool_name:  (.tool_name | text_or(null; 64)),
      prompt:     (if .hook_event_name == "UserPromptSubmit" and (.prompt | type) == "string"
                   then (.prompt | split("\n")[0] | .[:60] | text_or("Prompt submitted"; 60))
                   else null end),
      error:      (.error | if type == "string" and test("^[a-z][a-z0-9_]{0,47}$") then . else null end),
      tool_input: (if (.tool_input | type) == "object" and (.tool_input.file_path | type) == "string"
                   then {file_path: .tool_input.file_path} else null end)
    }
  | with_entries(select(.value != null))
  | . + {_meta: ({hostname: $host, cwd: $cwd, received_at_client: $ts}
                 + (if $branch != "" and ($branch | credential_shaped | not)
                    then {branch: $branch} else {} end))}
  ' <<<"$input" 2>/dev/null) || exit 0
[ -n "$filtered" ] || exit 0

if [ "$transform_only" = true ]; then
  printf '%s\n' "$filtered"
  exit 0
fi

# Background the POST so the hook returns immediately — a down or unreachable
# server must never add latency to Claude Code tool calls.
( curl -sS --connect-timeout 1 --max-time "$TIMEOUT" -X POST "$URL" \
    -H 'Content-Type: application/json' \
    --data-binary "$filtered" >/dev/null 2>&1 & )

# Exit 0 always — hooks failing should not break Claude Code.
exit 0
