# Implementation

Concrete build steps and all code. Follow top to bottom. Every code block is meant to be the actual contents of the named file.

## Project layout

```
focus-wall/
├── README.md                   # + other guides: ARCHITECTURE, IMPLEMENTATION (this file),
│                               #   GETTING_STARTED, DEPLOYMENT, HARDWARE, PHASE2-RUNBOOK,
│                               #   DISCORD, ECHO_SHOW, and the *_SETUP_CHECKLIST files
├── docker-compose.yml
├── .github/
│   ├── dependabot.yml
│   └── workflows/
│       └── deploy.yml.example  # inert sample; rename to deploy.yml to activate (Phase 2b)
├── src/
│   └── FocusWall.Server/
│       ├── FocusWall.Server.csproj
│       ├── Program.cs
│       ├── EventStore.cs
│       ├── HeartbeatService.cs
│       ├── RssService.cs        # RSS ticker background service
│       ├── RssParser.cs         # pure RSS/Atom parser (unit-tested)
│       ├── SlackService.cs      # Slack panel background service
│       ├── SlackCounts.cs       # pure client.counts reducer (unit-tested)
│       ├── SlackProfile.cs      # pure presence/status parser (unit-tested)
│       ├── UsageStore.cs        # per-host usage-limit summaries
│       ├── DiscordNotifier.cs   # optional Discord webhook (see DISCORD.md)
│       ├── EchoAnnouncer.cs     # optional Voice Monkey / Echo Show (see ECHO_SHOW.md)
│       ├── appsettings.json     # RSS feeds + Slack workspace config
│       ├── Dockerfile
│       └── wwwroot/
│           ├── index.html      # grid view (home /)
│           ├── grid.js         # per-session cards (grid view)
│           ├── hero.html       # hero view (/hero)
│           ├── app.js          # hero logic (hero view)
│           ├── app.css         # shared styles
│           ├── sse.js          # shared EventSource/reconnect/kiosk module
│           ├── wall.html       # kiosk wall (/wall) — RSS tickers + hero iframe
│           ├── wall.js
│           ├── mobile.html     # phone view (/mobile) — hosts the snooze control
│           ├── mobile.js
│           ├── mobile.css
│           ├── usage.html      # usage limits page (/usage)
│           ├── usage.js
│           └── usage.css
├── hooks/
│   ├── hook-send.sh            # hook wrapper (macOS/Linux)
│   ├── hook-send.ps1           # hook wrapper (Windows)
│   ├── install-workstation.sh  # workstation installer (macOS/Linux)
│   ├── install-workstation.ps1 # workstation installer (Windows)
│   ├── usage-poll.sh           # usage poller (macOS/Linux)
│   ├── usage-poll.ps1          # usage poller (Windows)
│   ├── settings.example.json
│   └── README.md
└── tests/
    └── FocusWall.Server.Tests/
        ├── FocusWall.Server.Tests.csproj
        ├── EventStoreTests.cs
        ├── RssParserTests.cs
        ├── SlackCountsTests.cs
        ├── SlackProfileTests.cs
        ├── SnoozeTests.cs
        └── UsageStoreTests.cs
```

> **Scope of this document.** The build steps below cover the core wall (event server + SSE + the grid/hero/wall views) and the RSS ticker. Four features shipped *after* this doc and are **not** transcribed here: the **Slack panel** (`SlackService`/`SlackCounts`/`SlackProfile` + `/slack/state`), the **usage limits** page and pollers (`UsageStore` + `usage-poll.*` + `/usage`), **snooze** (`POST /snooze`), and the **mobile** view (`/mobile`). Their design notes live in `CLAUDE.md`; the Discord and Echo channels are specified in `DISCORD.md` / `ECHO_SHOW.md`, and the turn-on steps in the `*_SETUP_CHECKLIST.md` files. Treat the code in `src/` as authoritative for those.

## Phase 1 — project bootstrap

### Create the project

```bash
mkdir focus-wall && cd focus-wall
git init
mkdir -p src/FocusWall.Server hooks
cd src/FocusWall.Server
dotnet new web -n FocusWall.Server -o . --force
rm -f appsettings.Development.json   # not needed
mkdir wwwroot
cd ../..
```

### `src/FocusWall.Server/FocusWall.Server.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>
</Project>
```

### `src/FocusWall.Server/Program.cs`

```csharp
using System.Text.Json;
using FocusWall.Server;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<EventStore>();
builder.Services.AddHostedService<HeartbeatService>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapPost("/events", async (HttpRequest req, EventStore store) =>
{
    using var reader = new StreamReader(req.Body);
    var body = await reader.ReadToEndAsync();

    JsonDocument doc;
    try { doc = JsonDocument.Parse(body); }
    catch { return Results.BadRequest(new { error = "invalid_json" }); }

    var entry = store.Add(doc.RootElement.Clone());
    return Results.Ok(new { id = entry.Id });
});

app.MapGet("/events", (EventStore store) =>
    Results.Json(new { events = store.Snapshot(), status = store.GetStatus() }));

app.MapGet("/events/stream", async (HttpResponse res, EventStore store, CancellationToken ct) =>
{
    res.Headers["Content-Type"] = "text/event-stream";
    res.Headers["Cache-Control"] = "no-cache, no-transform";
    res.Headers["Connection"] = "keep-alive";
    res.Headers["X-Accel-Buffering"] = "no";

    // Initial replay so a freshly-loaded dashboard has context
    foreach (var e in store.Snapshot().Reverse())
        await SseWrite(res, "event", e, ct);
    await SseWrite(res, "status", store.GetStatus(), ct);

    var (channel, id) = store.Subscribe();
    try
    {
        await foreach (var msg in channel.Reader.ReadAllAsync(ct))
            await SseWrite(res, msg.Kind, msg.Data, ct);
    }
    catch (OperationCanceledException) { /* client disconnected */ }
    finally
    {
        store.Unsubscribe(id);
    }
});

app.MapGet("/healthz", () => Results.Ok("ok"));

app.Run("http://0.0.0.0:5050");

static async Task SseWrite(HttpResponse res, string ev, object data, CancellationToken ct)
{
    // Web options = camelCase, matching Results.Json on GET /events —
    // the dashboard sees a single casing everywhere.
    var json = JsonSerializer.Serialize(data, JsonSerializerOptions.Web);
    await res.WriteAsync($"event: {ev}\ndata: {json}\n\n", ct);
    await res.Body.FlushAsync(ct);
}
```

### `src/FocusWall.Server/EventStore.cs`

The store keys state on `(hostname, session_id)`. Each session runs its own state machine; the global status is the "loudest" across all sessions. This is what makes concurrent Claude Code sessions work correctly.

```csharp
namespace FocusWall.Server;

using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;

public record SessionKey(string Hostname, string SessionId)
{
    public string Short => $"{Hostname}/{(SessionId.Length > 4 ? SessionId[^4..] : SessionId)}";
    public static SessionKey Unknown => new("unknown", "unknown");
}

public record EventEntry(
    string Id,
    DateTimeOffset ReceivedAt,
    SessionKey SessionKey,
    JsonElement Payload);

public record SessionState(
    SessionKey Key,
    string Status,
    DateTimeOffset StatusSince,
    DateTimeOffset LastEventAt,
    string? Cwd,
    EventEntry? LastEvent);

public record GlobalStatus(
    string Value,                 // loudest across sessions
    DateTimeOffset Since,
    int SessionCount,
    int WaitingCount,
    int WorkingCount,
    List<SessionState> Sessions);

public record StreamMessage(string Kind, object Data);

public class EventStore
{
    private const int MaxEvents = 200;
    private static readonly TimeSpan DoneAgesToIdleAfter = TimeSpan.FromSeconds(30);
    // Long enough that a silent long-running tool call (test suite, build)
    // doesn't flap the hero; short enough that a killed terminal that never
    // sent SessionEnd doesn't show "Working" for hours.
    private static readonly TimeSpan WorkingAgesToIdleAfter = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan SessionPruneAfter  = TimeSpan.FromHours(2);

    // Priority — higher number is louder in the "who wins the hero" contest
    private static readonly Dictionary<string, int> _priority = new()
    {
        ["waiting"] = 4,
        ["working"] = 3,
        ["done"]    = 2,
        ["idle"]    = 1
    };

    private readonly LinkedList<EventEntry> _events = new();
    private readonly Dictionary<SessionKey, SessionState> _sessions = new();
    private readonly object _lock = new();
    private readonly ConcurrentDictionary<Guid, Channel<StreamMessage>> _subs = new();

