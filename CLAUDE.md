# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

**Claude Focus Wall** — a wall-mounted Raspberry Pi dashboard showing live Claude Code session state (idle / working / waiting / done), fed by Claude Code hooks.

A working dashboard runs on real hardware: an ASP.NET minimal API (`net10.0`) under `src/FocusWall.Server/`, with xunit tests under `tests/FocusWall.Server.Tests/` (35/35 passing). `IMPLEMENTATION.md` is the spec of record — several files are transcribed from it verbatim (noted below), so keep the two in sync. The container runs on a Raspberry Pi 4 (hostname `focus-wall`) in a Chromium/labwc (Wayland) kiosk; an optional self-hosted GitHub Actions runner auto-redeploys on every push to `main`. **Networking:** the Pi is reached at `focus-wall.local` (mDNS); if mDNS is unreliable on your network, reserve a static LAN IP and point `FOCUSWALL_URL` (and the installer default) there instead.

### Features

- **Dashboard views** (vanilla JS, no build step; all share `wwwroot/sse.js`): the per-session **grid** (`GET /`), a composed **hero dashboard** (`GET /hero`), a **kiosk wall** (`GET /wall`) that wraps the hero in two RSS news tickers, a phone-optimized **mobile** view (`GET /mobile`), and a **usage** page (`GET /usage`). Details under *Architecture* below.
- **Notification channels** — optional, fire on any per-session transition to `waiting`, with per-session cooldown + optional quiet hours, and self-disable cleanly (log one line, dashboard unaffected) when unconfigured:
  - **Discord push** — `DiscordNotifier` POSTs an amber embed to a webhook (`DISCORD_WEBHOOK_URL`). Transcribed verbatim from `DISCORD.md`; `DISCORD_SETUP_CHECKLIST.md` is the turn-on guide.
  - **Echo Show announcements** — `EchoAnnouncer` fires a Voice Monkey webhook to speak "Claude is waiting for your input in {project}." Transcribed verbatim from `ECHO_SHOW.md`; `ECHO_SETUP_CHECKLIST.md` is the turn-on guide.
- **Snooze** — `POST /snooze?minutes=N` (`0` clears) silences the waiting alert as a global presentation overlay (see *Snooze* below). The button lives on `/mobile`.
- **Usage limits** — per-workstation pollers report each Claude account's subscription-limit gauges to `/usage` (see *Usage limits page* below).
- **Slack panel** — the hero's per-account Slack panel shows your own unread badge across 1–2 workspaces. Optional / best-effort (see *Slack panel* below); `SLACK_SETUP_CHECKLIST.md` is the turn-on guide.

Secrets (Discord / Voice Monkey / Slack) are supplied as GitHub Actions **repository secrets**: `deploy.yml`'s deploy step injects them as env vars (`${{ secrets.* }}`), which `docker-compose.yml` interpolates into the container (`${VAR}`). The gitignored `.env` next to `docker-compose.yml` — preserved on the runner across deploys by the workflow's `clean: false` — is the local/manual fallback. Never committed, never logged (error paths log only the upstream status/marker, never the token); any unset secret just disables that one channel. See `DEPLOYMENT.md` § 4a step 6 and the `*_SETUP_CHECKLIST.md` files.

### Workstation installer

**`hooks/install-workstation.sh`** — a self-contained, tested installer (macOS + Linux) that writes the `hook-send.sh` wrapper to `~/.focus-wall/`, merges the 7 hook entries into `~/.claude/settings.json` (idempotent, `--uninstall`, jq auto-install, existing hooks preserved), and installs the usage poller (launchd agent on macOS / systemd `--user` timer on Linux). It embeds the `hook-send.sh` body verbatim from `IMPLEMENTATION.md §hook-send.sh` — the spec of record, so keep the two in sync. **`hooks/install-workstation.ps1`** is the Windows PowerShell port (native JSON + `Invoke-RestMethod`, no jq/curl; a Scheduled Task runs the poller). `hooks/README.md` is the coworker-facing guide for both platforms.

**Both `.ps1` files must stay ASCII-only:** PowerShell 5.1 reads a BOM-less file as the ANSI codepage (CP1252) and mojibakes any non-ASCII (em-dashes, `§`) into a byte sequence ending in a curly quote it treats as a string delimiter — closing strings early and producing misleading parse errors far from the real line (e.g. a bogus "Catch block must be the last catch block"). A `MAINTAINERS:` header comment in each file records this.

Read order for context: `README.md` → `ARCHITECTURE.md` → `IMPLEMENTATION.md`. `HARDWARE.md`/`DEPLOYMENT.md` cover the Pi; `ECHO_SHOW.md`/`DISCORD.md` are optional notification channels. **`GETTING_STARTED.md` is the sequenced, do-this-now walkthrough** — work from that file rather than re-deriving an order from `IMPLEMENTATION.md` yourself.

