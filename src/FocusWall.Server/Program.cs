using System.Text.Json;
using FocusWall.Server;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<EventStore>();
builder.Services.AddSingleton<UsageStore>();
builder.Services.AddHostedService<HeartbeatService>();
builder.Services.AddSingleton<RssCache>();
builder.Services.AddHostedService<RssService>();
builder.Services.AddSingleton<SlackCache>();
builder.Services.AddHostedService<SlackService>();
builder.Services.AddHttpClient();
builder.Services.AddHostedService<DiscordNotifier>();
builder.Services.AddHostedService<EchoAnnouncer>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles(new StaticFileOptions
{
    // Build is still evolving and the kiosk has bitten us with stale assets, so
    // never let Chromium cache the dashboard files. Swap to a long max-age once
    // the frontend stabilizes.
    OnPrepareResponse = ctx =>
        ctx.Context.Response.Headers["Cache-Control"] = "no-store"
});

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

// Snooze the wall for N minutes (?minutes=30). minutes=0 clears. Unauthenticated
// like every other endpoint — trusted-LAN threat model. The button lives on
// /mobile (the wall kiosk is deliberately cursorless).
app.MapPost("/snooze", (int minutes, EventStore store) =>
    Results.Json(new { snoozedUntil = store.Snooze(minutes).SnoozedUntil }));

app.MapGet("/healthz", () => Results.Ok("ok"));

app.MapGet("/rss", (RssCache cache) => Results.Json(new { news = cache.News, sports = cache.Sports }));

app.MapGet("/slack/state", (SlackCache cache) =>
{
    var ws = cache.Workspaces;
    return Results.Json(new
    {
        ok = true,
        totalMentions = ws.Sum(w => w.Mentions),
        anyUnread = ws.Any(w => w.AnyUnread),
        workspaces = ws,
        updatedAt = ws.Count > 0 ? ws.Max(w => w.UpdatedAt) : (DateTimeOffset?)null
    });
});

app.MapGet("/hero", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "hero.html"), "text/html"));

app.MapGet("/wall", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "wall.html"), "text/html"));

app.MapGet("/mobile", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "mobile.html"), "text/html"));

app.MapPost("/usage/report", (UsageReport report, UsageStore store) =>
{
    store.Upsert(report, DateTimeOffset.UtcNow);
    return Results.Ok(new { ok = true });
});

app.MapGet("/usage/state", (UsageStore store) =>
    Results.Json(new { accounts = store.GetState(DateTimeOffset.UtcNow) }));

app.MapGet("/usage", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "usage.html"), "text/html"));

app.Run("http://0.0.0.0:5050");

static async Task SseWrite(HttpResponse res, string ev, object data, CancellationToken ct)
{
    // Web options = camelCase, matching Results.Json on GET /events —
    // the dashboard sees a single casing everywhere.
    var json = JsonSerializer.Serialize(data, JsonSerializerOptions.Web);
    await res.WriteAsync($"event: {ev}\ndata: {json}\n\n", ct);
    await res.Body.FlushAsync(ct);
}
