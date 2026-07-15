using FocusWall.Server;

public class SlackCountsTests
{
    // Shape based on observed client.counts responses; reconciled against a live
    // payload in Task 6. Arrays of {id, mention_count, has_unreads}; threads is
    // an object with the same two fields.
    private const string Mixed = """
        {
          "ok": true,
          "channels": [
            { "id": "C1", "mention_count": 2, "has_unreads": true },
            { "id": "C2", "mention_count": 0, "has_unreads": true }
          ],
          "mpims": [ { "id": "G1", "mention_count": 1, "has_unreads": true } ],
          "ims":   [ { "id": "D1", "mention_count": 3, "has_unreads": true } ],
          "threads": { "mention_count": 1, "has_unreads": true }
        }
        """;

    private const string Clear = """
        {
          "ok": true,
          "channels": [ { "id": "C1", "mention_count": 0, "has_unreads": false } ],
          "mpims": [], "ims": [],
          "threads": { "mention_count": 0, "has_unreads": false }
        }
        """;

    private const string MissingSections = """
        { "ok": true, "channels": [ { "id": "C1", "mention_count": 4, "has_unreads": true } ] }
        """;

    private const string NotAuthed = """
        { "ok": false, "error": "invalid_auth" }
        """;

    [Fact]
    public void SumsMentionsAndOrsUnreadsAcrossAllSections()
    {
        var c = SlackCounts.Reduce(Mixed);
        Assert.Equal(7, c.Mentions);   // 2 + 0 + 1 + 3 + 1
        Assert.True(c.AnyUnread);
        Assert.Equal(2, c.ChannelsUnread);  // C1 + C2 both unread
        Assert.Equal(2, c.DmsUnread);       // G1 (mpim) + D1 (im)
        Assert.Equal(1, c.ThreadsUnread);   // threads object unread
        Assert.Equal(2, c.ChannelMentions); // C1(2) + C2(0), channels only
        Assert.Equal(4, c.DmMentions);      // G1(1) + D1(3), mpims + ims only
    }

    [Fact]
    public void AllClearIsZeroAndFalse()
    {
        var c = SlackCounts.Reduce(Clear);
        Assert.Equal(0, c.Mentions);
        Assert.False(c.AnyUnread);
        Assert.Equal(0, c.ChannelsUnread);
        Assert.Equal(0, c.DmsUnread);
        Assert.Equal(0, c.ThreadsUnread);
        Assert.Equal(0, c.ChannelMentions);
        Assert.Equal(0, c.DmMentions);
    }

    [Fact]
    public void ToleratesMissingSections()
    {
        var c = SlackCounts.Reduce(MissingSections);
        Assert.Equal(4, c.Mentions);
        Assert.True(c.AnyUnread);
        Assert.Equal(4, c.ChannelMentions);
        Assert.Equal(0, c.DmMentions);
    }

    [Fact]
    public void ThrowsSlackApiExceptionCarryingErrorWhenOkFalse()
    {
        var ex = Assert.Throws<SlackApiException>(() => SlackCounts.Reduce(NotAuthed));
        Assert.Equal("invalid_auth", ex.SlackError);
    }
}