    // Signature of every session's status. Broadcast when *any* session
    // transitions — coalescing on the global loudest value alone would
    // swallow e.g. a second session entering "waiting" while another is
    // already waiting (the notifiers would never hear about it, and the
    // hero subtitle would name the wrong session).
    private string _lastBroadcastSignature = "";

    public EventEntry Add(JsonElement payload)
    {
        var key = ExtractSessionKey(payload);
        var eventName = payload.TryGetProperty("hook_event_name", out var n) ? n.GetString() : null;
        var cwd = ExtractCwd(payload);

        var entry = new EventEntry(
            Id: Guid.NewGuid().ToString("N")[..12],
            ReceivedAt: DateTimeOffset.UtcNow,
            SessionKey: key,
            Payload: payload);

        GlobalStatus globalAfter;
        bool shouldBroadcastStatus;

        lock (_lock)
        {
            _events.AddFirst(entry);
            while (_events.Count > MaxEvents) _events.RemoveLast();

            var previousStatus = _sessions.TryGetValue(key, out var existing) ? existing.Status : "idle";
            var newStatus = DeriveSessionStatus(eventName, previousStatus);

            if (eventName == "SessionEnd")
            {
                _sessions.Remove(key);
            }
            else
            {
                _sessions[key] = new SessionState(
                    Key: key,
                    Status: newStatus,
                    StatusSince: newStatus != previousStatus ? entry.ReceivedAt : (existing?.StatusSince ?? entry.ReceivedAt),
                    LastEventAt: entry.ReceivedAt,
                    Cwd: cwd ?? existing?.Cwd,
                    LastEvent: entry);
            }

            globalAfter = ComputeGlobalStatusLocked();
            var signature = ComputeSignatureLocked();
            shouldBroadcastStatus = signature != _lastBroadcastSignature;
            _lastBroadcastSignature = signature;
        }

        Broadcast(new StreamMessage("event", entry));
        if (shouldBroadcastStatus)
            Broadcast(new StreamMessage("status", globalAfter));

        return entry;
    }

    private static string DeriveSessionStatus(string? eventName, string current) => eventName switch
    {
        "Notification"     => "waiting",
        "Stop"             => "done",
        "PreToolUse"       => "working",
        "PostToolUse"      => "working",
        "UserPromptSubmit" => "working",
        // SessionStart means the session exists but nothing is running yet —
        // a freshly opened terminal, or the fresh conversation after /clear
        // (which fires SessionEnd then SessionStart). Idle, not working: work
        // begins at the first UserPromptSubmit. Keeps a cleared session on the
        // wall as Idle instead of resurrecting it as a phantom "Working" card.
        "SessionStart"     => "idle",
        "SessionEnd"       => "idle",
        _ => current
    };

    private static SessionKey ExtractSessionKey(JsonElement payload)
    {
        var hostname = "unknown";
        if (payload.TryGetProperty("_meta", out var meta) &&
            meta.TryGetProperty("hostname", out var h) &&
            h.ValueKind == JsonValueKind.String)
        {
            hostname = h.GetString() ?? "unknown";
        }

        var sessionId = "unknown";
        if (payload.TryGetProperty("session_id", out var s) &&
            s.ValueKind == JsonValueKind.String)
        {
            sessionId = s.GetString() ?? "unknown";
        }

        return new SessionKey(hostname, sessionId);
    }

    private static string? ExtractCwd(JsonElement payload)
    {
        // Prefer the wrapper's _meta.cwd, but fall back to the cwd field
        // Claude Code includes natively in hook payloads — project names
        // keep working even if the wrapper's jq augmentation is unavailable.
        string? full = null;
        if (payload.TryGetProperty("_meta", out var meta) &&
            meta.TryGetProperty("cwd", out var mc) &&
            mc.ValueKind == JsonValueKind.String)
        {
            full = mc.GetString();
        }
        else if (payload.TryGetProperty("cwd", out var pc) &&
                 pc.ValueKind == JsonValueKind.String)
        {
            full = pc.GetString();
        }

        // Show just the last path segment — "my-project" not the whole path.
        // Split on both separators explicitly: the server runs in a Linux container,
        // so System.IO.Path uses POSIX rules and would NOT treat '\' as a separator,
        // leaving Windows paths ("C:\Users\...\FocusWall") shown in full.
        if (full is null) return null;
        var trimmed = full.TrimEnd('/', '\\');
        var lastSep = trimmed.LastIndexOfAny(new[] { '/', '\\' });
        return lastSep >= 0 ? trimmed[(lastSep + 1)..] : trimmed;
    }

    private GlobalStatus ComputeGlobalStatusLocked()
    {
        var now = DateTimeOffset.UtcNow;

        // Age out done → idle, and prune long-abandoned sessions
        var toPrune = new List<SessionKey>();
        var keys = _sessions.Keys.ToList();
        foreach (var k in keys)
        {
            var s = _sessions[k];
            if (now - s.LastEventAt > SessionPruneAfter) { toPrune.Add(k); continue; }
            if (s.Status == "done" && now - s.LastEventAt > DoneAgesToIdleAfter)
                _sessions[k] = s with { Status = "idle", StatusSince = now };
            else if (s.Status == "working" && now - s.LastEventAt > WorkingAgesToIdleAfter)
                _sessions[k] = s with { Status = "idle", StatusSince = now };
            // "waiting" never decays — Claude stays blocked until you act.
        }
        foreach (var k in toPrune) _sessions.Remove(k);

        var active = _sessions.Values.ToList();
        if (active.Count == 0)
            return new GlobalStatus("idle", now, 0, 0, 0, new());

        var loudest = active.MaxBy(s => _priority[s.Status])!;
        var loudestSince = active
            .Where(s => s.Status == loudest.Status)
            .Min(s => s.StatusSince);

        return new GlobalStatus(
            Value: loudest.Status,
            Since: loudestSince,
            SessionCount: active.Count,
            WaitingCount: active.Count(s => s.Status == "waiting"),
            WorkingCount: active.Count(s => s.Status == "working"),
            Sessions: active.OrderByDescending(s => _priority[s.Status]).ToList());
    }

    private string ComputeSignatureLocked() =>
        string.Join("|", _sessions
            .OrderBy(kv => kv.Key.Hostname).ThenBy(kv => kv.Key.SessionId)
            .Select(kv => $"{kv.Key.Hostname}/{kv.Key.SessionId}={kv.Value.Status}"));

    public IReadOnlyList<EventEntry> Snapshot()
    {
        lock (_lock) return _events.ToList();
    }

    public GlobalStatus GetStatus()
    {
        lock (_lock) return ComputeGlobalStatusLocked();
    }

    public (Channel<StreamMessage> channel, Guid id) Subscribe()
    {
        var ch = Channel.CreateBounded<StreamMessage>(new BoundedChannelOptions(200)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false
        });
        var id = Guid.NewGuid();
        _subs[id] = ch;
        return (ch, id);
    }

    public void Unsubscribe(Guid id)
    {
        if (_subs.TryRemove(id, out var ch)) ch.Writer.TryComplete();
    }

    public void Heartbeat()
    {
        GlobalStatus globalAfter;
        bool shouldBroadcastStatus;
        lock (_lock)
        {
            globalAfter = ComputeGlobalStatusLocked();
            var signature = ComputeSignatureLocked();
            shouldBroadcastStatus = signature != _lastBroadcastSignature;
            _lastBroadcastSignature = signature;
        }

        Broadcast(new StreamMessage("heartbeat", new { t = DateTimeOffset.UtcNow }));
        if (shouldBroadcastStatus)
            Broadcast(new StreamMessage("status", globalAfter));
    }

    private void Broadcast(StreamMessage msg)
    {
        foreach (var ch in _subs.Values) ch.Writer.TryWrite(msg);
    }
}
```

### `src/FocusWall.Server/HeartbeatService.cs`

```csharp
namespace FocusWall.Server;

