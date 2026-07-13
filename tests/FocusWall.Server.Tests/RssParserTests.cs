using FocusWall.Server;

public class RssParserTests
{
    private const string Rss2 = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Test Feed</title>
          <item><title>First</title><link>https://ex.com/1</link>
            <pubDate>Wed, 08 Jul 2026 10:00:00 GMT</pubDate></item>
          <item><title>Second</title><link>https://ex.com/2</link>
            <pubDate>Wed, 08 Jul 2026 09:00:00 GMT</pubDate></item>
        </channel></rss>
        """;

    private const string Atom = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Test</title>
          <entry><title>Atom One</title><link href="https://ex.com/a1"/>
            <updated>2026-07-08T11:00:00Z</updated><id>urn:1</id></entry>
        </feed>
        """;

    [Fact]
    public void ParsesRss2WithSourceTitleAndLink()
    {
        var items = RssParser.ParseFeed(Rss2, "ex.com");
        Assert.Equal(2, items.Count);
        Assert.Equal("ex.com", items[0].Source);
        Assert.Equal("First", items[0].Title);
        Assert.Equal("https://ex.com/1", items[0].Link);
    }

    [Fact]
    public void ParsesAtomUsingUpdatedWhenNoPubDate()
    {
        var items = RssParser.ParseFeed(Atom, "ex.com");
        Assert.Single(items);
        Assert.Equal("Atom One", items[0].Title);
        // <updated> feeds the date via the LastUpdatedTime fallback.
        Assert.Equal(2026, items[0].PublishedAt.Year);
        Assert.Equal(7, items[0].PublishedAt.Month);
    }

    [Fact]
    public void MergeSortsNewestFirstAndCaps()
    {
        var a = RssParser.ParseFeed(Rss2, "a");   // 10:00 and 09:00
        var b = RssParser.ParseFeed(Atom, "b");   // 11:00
        var merged = RssParser.Merge(new[] { a, b }, 2);
        Assert.Equal(2, merged.Count);
        Assert.Equal("Atom One", merged[0].Title);  // 11:00 newest
        Assert.Equal("First", merged[1].Title);     // 10:00 next
    }

    [Fact]
    public void MalformedXmlThrowsSoCallerCanSkip()
    {
        Assert.ThrowsAny<Exception>(() => RssParser.ParseFeed("<not-valid", "x"));
    }
}
