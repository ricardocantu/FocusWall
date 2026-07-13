using System.ServiceModel.Syndication;
using System.Xml;

namespace FocusWall.Server;

public record RssItem(string Source, string Title, string? Link, DateTimeOffset PublishedAt);

public static class RssParser
{
    // Parse one feed document (RSS 2.0 or Atom) into items tagged with `source`.
    // Throws on malformed XML — RssService catches per-feed so one bad feed is
    // skipped without stalling the rest. XmlReader.Create defaults to
    // DtdProcessing.Prohibit, so external feeds can't trigger XXE.
    public static List<RssItem> ParseFeed(string xml, string source)
    {
        using var reader = XmlReader.Create(new StringReader(xml));
        var feed = SyndicationFeed.Load(reader);
        var items = new List<RssItem>();
        if (feed is null) return items;

        foreach (var item in feed.Items)
        {
            var title = item.Title?.Text?.Trim();
            if (string.IsNullOrEmpty(title)) continue;

            var link = item.Links.FirstOrDefault()?.Uri?.ToString();

            // Prefer <pubDate>/<published>; fall back to <updated> (many Atom
            // feeds only set the latter).
            var published = item.PublishDate;
            if (published == default) published = item.LastUpdatedTime;

            items.Add(new RssItem(source, title, link, published));
        }
        return items;
    }

    // Flatten all feeds, newest first, capped at maxItems.
    public static List<RssItem> Merge(IEnumerable<IEnumerable<RssItem>> feeds, int maxItems) =>
        feeds.SelectMany(f => f)
             .OrderByDescending(i => i.PublishedAt)
             .Take(maxItems)
             .ToList();
}