## Commands (per IMPLEMENTATION.md)

```bash
# Run the server locally (listens on http://localhost:5050)
cd src/FocusWall.Server && dotnet run

# Unit tests (EventStore state machine)
dotnet test tests/FocusWall.Server.Tests

# Smoke test — send a fake hook event
echo '{"hook_event_name":"Notification","message":"smoke test"}' | ./hooks/hook-send.sh
curl http://localhost:5050/events | jq .

# Container (project root)
docker compose up -d

# Cross-build for the Pi (manual fallback — normal path is push-to-deploy, see below)
docker buildx build --platform linux/arm64 -t focus-wall:arm64 --load ./src/FocusWall.Server
```

Unit tests (xunit, `tests/FocusWall.Server.Tests`) cover the `EventStore` state machine — loudest-wins, waiting-holds, and the broadcast-on-any-transition regression guard — plus the RSS parser, `UsageStore`, snooze, and the pure Slack reducers (`SlackCounts`/`SlackProfile`). End-to-end testing is done by piping simulated hook JSON through `hooks/hook-send.sh` — the single-session and multi-session scripts are in `IMPLEMENTATION.md` § "Testing approach". The multi-session "loudest wins" script is the Phase 1 acceptance test.

## Architecture

Single data path: Claude Code hooks → `hooks/hook-send.sh` (injects `_meta.hostname`/`cwd`, curl POST) → `POST /events` on an ASP.NET minimal API (.NET 10) → in-memory `EventStore` → Server-Sent Events (`GET /events/stream`) → vanilla-JS dashboard in `wwwroot/` rendered by a Chromium kiosk on the Pi. Optional background services (Echo Show via Voice Monkey, Discord webhook) fire on transitions to `waiting`.

The server is the single source of truth. Status is **derived from event history on the server**, never sent by Claude Code directly.

**Dashboard views** (vanilla JS, no build step; all share `wwwroot/sse.js` — the EventSource connect/reconnect/`?kiosk=1`-cursor module):

- **`GET /` — per-session grid** (`index.html` + `grid.js`): one card per session with status/project/host/time-in-status, a git-branch tag (from the wrapper's `_meta.branch`), a session-age line (server `StartedAt`), and a truncated "working on" label (first line of the prompt, ≤60 chars, on working + waiting cards). Waiting cards are amber + pulsing with their Notification message; working cards show a live tool **breadcrumb** (last 3 tools, `Read → Edit → Bash`) driven off the `event` stream because `status` snapshots are coalesced. The live maps (`activity`, `prompts`) reset on SSE `open` so replays don't stack stale state.
- **`GET /hero` — composed dashboard** (`hero.html` + `app.js` + `app.css`): a 12-col layout — a 9-col loudest-status hero + a 3-col **per-account Slack panel**, an "other sessions" strip, and a **bottom band that crossfades metrics ⇄ recent-events ⇄ usage** every 15s (`?rotate=` overrides; the usage pane reuses `usage.js`).
- **`GET /wall` — kiosk wall**: the two RSS tickers (news pinned top, sports along the bottom scrolling in reverse so the two read as distinct) wrapping a single `/hero?kiosk=1` iframe. `GET /rss` returns `{news, sports}`, each list fed by `RssService` from `appsettings.json` → `Rss:NewsFeeds`/`Rss:SportsFeeds`, merged newest-first and capped at `Rss:MaxItems` per row. Feeds are data, not code.
- **`GET /mobile` — phone companion** (`mobile.html` + `mobile.js` + `mobile.css`): a read-only sticky "loudest status" glance banner above a scrollable single-column session list. Reuses `sse.js` and the grid's `.card` styling verbatim; hosts the snooze button. Its small helpers (`keyOf`/`deriveActivity`/`fmtSince`/`pushActivity`) are deliberately duplicated from `grid.js` to leave the load-bearing grid untouched.
- **`GET /usage` — usage limits** (`usage.html` + `usage.js` + `usage.css`): per-account subscription-limit gauges (see *Usage limits page* below).

The kiosk loads a view with `?kiosk=1`, which hides the cursor in JS — the reliable mechanism on Wayland, where `unclutter` doesn't work. Full file blocks in `IMPLEMENTATION.md` § "Phase 1 — frontend".

### Core invariant: per-session state machines + "loudest wins"

This is the load-bearing design decision — a single global status would let a working session mask a waiting one.

- Session identity is `(hostname, session_id)` — hostname from the wrapper's `_meta`, `session_id` from the hook payload. Sub-agents share the parent's `session_id` intentionally.
- Each session runs its own state machine: `Notification` → waiting, `Stop` → done, tool/prompt events → working, `SessionStart`/`SessionEnd` → idle (a freshly started or just-`/clear`ed session is present but not working until its first prompt). Done ages to idle after 30s; working ages to idle after 15 min of silence (killed-session guard — deliberately generous because long tool calls emit nothing between Pre/PostToolUse); waiting never decays. Sessions prune after 2h silence or on `SessionEnd`.
- Global status = loudest across sessions, priority `waiting(4) > working(3) > done(2) > idle(1)`. If **any** session is waiting, the hero shows "Waiting for you" no matter what other sessions are doing. Logic lives in `EventStore.ComputeGlobalStatusLocked`.
- Status broadcasts must fire on **any per-session transition** (compared via a session-status signature), not just when the global loudest value changes — coalescing on the global value alone swallows a second session entering "waiting", which breaks the notifiers and mislabels the hero. There's a regression test for this.

### Usage limits page

`GET /usage` shows each Claude account's subscription-limit gauges — the data behind Claude Code's `/usage` command (session/5-hour, weekly, and per-model scoped limits). A per-workstation poller (`hooks/usage-poll.sh` / `.ps1`, every 5 min) reads the machine's **local** OAuth token (macOS Keychain `security -s "Claude Code-credentials"`, or `~/.claude/.credentials.json` on Linux/Windows), calls Anthropic's `GET /api/oauth/usage`, reduces the response to the `limits[]` array, and POSTs **only that summary — never the token** to `POST /usage/report`. The token never leaves the workstation and is never logged (error paths report a `no_token`/`auth_expired` status instead). The server keeps the latest per-host summary in `UsageStore` (keyed by hostname, stale after 15 min) and serves `GET /usage/state` (polled every 30s by the page).

- **Serialization seam:** `GET /usage/state` emits camelCase entry fields but **snake_case limit fields** (`resets_at`/`is_active`) because `[JsonPropertyName]` overrides the Web camelCase policy; `usage.js` reads them that way — don't "fix" one side without the other. (Contrast: `snoozedUntil` and the Slack endpoint are plain camelCase.)
- **launchd/systemd gotcha:** the poller must POST **synchronously** — do NOT background the report `curl` with `&`. launchd (and systemd `--user`) tear down the job's process group the instant the script exits, which kills an orphaned background `curl` before it reaches the server, so the report **silently never arrives** even though the job exits 0 (an interactive shell doesn't do this teardown, so a manual run misleadingly works). This is the opposite of `hook-send.sh`, which must stay backgrounded to never slow Claude Code — nothing waits on the poller, so a bounded (`-m 5`) blocking POST is correct. (`Invoke-RestMethod` in the `.ps1` port is already synchronous.)

