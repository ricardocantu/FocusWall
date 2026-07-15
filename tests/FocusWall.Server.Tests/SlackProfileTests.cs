using FocusWall.Server;

public class SlackProfileTests
{
    [Fact]
    public void ParsesActivePresence()
    {
        Assert.Equal("active", SlackProfile.ParsePresence("""{ "ok": true, "presence": "active" }"""));
    }

    [Fact]
    public void ParsesAwayPresence()
    {
        Assert.Equal("away", SlackProfile.ParsePresence("""{ "ok": true, "presence": "away" }"""));
    }

    [Fact]
    public void MissingPresenceIsNull()
    {
        Assert.Null(SlackProfile.ParsePresence("""{ "ok": true }"""));
    }

    [Fact]
    public void ParsesStatusTextAndEmoji()
    {
        var (text, emoji) = SlackProfile.ParseStatus(
            """{ "ok": true, "profile": { "status_text": "shipping v2", "status_emoji": ":rocket:" } }""");
        Assert.Equal("shipping v2", text);
        Assert.Equal(":rocket:", emoji);
    }

    [Fact]
    public void EmptyStatusFieldsBecomeNull()
    {
        var (text, emoji) = SlackProfile.ParseStatus(
            """{ "ok": true, "profile": { "status_text": "", "status_emoji": "" } }""");
        Assert.Null(text);
        Assert.Null(emoji);
    }

    [Fact]
    public void MissingProfileIsNulls()
    {
        var (text, emoji) = SlackProfile.ParseStatus("""{ "ok": true }""");
        Assert.Null(text);
        Assert.Null(emoji);
    }
}
