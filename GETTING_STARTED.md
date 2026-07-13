# Getting Started

A single top-to-bottom path through this project. It doesn't duplicate code or steps that already live in the other docs — it sequences them and tells you exactly which file to open at each point.

**Read this once, then work through it top to bottom.** Stop at each checkpoint and confirm it before moving on.

## Where the other docs fit

| Doc | Use it for |
|-----|------------|
| `README.md` | The 2-minute pitch. Skip if you're already sold. |
| `ARCHITECTURE.md` | *Why* things are built this way — read once before you touch code, re-read if you're about to change the state machine. |
| `IMPLEMENTATION.md` | Every file's actual contents. This guide tells you *when* to copy which block from it. |
| `HARDWARE.md` | Buying the Pi and monitor. Only relevant once the local build works on your laptop. |
| `DEPLOYMENT.md` | Flashing and configuring the Pi. Start this after Phase 1 (below) is done. |
| `ECHO_SHOW.md` / `DISCORD.md` | Optional notification channels — Phase 6, after the wall itself works. Don't start these yet. |

## Start here: Phase 0 — Prerequisites

Install these on your workstation before you begin:

- **.NET 10 SDK** — the project targets **`net10.0`** (a newer SDK installed alongside an older one is harmless).
- **`jq`** — the hook wrapper uses it to filter and augment payloads (`brew install jq` on macOS).
- **Docker** — Docker Desktop or Docker Engine, for the Pi build later.

Two choices you can defer until you reach `DEPLOYMENT.md`: where the server will live long-term (the Pi, a small Linux VM, or existing infrastructure), and the dashboard hostname (`focus-wall.local` is the suggested default the other docs assume).

Once the SDK, `jq`, and Docker are installed, you can start Phase 1.

## Phase 1 — MVP server and dashboard (do this today)

Goal for this session: hooks on your laptop fire a curl, a local server receives it, a browser tab shows live updates. This is entirely local — no Pi needed yet.

### Step 1 — Scaffold the project

Follow `IMPLEMENTATION.md` § "Phase 1 — project bootstrap" (`mkdir focus-wall && cd focus-wall && git init && dotnet new web …`).

**One thing to confirm after you scaffold:** the project is pinned to `net10.0` everywhere — the `.csproj` in `IMPLEMENTATION.md` sets `<TargetFramework>net10.0</TargetFramework>` and the Phase 2 Dockerfile bases match (`mcr.microsoft.com/dotnet/sdk:10.0` / `aspnet:10.0`). With SDK `10.0.201`, `dotnet new web` already scaffolds a `net10.0` template, so paste the `.csproj` block as-is and confirm it reads `net10.0`. Don't downgrade any single file to `net9.0` in isolation — the container build fails on a framework mismatch if the `.csproj` and the Dockerfile bases disagree.

### Step 2 — Copy in the server files

From `IMPLEMENTATION.md`, in order:
1. `Program.cs`
2. `EventStore.cs`
3. `HeartbeatService.cs`
4. `wwwroot/index.html`, `wwwroot/app.css`, `wwwroot/app.js`

Each is a complete file — paste the whole block, don't hand-merge.

### Step 3 — Run it

```bash
cd src/FocusWall.Server
dotnet run
```

Open `http://localhost:5050` in a browser. You should see the dashboard shell with hero "Idle."

### Step 4 — Wire up the hook wrapper

Copy `hooks/hook-send.sh` and `hooks/settings.example.json` from `IMPLEMENTATION.md`. `chmod +x hooks/hook-send.sh`. Merge the hooks block into `~/.claude/settings.json`, using the absolute path to your `hook-send.sh`.

Run the smoke test from `IMPLEMENTATION.md` § "Smoke test":

```bash
echo '{"hook_event_name":"Notification","message":"smoke test"}' | ./hooks/hook-send.sh
curl http://localhost:5050/events | jq .
```

You should see one event in the JSON response and a dot appear in the dashboard's event log.

### Step 5 — Unit tests

Set up `tests/FocusWall.Server.Tests` per `IMPLEMENTATION.md` § "Unit tests — EventStore". Run:

```bash
dotnet test tests/FocusWall.Server.Tests
```

All four tests should pass, including `SecondSessionEnteringWaitingStillBroadcasts` — that one guards the multi-session broadcast fix, and it's the cheapest way to catch a regression before you ever touch two terminals.

### Step 6 — Real session, then the multi-session acceptance test

1. Start a real Claude Code session in another terminal, do a few things, watch events land in the dashboard.
2. Run the **multi-session "loudest wins" test** — the exact script is in `IMPLEMENTATION.md` § "Testing approach" → "Multi-session 'loudest wins' test." This is the actual Phase 1 checkpoint below, not optional.

### ✅ Phase 1 checkpoint

You're done with Phase 1 when, during that multi-session script: Session A goes "Waiting for you," Session B keeps hammering tool calls, and the hero **stays on "Waiting for you" the entire time** — only dropping back to "Working" after Session A resumes. If it flips back to "Working" while B is still churning, something regressed in `ComputeGlobalStatusLocked` — stop and fix it before moving on; everything downstream (notifications, the wall itself) depends on this holding.

## After Phase 1 works

You have a working local dashboard. From here the path forks by what you want next — pick one, or do them in this order:

1. **Get it on the Pi.** Order hardware per `HARDWARE.md` (skip if you already have a Pi + monitor). Once parts are in hand: `DEPLOYMENT.md` start to finish (flash → Docker → deploy → kiosk mode → wall mount) — it's already sequenced step-by-step, just follow it. **Make the GitHub repo private before you get to the deploy step** — `DEPLOYMENT.md` § 4a sets up a self-hosted Actions runner on the Pi so every `git push` auto-deploys, and that path requires a private repo (GitHub's own warning: on a public repo, a self-hosted runner lets PR code execute on your hardware). If you'd rather not deal with a runner yet, § 4b is the plain manual `docker compose up -d` path.
2. **Add a second workstation.** Trivial once the Pi is live — run `hooks/install-workstation.sh` on the second machine pointed at the same server (about 20 minutes, no server changes; see `hooks/README.md`).
3. **Add notifications.** Once you've lived with the wall display for a few days and know whether you actually miss "waiting" moments away from your desk, `DISCORD.md` (fastest, ~30 min) or `ECHO_SHOW.md` (needs an Echo Show + Voice Monkey account, ~1 evening). Don't build these before the wall itself — both docs are explicit that this is easy to over-invest in early.
