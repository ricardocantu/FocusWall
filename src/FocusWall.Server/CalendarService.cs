namespace FocusWall.Server;

// One configured calendar. Bound from Calendar:Sources (appsettings) or the
// Calendar__Sources__N__* env vars injected at deploy time. IcsUrl is the
// provider's "secret address in iCal format" — a plain HTTP GET, no OAuth.
public record CalendarSource
{
    public string Label { get; init; } = "";
    public string IcsUrl { get; init; } = "";
}

// Latest reduced summary for one calendar. Serializes as plain camelCase from
// GET /calendar/state (no [JsonPropertyName] seam, unlike the usage page).
public record CalendarSourceState(
    string Label, IReadOnlyList<CalendarEventInfo> Events, string? Error, DateTimeOffset UpdatedAt);

// Thread-safe holder; the service swaps the whole list at once (reference
// assignment is atomic), so readers always see a consistent snapshot. Mirrors
// RssCache/SlackCache.
public class CalendarCache
{
    public IReadOnlyList<CalendarSourceState> Sources { get; set; } = Array.Empty<CalendarSourceState>();
}

// Polls each configured calendar's secret ICS URL on a timer, parses it via
// IcsParser, and updates the cache. Mirrors SlackService's per-source
// independent-fetch shape. Self-disables when no source has an IcsUrl.
public class CalendarService(
    CalendarCache cache,
    IConfiguration config,
    IHttpClientFactory httpFactory,
    ILogger<CalendarService> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var sources = (config.GetSection("Calendar:Sources").Get<CalendarSource[]>() ?? Array.Empty<CalendarSource>())
            .Where(s => !string.IsNullOrEmpty(s.IcsUrl))
            .ToArray();

        if (sources.Length == 0)
        {
            log.LogInformation("CalendarService disabled — no Calendar:Sources configured");
            return;
        }

        var refreshMin = Math.Max(1, config.GetValue("Calendar:RefreshMinutes", 15));
        var http = httpFactory.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(10); // ICS feeds can run larger than RSS/Slack payloads

        log.LogInformation("CalendarService polling {Count} source(s) every {Min}m", sources.Length, refreshMin);

        await Refresh(sources, http, ct); // immediate first load

        var timer = new PeriodicTimer(TimeSpan.FromMinutes(refreshMin));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                await Refresh(sources, http, ct);
        }
        catch (OperationCanceledException) { }
    }

    private async Task Refresh(CalendarSource[] sources, HttpClient http, CancellationToken ct)
    {
        var states = new List<CalendarSourceState>(sources.Length);
        foreach (var src in sources)
            states.Add(await FetchOne(src, http, ct));
        cache.Sources = states;
    }

    private async Task<CalendarSourceState> FetchOne(CalendarSource src, HttpClient http, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        try
        {
            var ics = await http.GetStringAsync(src.IcsUrl, ct);
            var today = DateOnly.FromDateTime(DateTime.Now); // server-local "today", same convention as the kiosk clock
            var events = IcsParser.ParseToday(ics, today, TimeZoneInfo.Local);
            return new CalendarSourceState(src.Label, events, null, now);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex)
        {
            // Log only the exception type, never ex.Message — HttpRequestException's
            // message can echo the request URI, and IcsUrl is a secret feed address.
            log.LogWarning("Calendar source {Label}: fetch_failed ({ExceptionType})", src.Label, ex.GetType().Name);
            return new CalendarSourceState(src.Label, Array.Empty<CalendarEventInfo>(), "fetch_failed", now);
        }
    }
}
