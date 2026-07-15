namespace FocusWall.Server;

using System.Text.Json;

// Pure parsers for Slack's users.getPresence and users.profile.get responses.
// HTTP-free so they're unit-testable from captured payloads, like SlackCounts.
public static class SlackProfile
{
    // { "ok": true, "presence": "active" | "away" }
    public static string? ParsePresence(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.TryGetProperty("presence", out var p) && p.ValueKind == JsonValueKind.String
            ? p.GetString()
            : null;
    }

    // { "ok": true, "profile": { "status_text": "...", "status_emoji": ":x:" } }
    // Empty strings are normalized to null so the UI can treat "no status" uniformly.
    public static (string? Text, string? Emoji) ParseStatus(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("profile", out var prof) || prof.ValueKind != JsonValueKind.Object)
            return (null, null);
        return (Field(prof, "status_text"), Field(prof, "status_emoji"));
    }

    private static string? Field(JsonElement obj, string name)
    {
        if (obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String)
        {
            var s = v.GetString();
            return string.IsNullOrEmpty(s) ? null : s;
        }
        return null;
    }
}
