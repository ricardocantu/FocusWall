using System.Text.Json;
using FocusWall.Server;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<EventStore>();
builder.Services.AddHostedService<HeartbeatService>();
builder.Services.AddSingleton<RssCache>();
builder.Services.AddHostedService<RssService>();
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

app.MapGet("/healthz", () => Results.Ok("ok"));

app.MapGet("/rss", (RssCache cache) => Results.Json(cache.Items));

app.MapGet("/hero", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "hero.html"), "text/html"));

app.MapGet("/wall", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "wall.html"), "text/html"));

app.MapGet("/mobile", () =>
    Results.File(Path.Combine(app.Environment.WebRootPath, "mobile.html"), "text/html"));

app.Run("http://0.0.0.0:5050");

static async Task SseWrite(HttpResponse res, string ev, object data, CancellationToken ct)
{
    // Web options = camelCase, matching Results.Json on GET /events —
    // the dashboard sees a single casing everywhere.
    var json = JsonSerializer.Serialize(data, JsonSerializerOptions.Web);
    await res.WriteAsync($"event: {ev}\ndata: {json}\n\n", ct);
    await res.Body.FlushAsync(ct);
}
