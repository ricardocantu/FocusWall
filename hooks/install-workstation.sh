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
#   - merges  ~/.claude/settings.json   (adds 7 hook entries; your existing
#             hooks are preserved; a timestamped .bak is kept)
#
# The wrapper body is copied verbatim from IMPLEMENTATION.md §hook-send.sh,
# which is the spec of record — keep the two in sync if you edit either.

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
# Pi's reserved LAN IP (DHCP reservation). Preferred over focuswall.local —
# mDNS proved unreliable across reboots on this network; see PHASE2-RUNBOOK.md §6.
DEFAULT_URL="http://focus-wall.local:5050/events"
INSTALL_DIR="${HOME}/.focus-wall"
SETTINGS="${HOME}/.claude/settings.json"
URL=""
UNINSTALL=0
ASSUME_YES=0

EVENTS='["Notification","Stop","SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse"]'

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

# Add our 7 hook entries, first removing any prior FocusWall entry (matched by
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
# Reads hook JSON on stdin, filters + augments it, POSTs to focus-wall.
# Installed by install-workstation.sh. Spec of record: IMPLEMENTATION.md §hook-send.sh.
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default baked in below by the installer
#   FOCUSWALL_TIMEOUT  curl --max-time, default 2

set -u
URL="${FOCUSWALL_URL:-@@FOCUSWALL_URL@@}"
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
WRAPPER_EOF

  # Bake the URL into the default line. Use bash literal replacement, not sed —
  # a URL with &, |, or \ would be mangled by sed's replacement metacharacters.
  local content; content="$(cat "$tmp")"
  rm -f "$tmp"
  content="${content/@@FOCUSWALL_URL@@/$URL}"
  printf '%s\n' "$content" > "$WRAPPER"
  chmod +x "$WRAPPER"
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
