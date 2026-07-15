namespace FocusWall.Server;

using System.Text;
using System.Text.Json;

public class DiscordNotifier(
    EventStore store,
    IHttpClientFactory httpFactory,
    IConfiguration config,
    ILogger<DiscordNotifier> log) : BackgroundService
{
    private readonly string? _webhookUrl = config["DISCORD_WEBHOOK_URL"];
    private readonly string? _dashboardUrl = config["DISCORD_DASHBOARD_URL"];
    private readonly TimeSpan _cooldown = TimeSpan.FromSeconds(
        int.TryParse(config["DISCORD_COOLDOWN_SECONDS"], out var s) ? s : 120);
    private readonly TimeOnly? _quietStart =
        TimeOnly.TryParse(config["DISCORD_QUIET_START"], out var qs) ? qs : null;
    private readonly TimeOnly? _quietEnd =
        TimeOnly.TryParse(config["DISCORD_QUIET_END"], out var qe) ? qe : null;

    // Colors as decimal ints (Discord's embed.color format).
    // Matches the wall's palette in ARCHITECTURE.md.
    private const int ColorWaiting = 0xBA7517;  // amber

    // Per-session tracking, same pattern as EchoAnnouncer.
    private readonly Dictionary<SessionKey, string> _lastNotifiedStatus = new();
    private readonly Dictionary<SessionKey, DateTimeOffset> _lastNotifiedAt = new();

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_webhookUrl))
        {
            log.LogInformation("DiscordNotifier disabled — DISCORD_WEBHOOK_URL not set");
            return;
        }

        var (channel, id) = store.Subscribe();
        log.LogInformation("DiscordNotifier subscribed (cooldown {Cooldown}s per session)",
            (int)_cooldown.TotalSeconds);

        try
        {
            await foreach (var msg in channel.Reader.ReadAllAsync(ct))
            {
                if (msg.Kind != "status") continue;
                if (msg.Data is not GlobalStatus global) continue;

                // Notify for any session freshly transitioning to "waiting".
                foreach (var session in global.Sessions.Where(s => s.Status == "waiting"))
                {
                    if (_lastNotifiedStatus.TryGetValue(session.Key, out var prev) && prev == "waiting")
                        continue;

                    if (global.SnoozedUntil > DateTimeOffset.UtcNow)
                    {
                        // Mark as notified so it doesn't back-fire the instant
                        // snooze ends — same bookkeeping as quiet hours.
                        log.LogInformation("Suppressed (snoozed) for {Session}", session.Key.Short);
                        _lastNotifiedStatus[session.Key] = "waiting";
                        continue;
                    }

                    if (IsQuietHours())
                    {
                        log.LogInformation("Suppressed (quiet hours) for {Session}", session.Key.Short);
                        _lastNotifiedStatus[session.Key] = "waiting";
                        continue;
                    }

                    if (_lastNotifiedAt.TryGetValue(session.Key, out var last)
                        && DateTimeOffset.UtcNow - last < _cooldown)
                    {
                        log.LogInformation("Suppressed (cooldown) for {Session}", session.Key.Short);
                        continue;
                    }

                    await NotifyAsync(session, ct);
                    _lastNotifiedAt[session.Key] = DateTimeOffset.UtcNow;
                    _lastNotifiedStatus[session.Key] = "waiting";
                }

                // Reset when a session leaves "waiting" so the next waiting fires again.
                foreach (var session in global.Sessions.Where(s => s.Status != "waiting"))
                    _lastNotifiedStatus[session.Key] = session.Status;

                // Prune ended sessions.
                var activeKeys = global.Sessions.Select(s => s.Key).ToHashSet();
                foreach (var k in _lastNotifiedStatus.Keys.Except(activeKeys).ToList())
                {
                    _lastNotifiedStatus.Remove(k);
                    _lastNotifiedAt.Remove(k);
                }
            }
        }
        catch (OperationCanceledException) { }
        finally { store.Unsubscribe(id); }
    }

    private async Task NotifyAsync(SessionState session, CancellationToken ct)
    {
        // Try to pull the human-readable message from the triggering event.
        var description = "Permission requested";
        if (session.LastEvent is { Payload: var payload }
            && payload.TryGetProperty("message", out var msgEl)
            && msgEl.ValueKind == JsonValueKind.String)
        {
            var m = msgEl.GetString();
            if (!string.IsNullOrWhiteSpace(m)) description = m!;
        }

        var embed = new Dictionary<string, object?>
        {
            ["title"] = "Claude is waiting for you",
            ["description"] = description,
            ["color"] = ColorWaiting,
            ["fields"] = new object[]
            {
                new { name = "Session", value = $"`{session.Key.Short}`", inline = true },
                new { name = "Project", value = $"`{session.Cwd ?? "(unknown)"}`", inline = true }
            },
            ["footer"] = new { text = "Claude Focus Wall" },
            ["timestamp"] = DateTimeOffset.UtcNow.ToString("o")
        };
        if (!string.IsNullOrEmpty(_dashboardUrl)) embed["url"] = _dashboardUrl;

        var body = JsonSerializer.Serialize(new
        {
            username = "Claude Focus Wall",
            embeds = new[] { embed }
        });

        try
        {
            using var http = httpFactory.CreateClient();
            http.Timeout = TimeSpan.FromSeconds(3);
            using var content = new StringContent(body, Encoding.UTF8, "application/json");
            var res = await http.PostAsync(_webhookUrl, content, ct);
            if (!res.IsSuccessStatusCode)
            {
                var responseBody = await res.Content.ReadAsStringAsync(ct);
                log.LogWarning("Discord returned {Status}: {Body}",
                    (int)res.StatusCode, responseBody);
            }
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "Discord webhook call failed");
        }
    }

    private bool IsQuietHours()
    {
        if (_quietStart is null || _quietEnd is null) return false;
        var now = TimeOnly.FromDateTime(DateTime.Now);
        return _quietStart < _quietEnd
            ? now >= _quietStart && now < _quietEnd
            : now >= _quietStart || now < _quietEnd;
    }
}
