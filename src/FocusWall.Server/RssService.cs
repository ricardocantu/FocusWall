namespace FocusWall.Server;

// Thread-safe holder for the latest merged feed items. The service swaps the
// whole list at once (reference assignment is atomic), so readers always see a
// complete, consistent snapshot.
public class RssCache
{
    public IReadOnlyList<RssItem> Items { get; set; } = Array.Empty<RssItem>();
}

// Fetches the configured feeds on a timer, parses + merges them, and updates the
// cache. Mirrors HeartbeatService's PeriodicTimer/BackgroundService shape.
public class RssService(RssCache cache, IConfiguration config, ILogger<RssService> log)
    : BackgroundService
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(5) };

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var feeds = config.GetSection("Rss:Feeds").Get<string[]>() ?? Array.Empty<string>();
        var refreshMin = Math.Max(1, config.GetValue("Rss:RefreshMinutes", 10));
        var maxItems = config.GetValue("Rss:MaxItems", 30);

        await Refresh(feeds, maxItems, ct);   // immediate first load

        var timer = new PeriodicTimer(TimeSpan.FromMinutes(refreshMin));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                await Refresh(feeds, maxItems, ct);
        }
        catch (OperationCanceledException) { }
    }

    private async Task Refresh(string[] feeds, int maxItems, CancellationToken ct)
    {
        var perFeed = new List<List<RssItem>>();
        foreach (var url in feeds)
        {
            try
            {
                var xml = await _http.GetStringAsync(url, ct);
                perFeed.Add(RssParser.ParseFeed(xml, SourceLabel(url)));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                // One bad feed is skipped; the rest still populate the ticker.
                log.LogWarning("RSS feed {Url} failed: {Message}", url, ex.Message);
            }
        }
        cache.Items = RssParser.Merge(perFeed, maxItems);
    }

    // Short display label from the feed host, minus common feed-y prefixes.
    private static string SourceLabel(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return url;
        var host = uri.Host;
        foreach (var p in new[] { "www.", "feeds.", "rss.", "feed." })
            if (host.StartsWith(p)) host = host[p.Length..];
        return host;
    }
}