public class HeartbeatService(EventStore store) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                store.Heartbeat();
        }
        catch (OperationCanceledException) { }
    }
}
```

## Phase 1 — frontend

The frontend is a set of views sharing common CSS and a connection module,
not a single page. This section builds the first three — grid, hero, and
wall; the `/mobile` and `/usage` views shipped later (see the scope note
above) and follow the same pattern. `GET /` serves the **grid** view — `wwwroot/index.html`
loading `wwwroot/grid.js` — via `app.UseDefaultFiles()`/`UseStaticFiles()`
in `Program.cs` (static-files middleware treats `index.html` as the default
document for `/`). `GET /hero` is mapped explicitly in `Program.cs`
(`app.MapGet("/hero", …)`) to `wwwroot/hero.html`, which loads
`wwwroot/app.js`. `GET /wall` is mapped to `wwwroot/wall.html`, which composes
the grid and hero views in two iframes with a configurable RSS news ticker.
All views link `wwwroot/app.css` for styling, and their scripts import
`wwwroot/sse.js` — the shared `EventSource`/reconnect/kiosk module
(`initKioskCursor`, `connectStream`) — so connection handling and
kiosk-cursor behavior are identical on all routes with no duplicated code.

Files in this section:
- `wwwroot/index.html` — **grid view** (home `/`), loads `grid.js`
- `wwwroot/hero.html` — **hero view** (`/hero`), loads `app.js`
- `wwwroot/wall.html` — **rotator view** (`/wall`), composes grid and hero iframes with RSS ticker
- `wwwroot/app.css` — shared styles, including the grid/card/rotator rules
- `wwwroot/sse.js` — shared EventSource/reconnect/kiosk module used by all views
- `wwwroot/grid.js` — renders per-session cards from the `status` snapshot
- `wwwroot/app.js` — hero logic; now obtains its connection from `sse.js` instead of managing its own `EventSource`

### `src/FocusWall.Server/wwwroot/index.html`

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude Focus Wall — Sessions</title>
  <link rel="stylesheet" href="/app.css">
</head>
<body>
  <main id="app" class="grid-page" data-status="idle">
    <header class="topbar">
      <div class="brand">
        <span class="brand-dot"></span>
        <span>Claude Focus Wall</span>
      </div>
      <div class="clock" id="clock">--:--:--</div>
      <div class="conn" id="conn">connecting…</div>
    </header>
    <section class="grid" id="grid"></section>
  </main>
  <script src="/grid.js" type="module"></script>
</body>
</html>
```

### `src/FocusWall.Server/wwwroot/hero.html`

This is the original single-view `index.html`, renamed and moved to the
`/hero` route once the grid became the home page. The `app.css`/`app.js`
asset paths are absolute (`/app.css`, `/app.js`) since this file is served
via an explicit `MapGet`, not the static-files default-document path. A
`sessions-strip` section sits between the hero and the metrics: `app.js`
fills it with a compact card per session the hero isn't already featuring,
and hides it entirely when there are none.

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude Focus Wall</title>
  <link rel="stylesheet" href="/app.css">
</head>
<body>
  <main id="app" data-status="idle">
    <header class="topbar">
      <div class="brand">
        <span class="brand-dot"></span>
        <span>Claude Focus Wall</span>
      </div>
      <div class="clock" id="clock">--:--:--</div>
      <div class="conn" id="conn">connecting…</div>
    </header>

    <section class="hero" id="hero">
      <div class="hero-label">Status</div>
      <h1 class="hero-title" id="hero-title">Idle</h1>
      <p class="hero-detail" id="hero-detail">No active sessions</p>
      <p class="hero-summary" id="hero-summary"></p>
      <p class="hero-since" id="hero-since">—</p>
    </section>

    <section class="sessions-strip" id="sessions-strip" hidden>
      <div class="strip-title">Other sessions</div>
      <div class="strip-cards" id="strip-cards"></div>
    </section>

    <section class="metrics">
      <div class="metric"><span class="metric-label">Sessions</span><span class="metric-value" id="m-sessions">0</span></div>
      <div class="metric"><span class="metric-label">Tool calls</span><span class="metric-value" id="m-tools">0</span></div>
      <div class="metric"><span class="metric-label">Edits</span><span class="metric-value" id="m-edits">0</span></div>
      <div class="metric"><span class="metric-label">Last event</span><span class="metric-value" id="m-last">—</span></div>
    </section>

    <section class="log">
      <div class="log-title">Recent events</div>
      <ul class="log-list" id="log-list"></ul>
    </section>
  </main>
  <script src="/app.js" type="module"></script>
</body>
</html>
```

### `src/FocusWall.Server/wwwroot/wall.html`

The wall rotator composes the grid and hero views in two iframes, toggling
between them every 60 seconds (configurable via `?rotate=<seconds>`). Each
iframe maintains its own independent SSE connection so both views stay live
during rotation. The RSS news ticker is pinned along the top outside the
iframes, fed by `GET /rss`. The page loads with `/?kiosk=1` to hide the cursor
(which `grid.js` and `app.js` handle via the shared `initKioskCursor` call
from `sse.js`). Use `?kiosk=1&rotate=30` to set both kiosk mode and rotation
period on the wall rotator.

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude Focus Wall — Wall</title>
  <link rel="stylesheet" href="/app.css">
</head>
<body class="wall-page">
  <header class="ticker" id="ticker" aria-hidden="true">
    <div class="ticker-track" id="ticker-track">
      <span class="ticker-item">Loading news…</span>
    </div>
  </header>
  <div class="wall-views">
    <iframe class="wall-frame" id="frame-grid" src="/?kiosk=1" title="Session grid"></iframe>
    <iframe class="wall-frame" id="frame-hero" src="/hero?kiosk=1" title="Status hero" hidden></iframe>
  </div>
  <script src="/wall.js" type="module"></script>
</body>
</html>
```

### `src/FocusWall.Server/wwwroot/wall.js`

The wall rotator handles toggling between grid and hero iframes on a configurable
interval, and populates the RSS ticker. The script fetches `GET /rss` (which
returns `[{ source, title, link, publishedAt }]`, camelCase) and renders each
feed item as a scrollable ticker. The ticker is independent of the iframes, so
it updates asynchronously. Rotation can be overridden via the `?rotate=<seconds>`
URL parameter; if omitted, it defaults to 60 seconds.

```javascript
// /wall — rotates between the grid and hero views without reloading either,
// and drives the news ticker along the top.
// Both iframes stay loaded; only `hidden` toggles, so each keeps its DOM and
// SSE connection alive — revealing a view is instant, with no reload or replay.
import { initKioskCursor } from './sse.js';

initKioskCursor(); // hides cursor when loaded as /wall?kiosk=1

// ── View rotation ──────────────────────────────────────────────────────────
// Interval is per view (a full grid→hero→grid cycle is 2×). ?rotate=<seconds>
// overrides the 30s default.
function initRotation() {
  const frames = [
    document.getElementById('frame-grid'),
    document.getElementById('frame-hero'),
  ];
  const secs = parseInt(new URLSearchParams(location.search).get('rotate'), 10) || 30;
  let shown = 0;
  setInterval(() => {
    frames[shown].hidden = true;
    shown ^= 1;
    frames[shown].hidden = false;
  }, secs * 1000);
}

initRotation();

// ── News ticker ────────────────────────────────────────────────────────────
// Reads the server-merged, same-origin /rss feed (browsers can't fetch external
// RSS — CORS). Feed titles are external/untrusted, so every node is built with
// textContent, never innerHTML.
const track = document.getElementById('ticker-track');

// Scroll speed in pixels/second — LOWER is SLOWER. This drives the marquee
// duration off the actual content width, so the speed stays constant no matter
// how many feeds/items are configured (a fixed CSS duration would speed up as
// you add feeds). Tune this one number to taste.
const TICKER_PX_PER_SEC = 40;

function makeItems(items) {
  return items.map(it => {
    const span = document.createElement('span');
    span.className = 'ticker-item';
    const src = document.createElement('span');
    src.className = 'ticker-src';
    src.textContent = it.source || 'news';
    const title = document.createElement('span');
    title.textContent = it.title;
    span.append(src, title);
    return span;
  });
}

function renderTicker(items) {
  track.replaceChildren();
  if (!items || items.length === 0) {
    const span = document.createElement('span');
    span.className = 'ticker-item';
    span.textContent = 'News unavailable';
    track.appendChild(span);
    track.classList.remove('scrolling');
    return;
  }
  // Duplicate the sequence so the CSS marquee (translateX 0 → -50%) loops seamlessly.
  for (const node of makeItems(items)) track.appendChild(node);
  for (const node of makeItems(items)) track.appendChild(node);
  track.classList.add('scrolling');
  // One animation cycle (0 → -50%) advances exactly one copy = scrollWidth / 2.
  // Derive the duration so the on-screen speed is a constant px/sec.
  const oneCopyPx = track.scrollWidth / 2;
  track.style.animationDuration = (oneCopyPx / TICKER_PX_PER_SEC) + 's';
}

async function refreshTicker() {
  try {
    const res = await fetch('/rss');
    if (!res.ok) throw new Error(String(res.status));
    renderTicker(await res.json());
  } catch {
    // Keep whatever is showing; only fall back to the placeholder if empty.
    if (!track.querySelector('.ticker-item')) renderTicker([]);
  }
}

refreshTicker();
setInterval(refreshTicker, 5 * 60 * 1000);
```

