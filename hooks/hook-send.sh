#!/usr/bin/env bash
# Reads hook JSON on stdin, filters + augments it, POSTs to focus-wall.
# Usage in settings.json: "command": "/abs/path/to/hook-send.sh"
#
# Once the server lives on the Pi, change the default URL below — editing it
# here (one place) beats a shell-rc env var, which GUI-launched Claude Code
# sessions (e.g. the VS Code extension) may never see.
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default http://localhost:5050/events
#   FOCUSWALL_TIMEOUT  curl --max-time, default 2

set -u
URL="${FOCUSWALL_URL:-http://localhost:5050/events}"
TIMEOUT="${FOCUSWALL_TIMEOUT:-2}"

input=$(cat)

# Current git branch for this cwd — silent + guarded so a non-repo cwd or
# missing git just omits the field. Never blocks the hook.
branch=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

# Strip tool_input down to file_path — raw PreToolUse payloads carry full
# Bash command lines and entire Write file bodies; source code stays on this
# machine. Then add host metadata. Also truncate a user prompt to its first
# line, <=60 chars, so full prompt text never leaves the workstation. The
# timestamp format is portable (BSD/macOS date has no GNU %N).
augmented=$(jq -c \
  --arg host "$(hostname -s)" \
  --arg cwd "$PWD" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg branch "$branch" \
  'if .tool_input then .tool_input |= {file_path} else . end
   | if .hook_event_name == "UserPromptSubmit" and (.prompt | type) == "string"
     then .prompt |= (split("\n")[0] | .[:60]) else . end
   | . + {_meta: ({hostname: $host, cwd: $cwd, received_at_client: $ts}
                  + (if $branch != "" then {branch: $branch} else {} end))}' \
  <<<"$input" 2>/dev/null) || augmented="$input"

# Background the POST so the hook returns immediately — a down or unreachable
# server must never add latency to Claude Code tool calls.
( curl -sS --connect-timeout 1 --max-time "$TIMEOUT" -X POST "$URL" \
    -H 'Content-Type: application/json' \
    --data-binary "$augmented" >/dev/null 2>&1 & )

# Exit 0 always — hooks failing should not break Claude Code.
exit 0
