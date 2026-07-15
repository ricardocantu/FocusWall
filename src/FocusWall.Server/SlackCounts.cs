namespace FocusWall.Server;

using System.Text.Json;

// Raised when client.counts returns {"ok": false, "error": "..."}. The service
// inspects SlackError to classify auth failures vs. transient failures.
public class SlackApiException(string error) : Exception(error)
{
    public string SlackError => Message;
}

// Reduced badge summary for one workspace. Mentions/AnyUnread are Slack's
// combined badge total across every section (channels + mpims + ims +
// threads) — that's what client.counts itself represents, since Slack sets
// mention_count on ims/mpims for any unread DM message (a 1:1 conversation
// has no @mention concept). ChannelMentions/DmMentions split that same sum
// by category so a UI can show a channel-only "Mentions" figure without
// silently folding in DM activity. Pure + HTTP-free so it is unit-testable
// from a captured payload, exactly like RssParser.ParseFeed.
public record SlackCounts(
    int Mentions, bool AnyUnread, int ChannelsUnread, int DmsUnread, int ThreadsUnread,
    int ChannelMentions, int DmMentions)
{
    public static SlackCounts Reduce(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.False)
        {
            var err = root.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String
                ? e.GetString()! : "unknown";
            throw new SlackApiException(err);
        }

        int mentions = 0, channelsUnread = 0, dmsUnread = 0, threadsUnread = 0;
        int channelMentions = 0, dmMentions = 0;
        bool anyUnread = false;

        channelsUnread = CountArray(root, "channels", ref mentions, ref anyUnread, ref channelMentions);
        dmsUnread += CountArray(root, "mpims", ref mentions, ref anyUnread, ref dmMentions);
        dmsUnread += CountArray(root, "ims", ref mentions, ref anyUnread, ref dmMentions);

        // threads is an object, not an array.
        if (root.TryGetProperty("threads", out var threads) && threads.ValueKind == JsonValueKind.Object)
            if (Accumulate(threads, out _, ref mentions, ref anyUnread)) threadsUnread = 1;

        return new SlackCounts(mentions, anyUnread, channelsUnread, dmsUnread, threadsUnread, channelMentions, dmMentions);
    }

    // Returns how many entries in the named array had has_unreads:true; adds
    // the array's mention_count total into both the shared `mentions` total
    // and the category-specific `categoryMentions`.
    private static int CountArray(JsonElement root, string section, ref int mentions, ref bool anyUnread, ref int categoryMentions)
    {
        if (!root.TryGetProperty(section, out var arr) || arr.ValueKind != JsonValueKind.Array)
            return 0;
        int unread = 0;
        foreach (var item in arr.EnumerateArray())
        {
            if (Accumulate(item, out var itemMentions, ref mentions, ref anyUnread)) unread++;
            categoryMentions += itemMentions;
        }
        return unread;
    }

    // Adds this element's mentions, ORs global unread, and returns whether THIS
    // element is unread (so callers can count unread entries per category).
    // itemMentions surfaces this element's own mention_count so callers can
    // roll it up per-category as well as into the shared total.
    private static bool Accumulate(JsonElement el, out int itemMentions, ref int mentions, ref bool anyUnread)
    {
        itemMentions = el.TryGetProperty("mention_count", out var mc) && mc.ValueKind == JsonValueKind.Number
            ? mc.GetInt32() : 0;
        mentions += itemMentions;
        bool unread = el.TryGetProperty("has_unreads", out var hu) && hu.ValueKind == JsonValueKind.True;
        if (unread) anyUnread = true;
        return unread;
    }
}
