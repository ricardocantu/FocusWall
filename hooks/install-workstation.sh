#!/usr/bin/env bash
#
# install-workstation.sh — set up Claude Focus Wall reporting on this machine.
#
# Installs the hook wrapper and wires it into Claude Code so your sessions
# show up on a Focus Wall dashboard (idle / working / waiting / done).
# Self-contained: this one file is all a coworker needs — no repo clone,
# no build, no .NET, no Docker.
#
#   Install:    ./install-workstation.sh --url http://focus-wall.local:5050/events
#   Interactive: ./install-workstation.sh          (prompts for the URL)
#   Uninstall:  ./install-workstation.sh --uninstall
#
# Options:
#   --url URL     Focus Wall events endpoint (default http://focus-wall.local:5050/events; use the Pi's LAN IP if mDNS is unreliable)
#   --uninstall   Remove the Focus Wall hooks and (optionally) the install dir
#   --dir PATH    Where to install the wrapper (default ~/.focus-wall)
#   --yes         Non-interactive: assume yes, skip prompts (for scripted rollout)
#   --help        Show this help
#
# What it changes:
#   - writes  <dir>/hook-send.sh   (the wrapper; the server URL is baked in)
#   - merges  ~/.claude/settings.json   (adds 8 hook entries; your existing
#             hooks are preserved; a timestamped .bak is kept)
#
# The wrapper body is copied verbatim from IMPLEMENTATION.md §hook-send.sh,
# which is the spec of record — keep the two in sync if you edit either.

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
# Default to the Pi over mDNS (focus-wall.local). If mDNS is unreliable on your
# network, pass --url with the Pi's LAN IP instead; see PHASE2-RUNBOOK.md §6.
DEFAULT_URL="http://focus-wall.local:5050/events"
INSTALL_DIR="${HOME}/.focus-wall"
SETTINGS="${HOME}/.claude/settings.json"
URL=""
UNINSTALL=0
ASSUME_YES=0

EVENTS='["Notification","Stop","StopFailure","SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse"]'

# ---- little helpers ---------------------------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Yes/no prompt. Returns 0 for yes. Honors --yes.
confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  local reply
  read -r -p "  $prompt [y/N] " reply || reply=""
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- args -------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --url)       URL="${2:-}"; shift 2 ;;
    --url=*)     URL="${1#*=}"; shift ;;
    --dir)       INSTALL_DIR="${2:-}"; shift 2 ;;
    --dir=*)     INSTALL_DIR="${1#*=}"; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    *)           die "Unknown option: $1  (try --help)" ;;
  esac
done

WRAPPER="${INSTALL_DIR%/}/hook-send.sh"

# ---- usage poller (scheduler) ------------------------------------------------
FW_DIR="$INSTALL_DIR"
POLL_DST="${FW_DIR%/}/usage-poll.sh"
PLIST="$HOME/Library/LaunchAgents/com.focuswall.usage-poll.plist"
SD_DIR="$HOME/.config/systemd/user"

# ---- jq ---------------------------------------------------------------------
# jq is required: without it the wrapper stops stripping tool_input, leaking
# command lines and file bodies to the server. Non-negotiable.
install_jq() {
  local os; os="$(uname -s)"
  if [ "$os" = "Darwin" ]; then
    command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh then re-run, or install jq manually."
    confirm "jq is required but missing. Install it with 'brew install jq'?" || die "jq is required. Aborting."
    brew install jq
  else
    local pm="" cmd=""
    if   command -v apt-get >/dev/null 2>&1; then pm="apt-get"; cmd="sudo apt-get update && sudo apt-get install -y jq"
    elif command -v dnf     >/dev/null 2>&1; then pm="dnf";     cmd="sudo dnf install -y jq"
    elif command -v yum     >/dev/null 2>&1; then pm="yum";     cmd="sudo yum install -y jq"
    elif command -v pacman  >/dev/null 2>&1; then pm="pacman";  cmd="sudo pacman -S --noconfirm jq"
    else die "jq is required but no known package manager was found. Install jq manually, then re-run."
    fi
    confirm "jq is required but missing. Install it with '$pm'?" || die "jq is required. Aborting."
    eval "$cmd"
  fi
  command -v jq >/dev/null 2>&1 || die "jq still not available after install. Aborting."
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then install_jq; fi
  ok "jq present ($(jq --version 2>/dev/null))"
}

# ---- settings.json helpers --------------------------------------------------
# Load current settings as JSON text ('{}' if the file is absent). Aborts if
# the file exists but isn't valid JSON — we never clobber an unreadable file.
read_settings() {
  if [ -f "$SETTINGS" ]; then
    jq empty "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON. Fix or move it, then re-run."
    cat "$SETTINGS"
  else
    printf '{}'
  fi
}

