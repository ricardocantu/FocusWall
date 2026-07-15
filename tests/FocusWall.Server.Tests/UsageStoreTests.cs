using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using FocusWall.Server;

public class UsageStoreTests
{
    private static UsageReport Report(string host, string label = "acct", string status = "ok") =>
        new(host, label, status,
            new List<UsageLimit>
            {
                new("weekly_scoped", "weekly", 100, "critical",
                    DateTimeOffset.Parse("2026-07-15T18:59:59Z"), "Fable", true)
            },
            DateTimeOffset.Parse("2026-07-13T22:00:00Z"));

    [Fact]
    public void UpsertReplacesByHost()
    {
        var store = new UsageStore();
        var now = DateTimeOffset.Parse("2026-07-13T22:05:00Z");
        store.Upsert(Report("mac", label: "old"), now);
        store.Upsert(Report("mac", label: "new"), now);

        var state = store.GetState(now);
        Assert.Single(state);
        Assert.Equal("new", state[0].Label);
    }

    [Fact]
    public void FreshReportIsNotStale()
    {
        var store = new UsageStore();
        var t = DateTimeOffset.Parse("2026-07-13T22:00:00Z");
        store.Upsert(Report("mac"), t);
        Assert.False(store.GetState(t.AddMinutes(14)).Single().Stale);
    }

    [Fact]
    public void OldReportIsStaleAfter15Minutes()
    {
        var store = new UsageStore();
        var t = DateTimeOffset.Parse("2026-07-13T22:00:00Z");
        store.Upsert(Report("mac"), t);
        Assert.True(store.GetState(t.AddMinutes(16)).Single().Stale);
    }

    [Fact]
    public void GetStateOrdersByLabelCaseInsensitive()
    {
        var store = new UsageStore();
        var now = DateTimeOffset.Parse("2026-07-13T22:00:00Z");
        store.Upsert(Report("h1", label: "zeta"), now);
        store.Upsert(Report("h2", label: "Alpha"), now);
        var labels = store.GetState(now).Select(e => e.Label).ToList();
        Assert.Equal(new[] { "Alpha", "zeta" }, labels);
    }

    [Fact]
    public void StateEntrySerializesWithExpectedCasing()
    {
        var entry = new UsageStateEntry(
            "mac", "Personal", "ok",
            new List<UsageLimit>
            {
                new("weekly_scoped", "weekly", 100, "critical",
                    DateTimeOffset.Parse("2026-07-15T18:59:59Z"), "Fable", true)
            },
            DateTimeOffset.Parse("2026-07-13T22:00:00Z"),
            DateTimeOffset.Parse("2026-07-13T22:00:05Z"),
            false);

        var json = JsonSerializer.Serialize(entry, JsonSerializerOptions.Web);

        // Entry fields serialize camelCase (default Web policy)
        Assert.Contains("\"receivedAt\"", json);
        Assert.Contains("\"stale\"", json);
        // Limit fields serialize snake_case (JsonPropertyName overrides the Web policy)
        Assert.Contains("\"resets_at\"", json);
        Assert.Contains("\"is_active\"", json);
        // The camelCase forms of the limit fields must NOT appear — that would blank the gauges
        Assert.DoesNotContain("\"resetsAt\"", json);
        Assert.DoesNotContain("\"isActive\"", json);
    }
}