### Snooze

`POST /snooze?minutes=N` (`0` clears) silences the "waiting" alert for N minutes — the hero/mobile banners show "Snoozed (Nm left)" (calm/dimmed, no pulse, `data-status="snoozed"`) and the notifiers suppress push, while Notification events still log. It is a **global presentation/suppression overlay, not a state-machine transition** (preserves the core invariant): `EventStore` holds `_snoozedUntil` and surfaces `SnoozedUntil` on `GlobalStatus`, but per-session `Status` values stay honest (a snoozed session is still `waiting`; the client renders the overlay and `DiscordNotifier`/`EchoAnnouncer` check `SnoozedUntil`, mirroring their quiet-hours mark-as-notified bookkeeping so nothing back-fires when snooze ends). `Snooze()` pushes a fresh status immediately; expiry flips the status signature (a `|snooze=` bit in `ComputeSignatureLocked`) so a heartbeat rebroadcasts the un-snoozed status, and clients also count down locally and self-clear. The button lives on `/mobile` (the wall kiosk is deliberately cursorless).

### Slack panel

The hero's per-account Slack panel shows *your own* unread badge across 1–2 workspaces — a presence dot + per-category unread rows (Mentions / Channels / DMs / Threads) + custom status, with a per-account `⚠ reconnect` on token error. `SlackService` (a `BackgroundService`, mirrors `RssService`) polls Slack's **internal `client.counts`** per workspace using a browser **session token (`xoxc`) + `d` cookie**, reduced by the pure, unit-tested `SlackCounts.Reduce`; `SlackProfile` parses two best-effort follow-up calls (`users.getPresence` / `users.profile.get`) whose failure leaves presence/status null but never drops the counts. `GET /slack/state` returns plain camelCase; `app.js` polls it every 30s and renders `textContent`-only (only counts leave Slack — no message content is read or stored). One failing/expired workspace can't blank the others.