### RSS ticker

The `/rss` endpoint returns `{ "news": [...], "sports": [...] }` — two independently
merged lists, one per ticker row (`/wall` renders news along the top, sports along
the bottom). Each list's sources are configured in `appsettings.json` →
`Rss:NewsFeeds` / `Rss:SportsFeeds`. The `RssService` background service fetches
both groups on a configurable interval (`Rss:RefreshMinutes`, default 10 minutes)
and merges each group's feeds newest-first, capping at `Rss:MaxItems` **per row**
(default 30). Items are tagged with a short source label (host minus common
`www.`/`feeds.`/`rss.`/`feed.`/`search.` prefixes) and carry `publishedAt` for the
client date stamp. If a feed fails to fetch or parse, it is skipped — the ticker
never blanks. The JSON config provider tolerates `//` comments, so each feed can be
labelled inline.

**Configuration in `appsettings.json`:**
```json
"Rss": {
  "NewsFeeds": [
    "https://feeds.bbci.co.uk/news/rss.xml",  // BBC — Top News
    "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"  // NYT — Top Stories
  ],
  "SportsFeeds": [
    "https://www.espn.com/espn/rss/news"  // ESPN — Top Sports
  ],
  "RefreshMinutes": 10,
  "MaxItems": 40
}
```

**GET /rss response:**
```json
[
  {
    "source": "Hacker News",
    "title": "Some interesting story",
    "link": "https://news.ycombinator.com/item?id=12345",
    "publishedAt": "2026-07-10T15:30:00Z"
  }
]
```

The `RssService` uses `System.ServiceModel.Syndication` to parse both RSS 2.0
and Atom feeds. Feed URLs are data (in config), not hardcoded. All display
rendering uses `textContent` to prevent XSS from untrusted feed titles.

### `src/FocusWall.Server/wwwroot/app.css`

```css
:root {
  --bg: #0f1115;
  --bg-elev: #161922;
  --fg: #eaeaea;
  --fg-dim: #8a8f99;
  --fg-faint: #555a64;
  --border: #2a2e38;

  --idle: #5a5f6b;
  --working: #378ADD;
  --waiting: #BA7517;
  --done: #1D9E75;
}

* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg);
  font-family: ui-sans-serif, system-ui, sans-serif; height: 100%; }
body { overflow: hidden; }
main {
  padding: 2.5vh 3vw;
  height: 100vh;
  display: grid;
  grid-template-rows: auto auto auto 1fr;
  gap: 2.5vh;
}

.topbar { display: flex; align-items: center; gap: 16px; }
.brand { display: flex; align-items: center; gap: 10px; font-weight: 500; font-size: 16px; }
.brand-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--working); }
.clock { font-variant-numeric: tabular-nums; color: var(--fg-dim); margin-left: auto; font-size: 14px; }
.conn { font-size: 12px; color: var(--fg-faint); padding: 4px 8px; border: 0.5px solid var(--border); border-radius: 6px; }
.conn.live { color: var(--done); border-color: var(--done); }
.conn.dead { color: var(--waiting); border-color: var(--waiting); }

.hero {
  background: var(--bg-elev);
  border-radius: 16px;
  padding: 4vh 3vw;
  border-left: 6px solid var(--idle);
  transition: border-color .3s;
}
.hero-label { color: var(--fg-dim); font-size: 13px; letter-spacing: .5px; }
.hero-title { margin: 8px 0 6px; font-size: clamp(48px, 8vw, 110px); font-weight: 500; line-height: 1; }
.hero-detail { margin: 0; color: var(--fg-dim); font-size: clamp(18px, 2vw, 28px); }
.hero-summary { margin: 8px 0 0; color: var(--fg-faint); font-size: 15px; font-variant-numeric: tabular-nums; }
.hero-since { margin: 12px 0 0; color: var(--fg-faint); font-size: 14px; font-variant-numeric: tabular-nums; }

[data-status="waiting"] .hero { border-color: var(--waiting); }
[data-status="waiting"] .hero-title { color: var(--waiting); }
[data-status="working"] .hero { border-color: var(--working); }
[data-status="done"] .hero { border-color: var(--done); }
[data-status="done"] .hero-title { color: var(--done); }

/* Mini session strip (hero.html) — compact status of the sessions the hero
   isn't already featuring. Hidden entirely when there are none, so the
   single-session hero is unchanged. When shown, main grows a 5th row for it. */
main.has-strip { grid-template-rows: auto auto auto auto 1fr; }
.sessions-strip { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.strip-title { color: var(--fg-dim); font-size: 13px; letter-spacing: .5px; }
.strip-cards { display: flex; flex-wrap: wrap; gap: 14px; min-width: 0; }
.mini {
  background: var(--bg-elev);
  border-radius: 12px;
  padding: 12px 16px;
  border-left: 5px solid var(--idle);
  display: flex; flex-direction: column; gap: 6px;
  flex: 0 1 220px; min-width: 170px; max-width: 320px;
  transition: border-color .3s, background .3s;
}
.mini-status { display: flex; align-items: center; gap: 8px; }
.mini-status .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--idle); }
.mini-status .word { font-size: 15px; font-weight: 500; color: var(--fg-dim); }
.mini-project { font-size: 22px; font-weight: 500; line-height: 1;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mini-foot { display: flex; gap: 8px; align-items: baseline; justify-content: space-between;
  color: var(--fg-faint); font-size: 12px; font-variant-numeric: tabular-nums; }
.mini-host { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mini-time { flex: 0 0 auto; }

.mini[data-status="working"] { border-color: var(--working); }
.mini[data-status="working"] .dot { background: var(--working); }
.mini[data-status="working"] .word { color: var(--working); }
.mini[data-status="done"] { border-color: var(--done); }
.mini[data-status="done"] .dot { background: var(--done); }
.mini[data-status="done"] .word { color: var(--done); }
.mini[data-status="idle"] .dot { background: var(--idle); }
.mini[data-status="idle"] .word { color: var(--fg-dim); }
.mini[data-status="waiting"] {
  border-color: var(--waiting);
  background: rgba(186, 117, 23, 0.14);
  animation: waitpulse 2s ease-in-out infinite;
}
.mini[data-status="waiting"] .dot { background: var(--waiting); }
.mini[data-status="waiting"] .word { color: var(--waiting); }

.metrics { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
.metric { background: var(--bg-elev); border-radius: 12px; padding: 14px 18px; display: flex; flex-direction: column; gap: 4px; }
.metric-label { color: var(--fg-dim); font-size: 13px; }
.metric-value { font-size: 28px; font-weight: 500; font-variant-numeric: tabular-nums; }

.log { background: var(--bg-elev); border-radius: 12px; padding: 18px 22px; overflow: hidden; display: flex; flex-direction: column; min-height: 0; }
.log-title { color: var(--fg-dim); font-size: 13px; font-weight: 500; margin-bottom: 12px; }
.log-list { list-style: none; margin: 0; padding: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
.log-list li { display: grid; grid-template-columns: 62px 12px 110px 130px 1fr; align-items: center; gap: 10px; font-size: 14px; }
.log-list li .time { color: var(--fg-faint); font-variant-numeric: tabular-nums; }
.log-list li .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--fg-faint); }
.log-list li .badge {
  font-size: 11px; font-variant-numeric: tabular-nums;
  color: var(--fg-dim); background: rgba(255,255,255,.04);
  padding: 3px 7px; border-radius: 5px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.log-list li .type { color: var(--fg-dim); }
.log-list li .detail { color: var(--fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.log-list li[data-kind="Notification"] .dot { background: var(--waiting); }
.log-list li[data-kind="Stop"] .dot { background: var(--done); }
.log-list li[data-kind="SessionStart"] .dot { background: var(--working); }
.log-list li[data-kind="SessionEnd"] .dot { background: var(--idle); }
```

