# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

**Claude Focus Wall** — a wall-mounted Raspberry Pi dashboard showing live Claude Code session state (idle / working / waiting / done), fed by Claude Code hooks.

The server lives under `src/FocusWall.Server/` (ASP.NET minimal API, `net10.0`): `Program.cs`, `EventStore.cs`, `HeartbeatService.cs`, `RssParser.cs`, `RssService.cs`, `DiscordNotifier.cs`, `EchoAnnouncer.cs`, and `wwwroot/`. xunit tests are under `tests/FocusWall.Server.Tests/` (the `EventStore` state machine + the RSS parser). `IMPLEMENTATION.md` is the spec of record — several code files were transcribed from it verbatim, so keep the two in sync when you change them.

Two optional notification channels ship alongside the dashboard, both structurally identical background services that subscribe to the same status stream and fire on any per-session transition to `waiting`:

- **`DiscordNotifier`** POSTs an amber embed to a Discord webhook. Transcribed verbatim from `DISCORD.md` (that section stays the spec of record). Self-disables (logs one line, dashboard unaffected) when `DISCORD_WEBHOOK_URL` is unset. The webhook URL is never logged.
- **`EchoAnnouncer`** fires a Voice Monkey webhook (HTTPS GET) that makes an Echo Show speak "Claude is waiting for your input in {project}." Transcribed verbatim from `ECHO_SHOW.md § EchoAnnouncer.cs`. Self-disables when `VOICEMONKEY_TOKEN`/`VOICEMONKEY_DEVICE` are unset. The token is never logged.

Both take their secrets from environment variables (a gitignored `.env` next to `docker-compose.yml`), never from committed files. `DISCORD_SETUP_CHECKLIST.md` and `ECHO_SETUP_CHECKLIST.md` are the turn-on guides.

The workstation-side installer is **`hooks/install-workstation.sh`** (macOS + Linux) — a self-contained, tested installer that writes the `hook-send.sh` wrapper to `~/.focus-wall/` and merges the 7 hook entries into `~/.claude/settings.json` (idempotent, `--uninstall`, jq auto-install, existing hooks preserved). It embeds the `hook-send.sh` body verbatim from `IMPLEMENTATION.md § hook-send.sh` — that section stays the spec of record, so keep the two in sync. A **Windows PowerShell port** (`hooks/install-workstation.ps1`, embedding `hook-send.ps1`) does the same using native PowerShell JSON + `Invoke-RestMethod` (no jq/curl needed) and runs on Windows PowerShell 5.1 or PowerShell 7+.

**Both `.ps1` files must stay ASCII-only.** PS 5.1 reads a BOM-less file as the ANSI codepage (CP1252) and mojibakes any non-ASCII (em-dashes, `§`) into a byte sequence ending in a curly quote it treats as a string delimiter, which closes strings early and produces misleading parse errors far from the real line (e.g. a bogus "Catch block must be the last catch block"). A `MAINTAINERS:` header comment in each file records this.

`hooks/README.md` is the coworker-facing guide for the installer (both platforms). The default target is `http://focus-wall.local:5050/events` — override with `--url` (or the `FOCUSWALL_URL` env var) to point at your Pi's LAN IP if mDNS is unreliable on your network.

Read order for context: `README.md` → `ARCHITECTURE.md` → `IMPLEMENTATION.md`. `HARDWARE.md`/`DEPLOYMENT.md` cover the Pi; `ECHO_SHOW.md`/`DISCORD.md` are the optional notification channels. `GETTING_STARTED.md` is the sequenced, do-this-now walkthrough of the local build — when actually starting to build, work from that file rather than re-deriving an order from `IMPLEMENTATION.md`.

## Commands (per IMPLEMENTATION.md)

```bash
# Run the server locally (listens on http://localhost:5050)
cd src/FocusWall.Server && dotnet run

# Unit tests (EventStore state machine + RSS parser)
dotnet test tests/FocusWall.Server.Tests

# Smoke test — send a fake hook event
echo '{"hook_event_name":"Notification","message":"smoke test"}' | ./hooks/hook-send.sh
curl http://localhost:5050/events | jq .

# Container (project root)
docker compose up -d

# Cross-build for the Pi (manual fallback)
docker buildx build --platform linux/arm64 -t focus-wall:arm64 --load ./src/FocusWall.Server
```

Unit tests (xunit, `tests/FocusWall.Server.Tests`) cover the `EventStore` state machine — loudest-wins, waiting-holds, and the broadcast-on-any-transition regression guard. End-to-end testing is done by piping simulated hook JSON through `hooks/hook-send.sh` — the single-session and multi-session scripts are in `IMPLEMENTATION.md` § "Testing approach". The multi-session "loudest wins" script is the Phase 1 acceptance test.

## Architecture

Single data path: Claude Code hooks → `hooks/hook-send.sh` (injects `_meta.hostname`/`cwd`, curl POST) → `POST /events` on an ASP.NET minimal API (~200 lines, .NET 10) → in-memory `EventStore` → Server-Sent Events (`GET /events/stream`) → vanilla-JS dashboard in `wwwroot/` rendered by a Chromium kiosk on the Pi. Optional background services (Echo Show via Voice Monkey, Discord webhook) fire on transitions to `waiting`.

The server is the single source of truth. Status is **derived from event history on the server**, never sent by Claude Code directly.

**Dashboard views** (vanilla JS, no build step; all share `wwwroot/sse.js` — the EventSource connect/reconnect/`?kiosk=1`-cursor module):