- **Mentions vs DMs:** `SlackCounts.Reduce` exposes `ChannelMentions` (channels only) and `DmMentions` (mpims + ims); the panel's Mentions row reads `channelMentions` and the DMs row reads `dmMentions`. The combined `Mentions` field / `totalMentions` aggregate sum `mention_count` across *every* section (Slack sets `mention_count` on DMs too, since a DM has no `@mention` concept) and are unchanged — keep both.
- **CSS load-bearers** (don't regress): `.bottom-band { grid-row: 4 }` (else it auto-places into an `auto` track and collapses to 0px whenever the sessions strip is `hidden` — the common 0–1-session wall state, since every `.band-panel` is `position:absolute`); `.sessions-strip[hidden] { display:none }` (the author `display:flex` rule was overriding the UA `[hidden]` rule, leaking an empty "Other sessions" header); and `.dash-row:has(.slack-panel[hidden]) .hero { grid-column: 1 / 13 }` (so a hidden/unconfigured panel doesn't leave the hero stuck at 9 cols with dead space).
- **Optional / best-effort:** `client.counts` is undocumented and not an officially supported integration — leave the workspace secrets unset and the panel stays hidden with nothing else affected. The session token expires on full sign-out / password change (weeks–months; re-grab when the panel shows `?`); the reducer safe-fails on shape drift (shows `?`, never crashes the loop).

### Other conventions

- Hook payloads pass through mostly intact — treat unknown fields as data; don't assume shape beyond `hook_event_name`. One deliberate exception: the wrapper strips `tool_input` down to `file_path` so Bash command lines and Write file bodies never leave the workstation. Don't remove that filter.
- Hooks are fire-and-forget: the wrapper always exits 0 and backgrounds a bounded curl, so a dead or unreachable server never breaks or slows Claude Code. Preserve this. The wrapper must also stay portable to macOS (BSD date has no GNU `%N`).
- Status colors are defined once (server-side mapping, mirrored as CSS vars): waiting `#BA7517` (amber deliberately, not red), working `#378ADD`, done `#1D9E75`, idle `#888780`.
- SSE replays the ring buffer (last 200 events) + current status on connect; the client resets its log and counters on every `open` so replays never duplicate rows or double-count metrics. A 15s server heartbeat keeps connections alive. `sse.js` also runs a **watchdog**: it tracks a `lastActivity` timestamp (bumped on every open/status/event/heartbeat frame) and hard-reloads the page after 120s of total silence — the reconnect-on-`error` path handles clean drops, this catches a wedged Chromium renderer that a JS-level reconnect can't recover. 120s is 8× the heartbeat, so a healthy stream never trips it; the reload is guarded to the visible tab.
- Log rows are built with `textContent`, never `innerHTML` — `POST /events` is unauthenticated, so payload fields are attacker-controlled by anyone on the LAN. The RSS ticker titles and Slack panel text are likewise `textContent`-only (untrusted).
- The kiosk loads `/wall?kiosk=1`, which hides the cursor in JS — the reliable mechanism on Wayland, where `unclutter` doesn't work.

### Deploy

Optional CI/CD: a self-hosted GitHub Actions runner living on the Pi (`DEPLOYMENT.md` § 4a; workflow documented in `IMPLEMENTATION.md`) redeploys on every push to `main` via `docker compose up -d --build`, run locally on the Pi — no registry, no inbound network access. The deploy is **health-gated with auto-recovery** (hardened after a corrupt build-cache layer once shipped a 0-byte `runtimeconfig.json` that crash-looped the .NET host and blanked the wall — the cause was Docker's build cache, not the app code): after the cached build it polls `/healthz` for 60s; if the container isn't serving it **rebuilds once with `--no-cache`** and re-checks. Only when `/healthz` answers does the `Reload kiosk browser` step `pkill` Chromium (matched on `--kiosk`), so the labwc autostart respawn loop relaunches it on the fresh page. If it is **still** unhealthy the job **fails loudly** and the kiosk step is skipped — so a broken deploy leaves the **last good page** on the wall instead of blanking it. A final `if: always()` step prunes the build cache (≤2GB) + dangling images. It deliberately does **not** reboot the Pi: the runner *is* the Pi, so a reboot would kill the job mid-run.

**The self-hosted-runner path requires the repo to stay private** — GitHub's own warning is that a self-hosted runner on a public repo lets PR-submitted workflow code execute on the runner, which here is physical hardware. The manual `git pull && docker compose up -d --build` path (`DEPLOYMENT.md` § 4b) works as a fallback and needs no CI.

### Deliberate non-goals (don't add these)

No framework on the frontend, no database (in-memory ring buffer), no auth/TLS (trusted-LAN threat model), no cloud sync, no observability stack. `ARCHITECTURE.md` § "Technology decisions" records the reasoning — push back there before swapping any of them. The RSS ticker and the Slack panel are the server's only outbound egress — RSS fetches configured public feeds; the Slack poller calls `slack.com`'s internal `client.counts` per configured workspace. Feeds live in `appsettings.json` (data, not code); Slack workspace tokens are GitHub Actions secrets injected at deploy (never committed).