`app.css` also carries the grid/card rules used by `index.html`/`grid.js`
(`.grid-page`, `.grid`, `.grid-empty`, `.card`, `.card-status`,
`.card-project`, `.card-host`, `.card-activity`, `.card-time`, `.card-msg`,
plus the per-status `[data-status]` color and the `waitpulse` animation for
`waiting` cards) — appended after the rules above, sharing the same
`--idle`/`--working`/`--waiting`/`--done` color variables as the hero view.
`.grid-page` overrides the generic `main` grid-template so the grid section
gets the `1fr` track (the grid page has only two rows, not the hero's four).

### `src/FocusWall.Server/wwwroot/sse.js`

Shared by both views so connection handling, reconnect-on-visibility, and
kiosk-cursor hiding live in exactly one place.

```javascript
// Shared connection + kiosk chrome for both dashboard views (grid + hero).
// Owns the single EventSource, reconnect, and the #conn badge so both views
// behave identically on Wi-Fi blips. No framework, no build step.

export function initKioskCursor() {
  // ?kiosk=1 hides the cursor — the reliable mechanism on the Pi (Wayland),
  // where unclutter does nothing.
  if (new URLSearchParams(location.search).has('kiosk')) {
    document.documentElement.style.cursor = 'none';
    document.body.style.cursor = 'none';
  }
}

export function connectStream({ onOpen, onStatus, onEvent } = {}) {
  const conn = document.getElementById('conn');
  let es;

  function connect() {
    if (es) es.close();
    if (conn) { conn.textContent = 'connecting…'; conn.className = 'conn'; }
    es = new EventSource('/events/stream');

    es.addEventListener('open', () => {
      if (conn) { conn.textContent = 'live'; conn.className = 'conn live'; }
      onOpen?.();
    });
    es.addEventListener('error', () => {
      if (conn) { conn.textContent = 'reconnecting…'; conn.className = 'conn dead'; }
    });
    es.addEventListener('status', (e) => onStatus?.(JSON.parse(e.data)));
    es.addEventListener('event', (e) => { if (onEvent) onEvent(JSON.parse(e.data)); });
    es.addEventListener('heartbeat', () => { /* keeps connection alive */ });
  }

  connect();
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && es?.readyState !== 1) connect();
  });
}
```

### `src/FocusWall.Server/wwwroot/grid.js`

Renders one card per session straight from the `status` SSE event's
`sessions` array — no client-side sort (the server already emits
loudest-first) and no per-event log, since the grid's job is "what's every
session doing right now," not a scrolling history. Working cards also show a
live activity line (e.g. `Edit · app.js`) derived from the `event` stream:
`status` snapshots are coalesced (broadcast only on a session transition), so
the activity node is updated in place from individual events rather than from
the snapshot, which would otherwise go stale between transitions.

```javascript
import { initKioskCursor, connectStream } from './sse.js';

initKioskCursor();

const gridEl = document.getElementById('grid');
const clock  = document.getElementById('clock');

const STATUS_WORD = { idle: 'Idle', working: 'Working', waiting: 'Waiting', done: 'Done' };

let sessions = [];
const activity = new Map();   // "host/sid" -> latest activity string (live, from the event stream)

function keyOf(sk) {
  return `${sk?.hostname || 'unknown'}/${sk?.sessionId || 'unknown'}`;
}

// Mirror the hero's event→detail derivation for tool events, so a working
// card shows e.g. "Edit · app.js" or the bare event name.
function deriveActivity(ev) {
  if (!ev) return null;
  const p = ev.payload || {};
  const name = p.hook_event_name;
  if ((name === 'PreToolUse' || name === 'PostToolUse') && p.tool_name) {
    const fp = p.tool_input?.file_path;
    return fp ? `${p.tool_name} · ${fp}` : p.tool_name;
  }
  return name || null;
}

function fmtSince(sinceIso) {
  const secs = Math.floor((Date.now() - new Date(sinceIso)) / 1000);
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// Rows/cards are built with textContent, never innerHTML — payload fields
// (message, cwd) are writable by anyone on the LAN via POST /events.
function render() {
  gridEl.replaceChildren();

  if (sessions.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'grid-empty';
    empty.textContent = 'No active sessions';
    gridEl.appendChild(empty);
    return;
  }

  for (const s of sessions) {
    const card = document.createElement('div');
    card.className = 'card';
    card.dataset.status = s.status;
    card.dataset.key = keyOf(s.key);

    const statusRow = document.createElement('div');
    statusRow.className = 'card-status';
    const dot = document.createElement('span');
    dot.className = 'dot';
    const word = document.createElement('span');
    word.className = 'status-word';
    word.textContent = STATUS_WORD[s.status] || s.status;
    statusRow.append(dot, word);
    card.appendChild(statusRow);

    const project = document.createElement('div');
    project.className = 'card-project';
    project.textContent = s.cwd || '—';
    card.appendChild(project);

    const host = document.createElement('div');
    host.className = 'card-host';
    host.textContent = s.key?.hostname || 'unknown';
    card.appendChild(host);

    // Live activity line — only for working sessions (waiting shows its message;
    // done/idle stay uncluttered). Updated in place by onEvent between snapshots.
    if (s.status === 'working') {
      const act = activity.get(keyOf(s.key)) ?? deriveActivity(s.lastEvent);
      const a = document.createElement('div');
      a.className = 'card-activity';
      a.textContent = act || '…';
      card.appendChild(a);
    }

    const time = document.createElement('div');
    time.className = 'card-time';
    time.dataset.since = s.statusSince;
    time.textContent = fmtSince(s.statusSince);
    card.appendChild(time);

    if (s.status === 'waiting') {
      const msg = s.lastEvent?.payload?.message;
      if (msg) {
        const m = document.createElement('div');
        m.className = 'card-msg';
        m.textContent = msg;
        card.appendChild(m);
      }
    }

    gridEl.appendChild(card);
  }
}

function tick() {
  clock.textContent = new Date().toLocaleTimeString([], { hour12: false });
  for (const el of gridEl.querySelectorAll('.card-time')) {
    el.textContent = fmtSince(el.dataset.since);
  }
}
setInterval(tick, 1000);

// Cards + ordering come from the status snapshot (loudest-first from the
// server). The activity line comes from the event stream: status snapshots are
// coalesced (only broadcast on a session transition), so a working session's
// current tool would otherwise never refresh. We update the matching card's
// activity node in place — no full re-render, so the waiting pulse stays smooth.
function onEvent(ev) {
  const k = keyOf(ev.sessionKey);
  const act = deriveActivity(ev);
  if (!act) return;
  activity.set(k, act);
  const el = gridEl.querySelector(
    `.card[data-status="working"][data-key="${CSS.escape(k)}"] .card-activity`);
  if (el) el.textContent = act;
}

connectStream({
  onStatus: (s) => { sessions = s.sessions || []; render(); },
  onEvent,
});
```

### `src/FocusWall.Server/wwwroot/app.js`

`app.js` no longer owns its own `EventSource`/reconnect logic or the kiosk
cursor toggle — those moved into `sse.js` (Task 1). `app.js` now imports
`initKioskCursor` and `connectStream` from `./sse.js` and wires `resetLog`,
`applyStatus`, and `addEvent` up as `connectStream`'s `onOpen`/`onStatus`/
`onEvent` callbacks; everything else (state, `STATUS_COPY`, `deriveDetail`,
`badgeFor`, `tickClocks`) is unchanged from the original single-view file.

```javascript
import { initKioskCursor, connectStream } from './sse.js';

const app          = document.getElementById('app');
const heroTitle    = document.getElementById('hero-title');
const heroDetail   = document.getElementById('hero-detail');
const heroSummary  = document.getElementById('hero-summary');
const heroSince    = document.getElementById('hero-since');
const clock        = document.getElementById('clock');
const logList      = document.getElementById('log-list');
const mSessions    = document.getElementById('m-sessions');
const mTools       = document.getElementById('m-tools');
const mEdits       = document.getElementById('m-edits');
const mLast        = document.getElementById('m-last');
const strip        = document.getElementById('sessions-strip');
const stripCards   = document.getElementById('strip-cards');

const STATUS_WORD = { idle: 'Idle', working: 'Working', waiting: 'Waiting', done: 'Done' };

initKioskCursor();

const state = {
  status: 'idle',
  statusSince: new Date(),
  sessionCount: 0,
  waitingCount: 0,
  workingCount: 0,
  loudestSession: null,   // SessionState of the loudest session, if any
  lastEventAt: null,
  toolCount: 0,
  editCount: 0,
};

const STATUS_COPY = {
  idle:    { title: 'Idle',            detail: 'No active sessions' },
  working: { title: 'Working',         detail: 'Claude is doing its thing' },
  waiting: { title: 'Waiting for you', detail: 'Input needed' },
  done:    { title: 'Done',            detail: 'Turn complete · ready for review' },
};

function applyStatus(s) {
  state.status        = s.value;
  state.statusSince   = new Date(s.since);
  state.sessionCount  = s.sessionCount ?? 0;
  state.waitingCount  = s.waitingCount ?? 0;
  state.workingCount  = s.workingCount ?? 0;

  const sessions = s.sessions || [];
  state.loudestSession = sessions.find(x => x.status === state.status) || null;

  app.dataset.status = state.status;
  const copy = STATUS_COPY[state.status] || STATUS_COPY.idle;
  heroTitle.textContent = copy.title;

  // For "waiting", show the actual notification text (permission prompt vs
  // idle nudge) — the waiting session's last event is always the Notification.
  let detail = copy.detail;
  if (state.status === 'waiting') {
    const msg = state.loudestSession?.lastEvent?.payload?.message;
    if (msg) detail = msg;
  }

  // Prefer cwd of loudest session (e.g., "my-project") for the detail line
  const cwd = state.loudestSession?.cwd;
  heroDetail.textContent = cwd ? `${detail} · ${cwd}` : detail;

  // Fleet summary line
  if (state.sessionCount === 0) {
    heroSummary.textContent = '';
  } else {
    const parts = [];
    if (state.waitingCount) parts.push(`${state.waitingCount} waiting`);
    if (state.workingCount) parts.push(`${state.workingCount} working`);
    const others = state.sessionCount - state.waitingCount - state.workingCount;
    if (others > 0) parts.push(`${others} idle/done`);
    heroSummary.textContent = parts.join(' · ') + ` (${state.sessionCount} total)`;
  }

  mSessions.textContent = state.sessionCount;

  renderStrip(sessions, state.loudestSession);
}

function fmtSince(iso) {
  const secs = Math.floor((Date.now() - new Date(iso)) / 1000);
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// Compact cards for every session the hero isn't already featuring. Same
// per-session payload the grid uses; ordered loudest-first by the server.
// Cards are built with textContent — payload fields (cwd, hostname) are
// writable by anyone on the LAN via POST /events. Strip collapses to nothing
// (row removed) when there are no other sessions, so the lone-hero view is
// unchanged.
function renderStrip(sessions, loudest) {
  const others = sessions.filter(x => x !== loudest);
  stripCards.replaceChildren();

  if (others.length === 0) {
    strip.hidden = true;
    app.classList.remove('has-strip');
    return;
  }

  for (const s of others) {
    const card = document.createElement('div');
    card.className = 'mini';
    card.dataset.status = s.status;

    const statusRow = document.createElement('div');
    statusRow.className = 'mini-status';
    const dot = document.createElement('span');
    dot.className = 'dot';
    const word = document.createElement('span');
    word.className = 'word';
    word.textContent = STATUS_WORD[s.status] || s.status;
    statusRow.append(dot, word);

    const project = document.createElement('div');
    project.className = 'mini-project';
    project.textContent = s.cwd || '—';

    const foot = document.createElement('div');
    foot.className = 'mini-foot';
    const host = document.createElement('span');
    host.className = 'mini-host';
    host.textContent = (s.key?.hostname || 'unknown').split('.')[0];
    const time = document.createElement('span');
    time.className = 'mini-time';
    time.dataset.since = s.statusSince;
    time.textContent = fmtSince(s.statusSince);
    foot.append(host, time);

    card.append(statusRow, project, foot);
    stripCards.appendChild(card);
  }

  strip.hidden = false;
  app.classList.add('has-strip');
}

function deriveDetail(ev) {
  if (!ev) return null;
  const p = ev.payload;
  const name = p.hook_event_name;
  if (name === 'Notification' && p.message) return p.message;
  if ((name === 'PreToolUse' || name === 'PostToolUse') && p.tool_name) {
    const fp = p.tool_input?.file_path;
    return fp ? `${p.tool_name} · ${fp}` : p.tool_name;
  }
  return name;
}

function badgeFor(ev) {
  const key = ev.sessionKey;
  if (!key) return '—';
  const host = (key.hostname || 'unknown').split('.')[0].slice(0, 10);
  const sid = (key.sessionId || 'unknown').slice(-4);
  return `${host}/${sid}`;
}

function addEvent(ev) {
  const p = ev.payload;
  const at = new Date(ev.receivedAt);
  const name = p.hook_event_name || 'unknown';

  state.lastEventAt = at;
  if (name === 'PreToolUse') state.toolCount++;
  if (name === 'PreToolUse' && (p.tool_name === 'Edit' || p.tool_name === 'Write')) state.editCount++;

  // Rows are built with textContent, never innerHTML — payload fields
  // (notification messages, file paths) are writable by anyone on the LAN
  // via POST /events and must not be able to inject markup into the kiosk.
  const li = document.createElement('li');
  li.dataset.kind = name;
  const badge = badgeFor(ev);
  for (const [cls, text] of [
    ['time', at.toLocaleTimeString([], { hour12: false })],
    ['dot', ''],
    ['badge', badge],
    ['type', name],
    ['detail', deriveDetail(ev) || ''],
  ]) {
    const span = document.createElement('span');
    span.className = cls;
    span.textContent = text;
    if (cls === 'badge') span.title = badge;
    li.appendChild(span);
  }
  logList.prepend(li);
  while (logList.children.length > 50) logList.lastElementChild.remove();

  mTools.textContent = state.toolCount;
  mEdits.textContent = state.editCount;
}

function tickClocks() {
  const now = new Date();
  clock.textContent = now.toLocaleTimeString([], { hour12: false });

  if (state.lastEventAt) {
    const secs = Math.floor((now - state.lastEventAt) / 1000);
    mLast.textContent = secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)}m`;
  }

  if (state.status === 'waiting' || state.status === 'done') {
    const secs = Math.floor((now - state.statusSince) / 1000);
    heroSince.textContent = secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)}m ${secs % 60}s`;
  } else {
    heroSince.textContent = '';
  }

  for (const el of stripCards.querySelectorAll('.mini-time')) {
    el.textContent = fmtSince(el.dataset.since);
  }
}
setInterval(tickClocks, 1000);

// The server replays its ring buffer on every (re)connect — and EventSource
// reconnects on any blip (Wi-Fi hiccup, nightly Chromium restart, container
// redeploy). Start from a clean slate each time so replayed events don't
// duplicate log rows or double-count the metrics.
function resetLog() {
  logList.replaceChildren();
  state.toolCount = 0;
  state.editCount = 0;
  mTools.textContent = '0';
  mEdits.textContent = '0';
}

connectStream({
  onOpen: resetLog,
  onStatus: applyStatus,
  onEvent: addEvent,
});
```

