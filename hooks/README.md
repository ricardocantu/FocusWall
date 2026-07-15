# Claude Focus Wall — workstation setup

A **Focus Wall** is a shared dashboard that shows, at a glance, what everyone's
Claude Code sessions are doing right now — **idle**, **working**, **waiting for
you**, or **done**. This folder has the one script you run to make *your*
machine show up on it.

## Install

You only need **`install-workstation.sh`** — it's self-contained. Grab that one
file, then run it with your team's wall URL:

```bash
chmod +x install-workstation.sh
./install-workstation.sh --url http://focus-wall.local:5050/events
```

Run it with no `--url` and it'll prompt you (default `http://focus-wall.local:5050/events`;
use the Pi's LAN IP if mDNS is unreliable on your network).
That's it — new Claude Code sessions start reporting automatically. No repo
clone, no build, nothing to keep running.

**Requirements:** macOS or Linux, and [`jq`](https://jqlang.github.io/jq/). If
`jq` is missing the installer offers to install it for you (`brew` on macOS;
`apt`/`dnf`/`yum`/`pacman` on Linux).

### Windows

On Windows use the PowerShell port instead — **`install-workstation.ps1`**. It's
the same idea and self-contained, but needs **no `jq` and no `curl`**: PowerShell
does the JSON filtering and the POST natively. Windows PowerShell 5.1 (ships with
Windows) or PowerShell 7+ both work.

```powershell
# From a PowerShell prompt, in the folder with the script:
.\install-workstation.ps1 -Url http://focus-wall.local:5050/events
```

Run it with no `-Url` and it prompts you (same default). It writes the wrapper to
`%USERPROFILE%\.focus-wall\hook-send.ps1` and merges the same 7 hook entries into
`%USERPROFILE%\.claude\settings.json` (existing hooks preserved, timestamped
`.bak` kept). If PowerShell blocks the script with an execution-policy error,
launch it as `powershell -ExecutionPolicy Bypass -File .\install-workstation.ps1 …`.

Run the Windows installer **from the repo's `hooks\` folder** (or keep
`usage-poll.ps1` next to it) and it also sets up the usage poller: it copies
`usage-poll.ps1` to `%USERPROFILE%\.focus-wall\`, writes a tiny `usage-poll.vbs`
shim (so the run is fully window-less), and registers a per-user Scheduled Task
named **`FocusWall Usage Poll`** (every 5 minutes, plus at logon — no admin
needed). If `usage-poll.ps1` isn't next to the installer it warns and skips the
poller; the hooks still install fine from the single file.

Smoke-test the wrapper by hand after installing:

```powershell
'{"hook_event_name":"Notification","message":"smoke test"}' | powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.focus-wall\hook-send.ps1"
```

One deliberate platform difference: the Windows wrapper POSTs **synchronously**
with a short timeout (default 2s, override with `FOCUSWALL_TIMEOUT`) — there's no
clean, window-less way to background it as the Unix wrapper does. It still always
exits 0 and swallows every error, so a down server can't break Claude Code; and
because the default URL is an IP there's no DNS stall, so a reachable wall costs
only a few milliseconds. Uninstall with `.\install-workstation.ps1 -Uninstall`.

## What it changes

- Writes the hook wrapper to `~/.focus-wall/hook-send.sh` (the wall URL is baked
  into it).
- Merges 7 hook entries into `~/.claude/settings.json`. **Your existing hooks
  and settings are preserved** — a timestamped `.bak` is saved before any change.
- Copies the usage poller to `~/.focus-wall/` and registers a scheduler that
  runs it every 5 minutes (a launchd agent on macOS, a systemd `--user` timer
  on Linux, a per-user Scheduled Task `FocusWall Usage Poll` on Windows).

Re-run it any time to point at a different wall; it won't create duplicates.

## Usage poller

Alongside the hooks, the installer sets up a small poller that shows your
Claude usage limits (5-hour / weekly session gauges) on the wall. Every 5
minutes it reads this machine's Claude Code OAuth token (from the macOS
Keychain, or `~/.claude/.credentials.json` on Linux and Windows), calls Anthropic's usage
endpoint, reduces the response to just the limit gauges, and POSTs that
summary to the wall server. **The token itself never leaves this machine** —
only the reduced summary (percentages, reset times, which limit is active) is
sent, the same way the hooks strip `tool_input` before sending. If no token is
found, or Anthropic's endpoint rejects it, the poller reports a status (
`no_token` / `auth_expired`) instead of limit data and keeps running — it never
blocks or errors out the scheduler.

By default the wall groups usage by short hostname. On a shared machine, or if
you want a friendlier label than the hostname, set `FOCUSWALL_ACCOUNT_LABEL`
before installing:

```bash
FOCUSWALL_ACCOUNT_LABEL="my-laptop" ./install-workstation.sh --url http://focus-wall.local:5050/events
```

Uninstalling removes the scheduler (launchd agent / systemd timer / Windows
scheduled task) and the copied poller along with the hooks.

## What leaves your machine (and what doesn't)

Each Claude Code lifecycle event sends a small JSON blob to the wall server:
which event fired, your short hostname, and the project directory name — enough
to render a status dot and a session badge.

**Your code and commands stay local.** Before anything is sent, the wrapper
strips tool details down to a bare `file_path` — so Bash command lines and the
contents of files you write **never leave your workstation**. The server is
plain HTTP on your trusted LAN, so only run this against a wall you trust.

## Uninstall

```bash
./install-workstation.sh --uninstall
```

Removes the Focus Wall hooks from `~/.claude/settings.json` (leaving your own
hooks untouched) and offers to delete `~/.focus-wall`.

## Options

```
--url URL     Focus Wall events endpoint
--uninstall   Remove the Focus Wall hooks (and optionally ~/.focus-wall)
--dir PATH    Install location for the wrapper (default ~/.focus-wall)
--yes         Non-interactive: assume yes, skip prompts (for scripted rollout)
--help        Full usage
```

## Troubleshooting

- **Nothing shows on the wall.** Make sure the server is actually up and the
  `--url` is reachable from your machine (`curl <url>` should connect). Hooks are
  fire-and-forget by design — a down server never slows or breaks Claude Code, so
  no error surfaces locally.
- **Badge says `unknown` / too much detail sent.** That means `jq` wasn't
  available at send time. Install `jq` and re-run the installer.
- **Using the VS Code / JetBrains extension.** Works the same — the URL is baked
  into the wrapper, not read from your shell, so GUI-launched sessions report
  correctly.