# Back up then atomically write stdin to settings.json.
write_settings() {
  local new="$1"
  mkdir -p "$(dirname "$SETTINGS")"
  if [ -f "$SETTINGS" ]; then
    local bak="${SETTINGS}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$SETTINGS" "$bak"
    info "Backup: $bak"
  fi
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$new" > "$tmp"
  mv "$tmp" "$SETTINGS"
}

# Add our 8 hook entries, first removing any prior FocusWall entry (matched by
# the wrapper path) so re-runs are idempotent and existing user hooks survive.
merge_hooks() {
  read_settings | jq \
    --arg cmd "$WRAPPER" \
    --argjson events "$EVENTS" '
    .hooks = (.hooks // {})
    | reduce $events[] as $e (.;
        .hooks[$e] = (
          ((.hooks[$e] // []) | map(select((.hooks // [] | any(.command == $cmd)) | not)))
          + [ { "hooks": [ { "type": "command", "command": $cmd } ] } ]
        )
      )
  '
}

# Remove our entries and prune anything left empty.
strip_hooks() {
  read_settings | jq \
    --arg cmd "$WRAPPER" \
    --argjson events "$EVENTS" '
    .hooks = (.hooks // {})
    | reduce $events[] as $e (.;
        .hooks[$e] = ((.hooks[$e] // []) | map(select((.hooks // [] | any(.command == $cmd)) | not)))
        | if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end
      )
    | if (.hooks | length) == 0 then del(.hooks) else . end
  '
}

# ---- wrapper ----------------------------------------------------------------
# Written verbatim from IMPLEMENTATION.md §hook-send.sh, except the URL default
# line, which we template so the chosen server URL is baked in. The quoted
# heredoc prevents the wrapper's own $-expansions from firing at install time.
write_wrapper() {
  mkdir -p "$INSTALL_DIR"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Reads hook JSON on stdin, filters it down to the fields the wall uses, adds
# host metadata, and POSTs it to focus-wall.
# Installed by install-workstation.sh. Spec of record: IMPLEMENTATION.md §hook-send.sh.
# Test/debug:             hook-send.sh --transform-only < payload.json
#                         (prints the filtered payload, sends nothing)
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default baked in below by the installer
#   FOCUSWALL_TIMEOUT  curl --max-time in seconds, 1..10, default 2
#
# Privacy: only an allowlist of fields leaves this machine (see the jq filter).
# If the filter cannot run — no jq, malformed input — NOTHING is sent: the wall
# missing one event beats shipping a raw payload.

set -u
URL="${FOCUSWALL_URL:-@@FOCUSWALL_URL@@}"
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
WRAPPER_EOF

  # Bake the URL into the default line. Use bash literal replacement, not sed —
  # a URL with &, |, or \ would be mangled by sed's replacement metacharacters.
  local content; content="$(cat "$tmp")"
  rm -f "$tmp"
  content="${content/@@FOCUSWALL_URL@@/$URL}"
  printf '%s\n' "$content" > "$WRAPPER"
  chmod +x "$WRAPPER"
}

# ---- usage poller -------------------------------------------------------------
# Copies usage-poll.sh alongside the wrapper and registers a 5-minute scheduler
# (launchd on macOS, systemd --user timer on Linux) so it runs unattended. OS
# detection mirrors the rest of the installer: presence of launchctl means
# macOS, else assume Linux + systemd. Idempotent — re-running overwrites the
# copy and the scheduler unit in place (launchd is unloaded/reloaded; systemd
# is re-enabled), so a re-run never duplicates a schedule.
install_usage_poller() {
  local poll_src="$(dirname "$0")/usage-poll.sh"
  if [ ! -f "$poll_src" ]; then
    warn "usage-poll.sh not found next to the installer — skipping usage poller (run the installer from the repo to enable it)."
    return 0
  fi
  mkdir -p "$FW_DIR"
  cp "$poll_src" "$POLL_DST"
  chmod +x "$POLL_DST"

  if command -v launchctl >/dev/null 2>&1; then
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.focuswall.usage-poll</string>
  <key>ProgramArguments</key><array><string>$POLL_DST</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>FOCUSWALL_URL</key><string>${FOCUSWALL_URL:-$URL}</string>
    <key>FOCUSWALL_ACCOUNT_LABEL</key><string>${FOCUSWALL_ACCOUNT_LABEL:-$(hostname)}</string>
  </dict>
</dict></plist>
PLIST_EOF
    # unload failing is normal (nothing loaded yet on a first install) — don't
    # warn on that. load failing is NOT normal and must surface: swallowing it
    # (as this used to) leaves the plist on disk but never scheduled, so usage
    # data silently never reports with no indication why.
    launchctl unload "$PLIST" 2>/dev/null || true
    local load_err; load_err="$(launchctl load "$PLIST" 2>&1 1>/dev/null)"
    if [ -n "$load_err" ] || ! launchctl list 2>/dev/null | grep -q "com.focuswall.usage-poll"; then
      warn "launchd usage poller did not load — usage data will not report.${load_err:+ (${load_err})}"
      warn "  On recent macOS, check System Settings > General > Login Items & Extensions for a blocked 'com.focuswall.usage-poll' item, then re-run this installer."
    else
      ok "Installed launchd usage poller (every 5 min)."
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    mkdir -p "$SD_DIR"
    cat > "$SD_DIR/focuswall-usage.service" <<SVC_EOF
[Unit]
Description=Focus Wall usage poller
[Service]
Type=oneshot
Environment=FOCUSWALL_URL=${FOCUSWALL_URL:-$URL}
Environment=FOCUSWALL_ACCOUNT_LABEL=${FOCUSWALL_ACCOUNT_LABEL:-$(hostname)}
ExecStart=$POLL_DST
SVC_EOF
    cat > "$SD_DIR/focuswall-usage.timer" <<TMR_EOF
[Unit]
Description=Run Focus Wall usage poller every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
TMR_EOF
    systemctl --user daemon-reload 2>/dev/null || true
    local enable_err; enable_err="$(systemctl --user enable --now focuswall-usage.timer 2>&1 1>/dev/null)"
    if [ -n "$enable_err" ] || ! systemctl --user is-enabled focuswall-usage.timer >/dev/null 2>&1; then
      warn "systemd usage timer did not enable — usage data will not report.${enable_err:+ (${enable_err})}"
      warn "  Check 'loginctl enable-linger $(whoami)' if this is a headless/non-interactive session, then re-run this installer."
    else
      ok "Installed systemd user usage timer (every 5 min)."
    fi
  else
    warn "No launchctl or systemctl found — install the poller scheduler manually."
  fi
}

# ---- flows ------------------------------------------------------------------
do_install() {
  say "Installing Claude Focus Wall reporting on this machine…"

  # Resolve URL: --url > $FOCUSWALL_URL > prompt > default.
  if [ -z "$URL" ]; then URL="${FOCUSWALL_URL:-}"; fi
  if [ -z "$URL" ]; then
    if [ "$ASSUME_YES" = 1 ]; then
      URL="$DEFAULT_URL"
      warn "No URL given; using default $URL"
    else
      read -r -p "  Focus Wall URL [$DEFAULT_URL]: " URL || URL=""
      [ -z "$URL" ] && URL="$DEFAULT_URL"
    fi
  fi
  ok "Server URL: $URL"

  ensure_jq

  write_wrapper
  ok "Wrapper: $WRAPPER"

  local merged; merged="$(merge_hooks)"
  write_settings "$merged"
  ok "Hooks merged into $SETTINGS"

  install_usage_poller

  # Non-fatal reachability check.
  if curl -sS --connect-timeout 2 -o /dev/null "$URL" 2>/dev/null; then
    ok "Server reachable at $URL"
  else
    warn "Could not reach $URL yet — that's fine if the server isn't up. Hooks are fire-and-forget."
  fi

  # Smoke event through the installed wrapper.
  printf '{"hook_event_name":"Notification","message":"install smoke test"}' | "$WRAPPER" || true
  ok "Sent a smoke event — look for a 'Notification' on the wall."

  say ""
  say "Done. New Claude Code sessions will report to the wall. Re-run any time to change the URL."
}

do_uninstall() {
  say "Removing Claude Focus Wall reporting…"
  ensure_jq
  local stripped; stripped="$(strip_hooks)"
  write_settings "$stripped"
  ok "Removed Focus Wall hooks from $SETTINGS"

  if command -v launchctl >/dev/null 2>&1 && [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now focuswall-usage.timer 2>/dev/null || true
    rm -f "$SD_DIR/focuswall-usage.timer" "$SD_DIR/focuswall-usage.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  rm -f "$POLL_DST"
  ok "Removed usage poller and scheduler"

  if [ -d "$INSTALL_DIR" ]; then
    if confirm "Also delete $INSTALL_DIR?"; then
      rm -rf "$INSTALL_DIR"
      ok "Deleted $INSTALL_DIR"
    else
      info "Left $INSTALL_DIR in place."
    fi
  fi
  say ""
  say "Done. Focus Wall hooks removed."
}

# ---- main -------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then do_uninstall; else do_install; fi