- `GET /` — the per-session **grid** (`index.html` + `grid.js`): one card per session with status/project/host/time-in-status, a git-branch tag (from the wrapper's `_meta.branch`), a session-age line (server `StartedAt`), and a truncated "working on" label (first line of the prompt, ≤60 chars). Waiting cards are amber + pulsing; working cards show a live activity **breadcrumb** (last 3 tools, `Read → Edit → Bash`) driven off the `event` stream because `status` snapshots are coalesced. The live maps (`activity`, `prompts`) reset on SSE `open` so replays don't stack stale state.
- `GET /hero` — the single **loudest-status hero** (`hero.html` + `app.js`) plus the scrolling event log.
- `GET /wall` — a kiosk rotator that alternates the grid and hero views in two iframes every 30s (`?rotate=<seconds>` overrides), with a configurable RSS news ticker (`GET /rss`, fed by `RssService` from `appsettings.json` → `Rss:Feeds`) pinned along the top. The rotator keeps each view's SSE alive across flips.
- `GET /mobile` — a phone-optimized read-only view (`mobile.html` + `mobile.js` + `mobile.css`): a sticky "loudest status" glance banner above a scrollable single-column session list. Reuses `sse.js` verbatim and the grid's `.card` classes/colors from `app.css`; `mobile.css` only overrides layout. Purely additive — no server-state changes. Its helpers (`keyOf`/`deriveActivity`/`fmtSince`/`pushActivity`) are deliberately duplicated from `grid.js` to leave the load-bearing grid untouched.

The kiosk's `/?kiosk=1` lands on the grid; use `/hero?kiosk=1` for the hero or `/wall?kiosk=1&rotate=30` for the rotator. Full file blocks are in `IMPLEMENTATION.md` § "Phase 1 — frontend". All views are LAN-only (trusted-LAN threat model).

### Core invariant: per-session state machines + "loudest wins"

This is the load-bearing design decision — a single global status would let a working session mask a waiting one.

- Session identity is `(hostname, session_id)` — hostname from the wrapper's `_meta`, `session_id` from the hook payload. Sub-agents share the parent's `session_id` intentionally.
- Each session runs its own state machine: `Notification` → waiting, `Stop` → done, tool/prompt events → working, `SessionStart`/`SessionEnd` → idle (a freshly started or just-`/clear`ed session is present but not working until its first prompt). Done ages to idle after 30s; working ages to idle after 15 min of silence (killed-session guard — deliberately generous because long tool calls emit nothing between Pre/PostToolUse); waiting never decays. Sessions prune after 2h silence or on `SessionEnd`.
- Global status = loudest across sessions, priority `waiting(4) > working(3) > done(2) > idle(1)`. If **any** session is waiting, the hero shows "Waiting for you" no matter what other sessions are doing. Logic lives in `EventStore.ComputeGlobalStatusLocked`.
- Status broadcasts must fire on **any per-session transition** (compared via a session-status signature), not just when the global loudest value changes — coalescing on the global value alone swallows a second session entering "waiting", which breaks the notifiers and mislabels the hero. There's a regression test for this.

### Other conventions

- Hook payloads pass through mostly intact — treat unknown fields as data; don't assume shape beyond `hook_event_name`. One deliberate exception: the wrapper strips `tool_input` down to `file_path` so Bash command lines and Write file bodies never leave the workstation. Don't remove that filter.
- Hooks are fire-and-forget: the wrapper always exits 0 and backgrounds a bounded curl, so a dead or unreachable server never breaks or slows Claude Code. Preserve this. The wrapper must also stay portable to macOS (BSD date has no GNU `%N`).
- Status colors are defined once (server-side mapping, mirrored as CSS vars): waiting `#BA7517` (amber deliberately, not red), working `#378ADD`, done `#1D9E75`, idle `#888780`.
- SSE replays the ring buffer (last 200 events) + current status on connect; the client resets its log and counters on every `open` so replays never duplicate rows or double-count metrics. A 15s server heartbeat keeps connections alive. `sse.js` also runs a **watchdog**: it tracks a `lastActivity` timestamp (bumped on every open/status/event/heartbeat frame) and hard-reloads the page after 120s of total silence — the reconnect-on-`error` path handles clean drops, this catches a wedged Chromium renderer that a JS-level reconnect can't recover. 120s is 8× the heartbeat, so a healthy stream never trips it; the reload is guarded to the visible tab.
- Log rows are built with `textContent`, never `innerHTML` — `POST /events` is unauthenticated, so payload fields are attacker-controlled by anyone on the LAN.
- The kiosk loads `/?kiosk=1`, which hides the cursor in JS — the reliable mechanism on Wayland, where `unclutter` doesn't work.

### Deploy

The primary path is manual: on the Pi, `git pull && docker compose up -d --build` (`DEPLOYMENT.md` § 4b). The full walkthrough — OS flash → Docker → kiosk → wall mount — is in `DEPLOYMENT.md`.

An **optional** auto-deploy path uses a self-hosted GitHub Actions runner living on the Pi (`DEPLOYMENT.md` § 4a; workflow YAML in `IMPLEMENTATION.md` § "Phase 2 — containerize") that redeploys on every push to `main` via `docker compose up -d --build`, run locally on the Pi — no registry, no inbound network access. **The workflow file is intentionally not included in this repository, and enabling it requires the repo to stay private** — GitHub's own warning is that a self-hosted runner on a public repo lets PR-submitted workflow code execute on the runner, which here is physical hardware. Only add the workflow to a fork you keep private.

### Deliberate non-goals (don't add these)

No framework on the frontend, no database (in-memory ring buffer; SQLite is a Phase 6c option), no auth/TLS (trusted-LAN threat model), no cloud sync, no observability stack. `ARCHITECTURE.md` § "Technology decisions" records the reasoning — push back there before swapping any of them. The RSS ticker adds the server's only outbound egress — it fetches configured public feeds. Feed titles are rendered with `textContent` (untrusted). Feeds are kept in `appsettings.json` so they are data, not code.
