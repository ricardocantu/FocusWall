namespace FocusWall.Server;

using System.Text.Json.Serialization;

public record UsageLimit(
    [property: JsonPropertyName("kind")]      string Kind,
    [property: JsonPropertyName("group")]     string Group,
    [property: JsonPropertyName("percent")]   double Percent,
    [property: JsonPropertyName("severity")]  string Severity,
    [property: JsonPropertyName("resets_at")] DateTimeOffset? ResetsAt,
    [property: JsonPropertyName("model")]     string? Model,
    [property: JsonPropertyName("is_active")] bool IsActive);

public record UsageReport(
    [property: JsonPropertyName("host")]   string Host,
    [property: JsonPropertyName("label")]  string Label,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("limits")] List<UsageLimit> Limits,
    [property: JsonPropertyName("ts")]     DateTimeOffset Ts);

public record UsageStateEntry(
    string Host,
    string Label,
    string Status,
    List<UsageLimit> Limits,
    DateTimeOffset Ts,
    DateTimeOffset ReceivedAt,
    bool Stale);

public class UsageStore
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(15);

    private readonly Dictionary<string, (UsageReport Report, DateTimeOffset ReceivedAt)> _byHost = new();
    private readonly object _lock = new();

    public void Upsert(UsageReport report, DateTimeOffset receivedAt)
    {
        lock (_lock)
        {
            _byHost[report.Host] = (report, receivedAt);
        }
    }

    public IReadOnlyList<UsageStateEntry> GetState(DateTimeOffset now)
    {
        lock (_lock)
        {
            return _byHost.Values
                .Select(v => new UsageStateEntry(
                    v.Report.Host, v.Report.Label, v.Report.Status,
                    v.Report.Limits ?? new List<UsageLimit>(), v.Report.Ts,
                    v.ReceivedAt, now - v.ReceivedAt > StaleAfter))
                .OrderBy(e => e.Label, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }
}
