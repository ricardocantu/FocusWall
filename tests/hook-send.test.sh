#!/usr/bin/env bash
# Black-box contract tests for hooks/hook-send.sh's privacy filter.
# Uses --transform-only, so nothing is sent; the output is the exact payload
# that would leave the workstation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENDER="$ROOT/hooks/hook-send.sh"
FIX="$ROOT/tests/fixtures/hooks"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

transform() {
  FOCUSWALL_TEST_HOST=test-host FOCUSWALL_TEST_CWD=/work/project \
  FOCUSWALL_TEST_BRANCH=main FOCUSWALL_TEST_NOW=2026-09-03T12:00:00Z \
    "$SENDER" --transform-only < "$FIX/$1"
}

# PreToolUse: the command line and transcript path stay home; file_path survives.
out="$(transform pre-tool.json)"
jq -e '.hook_event_name == "PreToolUse" and .session_id == "sess-1" and .tool_name == "Bash"
       and .tool_input == {file_path: "/home/you/projects/my-project/src/app.js"}
       and (has("transcript_path") | not) and (has("permission_mode") | not)
       and (has("tool_use_id") | not) and (has("cwd") | not)
       and ._meta == {hostname: "test-host", cwd: "/work/project",
                      received_at_client: "2026-09-03T12:00:00Z", branch: "main"}' \
  <<<"$out" >/dev/null || fail "pre-tool allowlist: $out"
grep -q 'aws/credentials' <<<"$out" && fail "Bash command leaked"

# PostToolUse: tool_response (file contents / stdout) never leaves.
out="$(transform post-tool.json)"
jq -e '(has("tool_response") | not) and .tool_input.file_path == "/home/you/projects/my-project/README.md"' \
  <<<"$out" >/dev/null || fail "post-tool: $out"
grep -q 'SECRET_FILE_BODY' <<<"$out" && fail "tool_response leaked"

# Prompt: first line only, cut to 60 characters.
line="Refactor the event store so that sessions are keyed by host and id, then run the tests"
out="$(transform prompt.json)"
jq -e --arg want "${line:0:60}" '.prompt == $want' <<<"$out" >/dev/null || fail "prompt truncation: $out"
grep -q 'second line' <<<"$out" && fail "prompt second line leaked"

# A credential-shaped prompt is replaced by a fixed label.
out="$(transform prompt-password.json)"
jq -e '.prompt == "Prompt submitted"' <<<"$out" >/dev/null || fail "credential gate: $out"
grep -q 'hunter2' <<<"$out" && fail "password leaked"

# Notification keeps its message, drops the rest.
out="$(transform notification.json)"
jq -e '.message == "Claude needs your permission to use Bash" and (has("notification_type") | not)' \
  <<<"$out" >/dev/null || fail "notification: $out"

# StopFailure keeps the error slug, drops error_details.
out="$(transform stop-failure.json)"
jq -e '.error == "rate_limit" and (has("error_details") | not)' <<<"$out" >/dev/null || fail "stop-failure: $out"
grep -q 'user@example.com' <<<"$out" && fail "error_details leaked"

# Fail closed: no hook name / invalid JSON / no jq on PATH -> nothing at all.
[ -z "$(transform no-hook-name.json)" ] || fail "no-hook-name should produce no output"
[ -z "$(transform invalid.json)" ] || fail "invalid JSON should produce no output"
tmpbin="$(mktemp -d)"; trap 'rm -rf "$tmpbin"' EXIT
ln -s "$(command -v bash)" "$tmpbin/bash"; ln -s "$(command -v cat)" "$tmpbin/cat"
[ -z "$(PATH="$tmpbin" transform pre-tool.json 2>/dev/null || true)" ] || fail "missing jq should produce no output"

# A credential-shaped branch name is left out of _meta.
out="$(FOCUSWALL_TEST_HOST=h FOCUSWALL_TEST_CWD=/w FOCUSWALL_TEST_BRANCH=feature/api-key-rotation \
       FOCUSWALL_TEST_NOW=2026-09-03T12:00:00Z "$SENDER" --transform-only < "$FIX/notification.json")"
jq -e '._meta | has("branch") | not' <<<"$out" >/dev/null || fail "credential-shaped branch leaked: $out"

echo "PASS"
