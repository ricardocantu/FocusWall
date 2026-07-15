namespace FocusWall.Server;

// Thread-safe holder for the latest merged feed items, split into the two
// ticker rows the wall renders (news on top, sports on the bottom). The service
// swaps each whole list at once (reference assignment is atomic), so readers
// always see a complete, consistent snapshot.
public class RssCache
{
    public IReadOnlyList<RssItem> News { get; set; } = Array.Empty<RssItem>();
    public IReadOnlyList<RssItem> Sports { get; set; } = Array.Empty<RssItem>();
}

// Fetches the configured feeds on a timer, parses + merges them, and updates the
// cache. Mirrors HeartbeatService's PeriodicTimer/BackgroundService shape.
public class RssService(RssCache cache, IConfiguration config, ILogger<RssService> log)
    : BackgroundService
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(5) };

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var newsFeeds = config.GetSection("Rss:NewsFeeds").Get<string[]>() ?? Array.Empty<string>();
        var sportsFeeds = config.GetSection("Rss:SportsFeeds").Get<string[]>() ?? Array.Empty<string>();
        var refreshMin = Math.Max(1, config.GetValue("Rss:RefreshMinutes", 10));
        var maxItems = config.GetValue("Rss:MaxItems", 30);

        await Refresh(newsFeeds, sportsFeeds, maxItems, ct);   // immediate first load

        var timer = new PeriodicTimer(TimeSpan.FromMinutes(refreshMin));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                await Refresh(newsFeeds, sportsFeeds, maxItems, ct);
        }
        catch (OperationCanceledException) { }
    }

    private async Task Refresh(string[] newsFeeds, string[] sportsFeeds, int maxItems, CancellationToken ct)
    {
        cache.News = await FetchGroup(newsFeeds, maxItems, ct);
        cache.Sports = await FetchGroup(sportsFeeds, maxItems, ct);
    }

    // Fetch + parse one group of feeds and merge them into a single sorted list.
    private async Task<IReadOnlyList<RssItem>> FetchGroup(string[] feeds, int maxItems, CancellationToken ct)
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
        return RssParser.Merge(perFeed, maxItems);
    }

    // Short display label from the feed host, minus common feed-y prefixes.
    private static string SourceLabel(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return url;
        var host = uri.Host;
        foreach (var p in new[] { "www.", "feeds.", "rss.", "feed.", "search." })
            if (host.StartsWith(p)) host = host[p.Length..];
        return host;
    }
}
