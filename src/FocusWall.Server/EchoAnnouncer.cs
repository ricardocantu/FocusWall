namespace FocusWall.Server;

public class EchoAnnouncer(
    EventStore store,
    IHttpClientFactory httpFactory,
    IConfiguration config,
    ILogger<EchoAnnouncer> log) : BackgroundService
{
    private readonly string? _token  = config["VOICEMONKEY_TOKEN"];
    private readonly string? _device = config["VOICEMONKEY_DEVICE"];
    private readonly TimeSpan _cooldown = TimeSpan.FromSeconds(
        int.TryParse(config["VOICEMONKEY_COOLDOWN_SECONDS"], out var s) ? s : 120);
    private readonly TimeOnly? _quietStart =
        TimeOnly.TryParse(config["VOICEMONKEY_QUIET_START"], out var qs) ? qs : null;
    private readonly TimeOnly? _quietEnd =
        TimeOnly.TryParse(config["VOICEMONKEY_QUIET_END"], out var qe) ? qe : null;

    // Per-session cooldown — two concurrent sessions both hitting "waiting"
    // will both announce (rather than one being swallowed).
    private readonly Dictionary<SessionKey, string> _lastAnnouncedStatus = new();
    private readonly Dictionary<SessionKey, DateTimeOffset> _lastAnnouncedAt = new();

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_token) || string.IsNullOrEmpty(_device))
        {
            log.LogInformation(
                "EchoAnnouncer disabled — VOICEMONKEY_TOKEN and VOICEMONKEY_DEVICE not set");
            return;
        }

        var (channel, id) = store.Subscribe();
        log.LogInformation("EchoAnnouncer subscribed (cooldown {Cooldown}s per session)",
            (int)_cooldown.TotalSeconds);

        try
        {
            await foreach (var msg in channel.Reader.ReadAllAsync(ct))
            {
                if (msg.Kind != "status") continue;
                if (msg.Data is not GlobalStatus global) continue;

                // Announce for any session that just transitioned to "waiting".
                foreach (var session in global.Sessions.Where(s => s.Status == "waiting"))
                {
                    if (_lastAnnouncedStatus.TryGetValue(session.Key, out var prev) && prev == "waiting")
                        continue;  // this session already announced its waiting

                    if (IsQuietHours())
                    {
                        log.LogInformation("Suppressed (quiet hours) for {Session}", session.Key.Short);
                        _lastAnnouncedStatus[session.Key] = "waiting";
                        continue;
                    }

                    if (_lastAnnouncedAt.TryGetValue(session.Key, out var last)
                        && DateTimeOffset.UtcNow - last < _cooldown)
                    {
                        log.LogInformation("Suppressed (cooldown) for {Session}", session.Key.Short);
                        continue;
                    }

                    var text = BuildPhrase(session);
                    await AnnounceAsync(text, ct);
                    _lastAnnouncedAt[session.Key] = DateTimeOffset.UtcNow;
                    _lastAnnouncedStatus[session.Key] = "waiting";
                }

                // Reset session cooldown when it leaves "waiting" (so next waiting fires again).
                foreach (var session in global.Sessions.Where(s => s.Status != "waiting"))
                {
                    _lastAnnouncedStatus[session.Key] = session.Status;
                }

                // Forget sessions that are no longer active.
                var activeKeys = global.Sessions.Select(s => s.Key).ToHashSet();
                foreach (var k in _lastAnnouncedStatus.Keys.Except(activeKeys).ToList())
                {
                    _lastAnnouncedStatus.Remove(k);
                    _lastAnnouncedAt.Remove(k);
                }
            }
        }
        catch (OperationCanceledException) { }
        finally { store.Unsubscribe(id); }
    }

    private static string BuildPhrase(SessionState session)
    {
        // If we know the project, name it. Otherwise generic.
        return string.IsNullOrEmpty(session.Cwd)
            ? "Claude is waiting for your input."
            : $"Claude is waiting for your input in {session.Cwd}.";
    }

    private async Task AnnounceAsync(string text, CancellationToken ct)
    {
        var url = "https://api-utility.voicemonkey.io/v2/announcement"
                + $"?token={Uri.EscapeDataString(_token!)}"
                + $"&device={Uri.EscapeDataString(_device!)}"
                + $"&text={Uri.EscapeDataString(text)}";
        try
        {
            using var http = httpFactory.CreateClient();
            http.Timeout = TimeSpan.FromSeconds(3);
            var res = await http.GetAsync(url, ct);
            if (!res.IsSuccessStatusCode)
                log.LogWarning("Voice Monkey returned {Status} for: {Text}",
                    (int)res.StatusCode, text);
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "Voice Monkey call failed");
            // fire-and-forget — never bubble up
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
