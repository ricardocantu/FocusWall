using System.Text.Json;
using FocusWall.Server;
using System.Linq;

public class SnoozeTests
{
    private static JsonElement Ev(string name, string sessionId, string host = "test-host") =>
        JsonDocument.Parse(
            $$"""{"hook_event_name":"{{name}}","session_id":"{{sessionId}}","_meta":{"hostname":"{{host}}"} }"""
        ).RootElement.Clone();

    [Fact]
    public void SnoozeSetsFutureSnoozedUntil()
    {
        var store = new EventStore();
        var before = DateTimeOffset.UtcNow;

        store.Snooze(30);

        var su = store.GetStatus().SnoozedUntil;
        Assert.NotNull(su);
        Assert.True(su > before.AddMinutes(29) && su <= before.AddMinutes(31));
    }

    [Fact]
    public void SnoozeZeroClears()
    {
        var store = new EventStore();
        store.Snooze(30);
        Assert.NotNull(store.GetStatus().SnoozedUntil);

        store.Snooze(0);
        Assert.Null(store.GetStatus().SnoozedUntil);
    }

    [Fact]
    public void SnoozeIsOverlayNotAStateTransition()
    {
        // The overlay must not corrupt the state machine: a waiting session stays
        // waiting and the global loudest value stays "waiting" while snoozed.
        // Suppression is the client's/notifiers' job, driven off SnoozedUntil.
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));   // → waiting
        store.Snooze(30);

        var status = store.GetStatus();
        Assert.Equal("waiting", status.Value);
        Assert.Equal("waiting", status.Sessions.Single().Status);
        Assert.NotNull(status.SnoozedUntil);
    }

    [Fact]
    public void SnoozeBroadcastsStatusToSubscribers()
    {
        // Snooze is a user action — it must push a fresh status immediately so
        // every connected view + the notifiers react without waiting for the
        // next event or heartbeat.
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));

        var (channel, id) = store.Subscribe();
        store.Snooze(30);
        store.Unsubscribe(id);

        var sawSnoozed = false;
        while (channel.Reader.TryRead(out var msg))
            if (msg is { Kind: "status", Data: GlobalStatus g } && g.SnoozedUntil is not null)
                sawSnoozed = true;
        Assert.True(sawSnoozed);
    }
}