### Run locally

```bash
cd src/FocusWall.Server
dotnet run
# server listens on http://localhost:5050
# open http://localhost:5050 in a browser
```

## Phase 1 — hook integration

### `hooks/hook-send.sh`

Make this executable: `chmod +x hooks/hook-send.sh`.

```bash
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
```

If `jq` isn't installed, the wrapper falls back to POSTing the raw stdin — events still flow, but `_meta` is missing (the hostname badge shows `unknown`) and, more importantly, `tool_input` is no longer stripped, so full command lines and file bodies reach the server. Install `jq` (it's a Phase 0 prerequisite; `brew install jq` on macOS) rather than living with the fallback. Project names still work without it because the server falls back to the `cwd` field Claude Code includes natively.

### `hooks/settings.example.json`

Copy this into `~/.claude/settings.json` (or merge with what's there). Replace the absolute path.

```json
{
  "hooks": {
    "Notification":      [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }],
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }],
    "PreToolUse":        [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "/abs/path/to/focus-wall/hooks/hook-send.sh" }] }]
  }
}
```

No `matcher` fields: omitting the matcher runs the hook for every tool on the tool events, and the non-tool events (Notification, Stop, etc.) don't use matchers at all.

When the server is hosted on the Pi, edit the default URL inside `hook-send.sh` itself:

```bash
URL="${FOCUSWALL_URL:-http://focus-wall.local:5050/events}"
```

One place, and it works for every way Claude Code gets launched. An `export FOCUSWALL_URL=…` in `~/.zshrc` also works as a per-shell override, but GUI-launched sessions (the VS Code extension, for example) may never source your shell rc — the silent symptom is events going to `localhost` and a dashboard that never updates.

### Smoke test

```bash
# Server running on localhost:5050
echo '{"hook_event_name":"Notification","message":"smoke test"}' | ./hooks/hook-send.sh
curl http://localhost:5050/events | jq .
```

You should see one event in the response and a Notification dot in the dashboard.

### Windows workstations

The wrapper above is the **spec of record** — the behaviour it defines (strip `tool_input` to `file_path`, truncate the prompt to its first line ≤60 chars, add `_meta`, always exit 0, fire-and-forget) is what any port must reproduce. For a Windows workstation, use the PowerShell port in `hooks/hook-send.ps1` (installed by `hooks/install-workstation.ps1`) rather than the shell script. It mirrors this wrapper exactly, with two deliberate platform differences:

- **No `jq`/`curl`.** Windows PowerShell 5.1 (ships with Windows) and PowerShell 7+ both do the JSON filtering with `ConvertFrom-Json`/`ConvertTo-Json` and the POST with `Invoke-RestMethod` — no external dependencies to install.
- **Synchronous POST.** There is no clean, window-less, job-safe way to background the request the way `( curl … & )` does on Unix, so the port POSTs inline with a short timeout (`FOCUSWALL_TIMEOUT`, default 2s) instead. It still always exits 0 and swallows every error, so a down server can't break Claude Code; and because the default URL is an IP there is no DNS stall, so a reachable wall costs only a few milliseconds and only a fully-unreachable server can add up to the timeout.

The Windows hook command is `powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.focus-wall\hook-send.ps1"` (the installer writes this into `%USERPROFILE%\.claude\settings.json`). Two Windows-specific gotchas the installer already handles: `settings.json` must be written **BOM-less** (Windows PowerShell 5.1's `Set-Content -Encoding UTF8` emits a UTF-8 BOM, which breaks Claude Code's JSON parser), and the `.ps1` needs `-ExecutionPolicy Bypass` to run unsigned. See `hooks/README.md` § Windows for the install and smoke-test commands.

## Phase 2 — containerize

### `src/FocusWall.Server/Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY FocusWall.Server.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out ./
EXPOSE 5050
# Port is set explicitly in Program.cs (app.Run) — single source of truth,
# so no ASPNETCORE_URLS here.
ENTRYPOINT ["dotnet", "FocusWall.Server.dll"]
```

### `docker-compose.yml` (project root)

```yaml
services:
  focus-wall:
    build: ./src/FocusWall.Server
    image: focus-wall:latest
    container_name: focus-wall
    restart: unless-stopped
    ports:
      - "5050:5050"
    environment:
      # Container default is UTC; the quiet-hours settings (ECHO_SHOW.md,
      # DISCORD.md) evaluate in this timezone. Set to yours.
      TZ: "Etc/UTC"
    healthcheck:
      # The aspnet base image ships neither wget nor curl; a bash /dev/tcp
      # connect is enough to prove the server is accepting connections.
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/localhost/5050"]
      interval: 30s
      timeout: 3s
      retries: 3
```

### `.github/workflows/deploy.yml`

Builds and deploys automatically on every push to `main`, using a self-hosted GitHub Actions runner living on the Pi itself. No registry, no inbound network access — the runner connects outbound to GitHub and pulls jobs. **Requires the repo to be private** (see `DEPLOYMENT.md` § 4a for why, and for runner setup). This replaces the manual `git pull && docker compose up -d --build` SSH step for anyone using it; it's optional — the manual paths below still work without it.

The deploy is **health-gated with auto-recovery**: after the cached build it polls `/healthz` for 60s; if the container isn't serving (e.g. a corrupt build-cache layer shipped a broken image) it rebuilds once with `--no-cache` and re-checks. Only when the server is confirmed healthy does it reload the kiosk (`pkill` Chromium → labwc respawns it on the fresh page); if it's still unhealthy the job fails loudly and the kiosk step is skipped, so a broken deploy leaves the **last good page** on the wall. A final `if: always()` step prunes the build cache (≤2GB) + dangling images. Optional-channel secrets are injected here as env vars from GitHub Actions **repository secrets** (`${{ secrets.* }}`), which `docker-compose.yml` interpolates into the container; an unset secret just disables that channel.

The committed copy of this file ships as an inert sample — `.github/workflows/deploy.yml.example` (GitHub only runs `.yml`/`.yaml` files, so the sample never triggers). Rename it to `deploy.yml` to activate.

```yaml
name: Deploy to Pi

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: [self-hosted, focus-wall-pi]
    steps:
      - uses: actions/checkout@v4
        with:
          # actions/checkout defaults to `git clean -ffdx` before checkout,
          # which would delete the runner's untracked .env file (the local
          # fallback for VOICEMONKEY_TOKEN / DISCORD_WEBHOOK_URL / SLACK_WS*).
          clean: false

      - name: Build, deploy, and health-check (auto-recover on failure)
        # Cached build for speed, then GATE on /healthz: if the container isn't
        # serving within 60s, rebuild once with --no-cache to bypass a poisoned
        # cache. If it is STILL unhealthy, FAIL without reloading the kiosk, so
        # the wall keeps showing the last good page.
        run: |
          healthy() {
            for i in $(seq 1 60); do
              curl -sf http://localhost:5050/healthz > /dev/null 2>&1 && return 0
              sleep 1
            done
            return 1
          }

          docker compose up -d --build || { echo "::error::cached build/up failed"; exit 1; }
          if healthy; then echo "Healthy after cached build."; exit 0; fi

          echo "::warning::Unhealthy after cached build — rebuilding with --no-cache."
          docker compose build --no-cache || { echo "::error::--no-cache build failed"; exit 1; }
          docker compose up -d || { echo "::error::up after --no-cache failed"; exit 1; }
          if healthy; then echo "Healthy after clean --no-cache rebuild."; exit 0; fi

          echo "::error::Still unhealthy after clean rebuild — NOT reloading kiosk. Recent state:"
          docker compose ps || true
          docker compose logs --tail 50 focus-wall 2>&1 || true
          exit 1
        env:
          # Repository secrets (Settings → Secrets and variables → Actions),
          # masked in logs. docker compose reads them for the ${VAR}
          # interpolation in docker-compose.yml. Unset → that notifier/panel
          # self-disables. The gitignored .env is the local/manual fallback.
          DISCORD_WEBHOOK_URL: ${{ secrets.DISCORD_WEBHOOK_URL }}
          VOICEMONKEY_TOKEN: ${{ secrets.VOICEMONKEY_TOKEN }}
          VOICEMONKEY_DEVICE: ${{ secrets.VOICEMONKEY_DEVICE }}
          SLACK_WS0_LABEL: ${{ secrets.SLACK_WS0_LABEL }}
          SLACK_WS0_TOKEN: ${{ secrets.SLACK_WS0_TOKEN }}
          SLACK_WS0_COOKIE: ${{ secrets.SLACK_WS0_COOKIE }}
          SLACK_WS1_LABEL: ${{ secrets.SLACK_WS1_LABEL }}
          SLACK_WS1_TOKEN: ${{ secrets.SLACK_WS1_TOKEN }}
          SLACK_WS1_COOKIE: ${{ secrets.SLACK_WS1_COOKIE }}

      - name: Reload kiosk browser
        # Only reached when the server is CONFIRMED healthy. labwc's autostart
        # respawn loop relaunches Chromium on the fresh /wall page. We do NOT
        # reboot: the runner *is* this Pi, so `reboot` would kill the job.
        run: pkill -f 'chromium.*--kiosk' || true

      - name: Prune build cache and dangling images
        # Always run — even after a failed deploy — so a poisoned/oversized
        # cache can't persist. Keep up to 2GB so normal deploys stay fast.
        if: always()
        run: |
          docker builder prune -f --keep-storage=2GB || docker builder prune -f || true
          docker image prune -f || true
```

Secrets turn-on is documented per channel in the `*_SETUP_CHECKLIST.md` files; the local `.env` fallback (kept across deploys by `clean: false`) is described in `DEPLOYMENT.md` § 4a step 6. If you're not using any optional channel, skip all of it — the compose file's `environment:` block reads unset vars as empty and the notifiers/panel just stay disabled.

### Build for the Pi manually (fallback, no CI)

If you're not using the runner above — building on your workstation (x86_64) and pushing to the Pi:

```bash
docker buildx create --use --name multi 2>/dev/null || true
docker buildx build \
  --platform linux/arm64 \
  -t focus-wall:arm64 \
  --load \
  ./src/FocusWall.Server
docker save focus-wall:arm64 | ssh pi@focus-wall.local 'docker load'
```

Or simpler: clone the repo on the Pi and run `docker compose up -d` there. The build takes ~3 minutes on a Pi 5, ~6 on a Pi 4.

### Run on the Pi

```bash
ssh pi@focus-wall.local
git clone <your-repo-url> ~/focus-wall
cd ~/focus-wall
docker compose up -d
docker compose logs -f focus-wall
```

Verify from your workstation: `curl http://focus-wall.local:5050/healthz` should return `ok`.

## Phase 4 — polish checklist

These are the small things that turn the MVP into something genuinely useful.

- [ ] Hero status font scales with viewport — already done via `clamp()` in CSS
- [x] Hide cursor in kiosk mode — done via the `?kiosk=1` URL param in `sse.js` (`initKioskCursor()`, shared by both views). This is the reliable mechanism on the Pi: `unclutter` is X11-only and does nothing under Bookworm's Wayland session
- [ ] Connection banner is unmissable when dead — pulse animation on `.conn.dead`
- [ ] Auto-refresh page if SSE has been dead for >2 minutes (Chromium occasionally locks up)
- [ ] `Cache-Control: no-store` on `index.html`, `app.js`, `app.css` during development; long cache once stable
- [ ] Test the wall view from your actual seat — the test for "readable at 10 feet" only works in situ

## Testing approach

### Unit tests — EventStore

The state machine is the heart of the system and it's pure logic — test it directly, not only through manual scripts. One test project:

```bash
mkdir -p tests/FocusWall.Server.Tests && cd tests/FocusWall.Server.Tests
dotnet new xunit -o . --force
dotnet add reference ../../src/FocusWall.Server/FocusWall.Server.csproj
cd ../..
```

### `tests/FocusWall.Server.Tests/EventStoreTests.cs`

The behaviors that must never regress:

```csharp
using System.Text.Json;
using FocusWall.Server;

public class EventStoreTests
{
    private static JsonElement Ev(string name, string sessionId, string host = "test-host") =>
        JsonDocument.Parse(
            // Trailing braces are spaced ("} }") so the two literal closing
            // braces don't collide with the $$ raw-string interpolation
            // delimiters (a bare "}}" is a compile error, CS9007).
            $$"""{"hook_event_name":"{{name}}","session_id":"{{sessionId}}","_meta":{"hostname":"{{host}}"} }"""
        ).RootElement.Clone();

    [Fact]
    public void WaitingWinsOverWorking()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("Notification", "b"));
        Assert.Equal("waiting", store.GetStatus().Value);
    }

    [Fact]
    public void WaitingHoldsWhileOtherSessionKeepsWorking()
    {
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));
        for (var i = 0; i < 5; i++) store.Add(Ev("PostToolUse", "b"));

        var status = store.GetStatus();
        Assert.Equal("waiting", status.Value);
        Assert.Equal(1, status.WaitingCount);
    }

    [Fact]
    public void SessionEndRemovesSession()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("SessionEnd", "a"));

        var status = store.GetStatus();
        Assert.Equal("idle", status.Value);
        Assert.Equal(0, status.SessionCount);
    }

    [Fact]
    public void SecondSessionEnteringWaitingStillBroadcasts()
    {
        // Regression guard: the global status stays "waiting" and the session
        // count doesn't change, but subscribers must still hear about it —
        // otherwise the notifiers never announce the second session and the
        // hero subtitle names the wrong one.
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("PreToolUse", "b"));
        store.Add(Ev("Notification", "a"));

        var (channel, id) = store.Subscribe();
        store.Add(Ev("Notification", "b"));
        store.Unsubscribe(id);

        var sawBothWaiting = false;
        while (channel.Reader.TryRead(out var msg))
            if (msg is { Kind: "status", Data: GlobalStatus g } && g.WaitingCount == 2)
                sawBothWaiting = true;
        Assert.True(sawBothWaiting);
    }
}
```

Run with:

```bash
dotnet test tests/FocusWall.Server.Tests
```

The time-based behaviors (done → idle after 30s, working → idle after 15 min, 2h prune) depend on wall-clock time; to unit-test those properly, thread a `TimeProvider` through `EventStore` — or accept covering them with the manual scripts below.

### Single-session test

```bash
# Terminal 1: server
cd src/FocusWall.Server && dotnet run

# Terminal 2: simulate one session's lifecycle
./hooks/hook-send.sh <<<'{"hook_event_name":"SessionStart","session_id":"sim1","source":"startup"}'
./hooks/hook-send.sh <<<'{"hook_event_name":"PreToolUse","session_id":"sim1","tool_name":"Bash","tool_input":{"command":"dotnet test"}}'
sleep 2
./hooks/hook-send.sh <<<'{"hook_event_name":"PostToolUse","session_id":"sim1","tool_name":"Bash"}'
./hooks/hook-send.sh <<<'{"hook_event_name":"Notification","session_id":"sim1","message":"Permission requested for Edit"}'
sleep 5
./hooks/hook-send.sh <<<'{"hook_event_name":"Stop","session_id":"sim1","stop_hook_reason":"end_turn"}'
```

### Multi-session "loudest wins" test

This is the acceptance test for Phase 1 — the exact scenario the single-status MVP would fail.

```bash
# 1. Session A starts working
./hooks/hook-send.sh <<<'{"hook_event_name":"SessionStart","session_id":"sessA","source":"startup"}'
./hooks/hook-send.sh <<<'{"hook_event_name":"PreToolUse","session_id":"sessA","tool_name":"Bash","tool_input":{"command":"dotnet test"}}'

# 2. Session B starts working in a different cwd (simulated via cd)
( cd /tmp && ./hooks/hook-send.sh <<<'{"hook_event_name":"SessionStart","session_id":"sessB","source":"startup"}' )
( cd /tmp && ./hooks/hook-send.sh <<<'{"hook_event_name":"PreToolUse","session_id":"sessB","tool_name":"Read","tool_input":{"file_path":"/tmp/foo.txt"}}' )

# Dashboard hero should now say "Working" with summary "2 working (2 total)"

# 3. Session A hits Notification — needs your input
./hooks/hook-send.sh <<<'{"hook_event_name":"Notification","session_id":"sessA","message":"Permission requested"}'

# Dashboard hero should FLIP to "Waiting for you", subtitle showing Session A's cwd

# 4. Session B keeps hammering tool calls — this is the failure case in the MVP
for i in 1 2 3 4 5; do
  ( cd /tmp && ./hooks/hook-send.sh <<<'{"hook_event_name":"PostToolUse","session_id":"sessB","tool_name":"Read"}' )
  ( cd /tmp && ./hooks/hook-send.sh <<<'{"hook_event_name":"PreToolUse","session_id":"sessB","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt"}}' )
  sleep 1
done

# Hero MUST still say "Waiting for you" throughout — Session A is still blocked on you.
# Summary should show "1 waiting · 1 working (2 total)".

# 5. Session A resumes
./hooks/hook-send.sh <<<'{"hook_event_name":"UserPromptSubmit","session_id":"sessA","prompt":"proceed"}'

# Hero drops back to "Working" — B is still running.

# 6. Clean shutdown
./hooks/hook-send.sh <<<'{"hook_event_name":"SessionEnd","session_id":"sessA"}'
( cd /tmp && ./hooks/hook-send.sh <<<'{"hook_event_name":"SessionEnd","session_id":"sessB"}' )
# Hero returns to "Idle".
```

If step 4's hero stays on "Waiting for you" the whole time you're pumping B's events, multi-session is working. If it flips back to "Working" partway through, something's broken in `ComputeGlobalStatusLocked`.

## What "done" looks like for each phase

| Phase | Acceptance test |
|-------|-----------------|
| 1 | Multi-session test above passes; hero holds "Waiting" while other session keeps churning |
| 2 | Same test passes after replacing URL with `focus-wall.local:5050`; container survives `docker restart` |
| 3 | Pull Pi power cord; within 60s, dashboard back on screen with no keyboard |
| 4 | Walk 10 feet from monitor; status word readable; transition to "Waiting" is unmissable |
| 5 | Add hook wrapper to a second workstation; both machines' badges appear in event log |

Move to `HARDWARE.md` for the bill of materials, then `DEPLOYMENT.md` for the Pi setup walkthrough.
