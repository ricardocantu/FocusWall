using System.Text.Json;
using FocusWall.Server;
using System.Linq;

public class CloseSessionTests
{
    private static JsonElement Ev(string name, string sessionId, string host = "test-host") =>
        JsonDocument.Parse(
            $$"""{"hook_event_name":"{{name}}","session_id":"{{sessionId}}","_meta":{"hostname":"{{host}}"} }"""
        ).RootElement.Clone();

    [Fact]
    public void ClosingWaitingSessionRemovesIt()
    {
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));   // → waiting
        Assert.Equal(1, store.GetStatus().SessionCount);

        store.CloseSession("test-host", "a");

        Assert.Equal(0, store.GetStatus().SessionCount);
    }

    [Fact]
    public void ClosingIdleSessionRemovesIt()
    {
        var store = new EventStore();
        store.Add(Ev("SessionStart", "a"));   // → idle
        Assert.Equal(1, store.GetStatus().SessionCount);

        store.CloseSession("test-host", "a");

        Assert.Equal(0, store.GetStatus().SessionCount);
    }

    [Fact]
    public void ClosingErrorSessionRemovesIt()
    {
        var store = new EventStore();
        store.Add(Ev("StopFailure", "a"));   // → error
        Assert.Equal(1, store.GetStatus().SessionCount);

        store.CloseSession("test-host", "a");

        Assert.Equal(0, store.GetStatus().SessionCount);
    }

    [Fact]
    public void ClosingWorkingSessionIsANoOp()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));   // → working

        store.CloseSession("test-host", "a");

        var status = store.GetStatus();
        Assert.Equal(1, status.SessionCount);
        Assert.Equal("working", status.Sessions.Single().Status);
    }

    [Fact]
    public void ClosingDoneSessionIsANoOp()
    {
        var store = new EventStore();
        store.Add(Ev("Stop", "a"));   // → done

        store.CloseSession("test-host", "a");

        var status = store.GetStatus();
        Assert.Equal(1, status.SessionCount);
        Assert.Equal("done", status.Sessions.Single().Status);
    }

    [Fact]
    public void ClosingUnknownSessionIsAHarmlessNoOp()
    {
        var store = new EventStore();

        var global = store.CloseSession("nobody-host", "nobody-session");

        Assert.Equal(0, global.SessionCount);
    }

    [Fact]
    public void ClosingBroadcastsStatusToSubscribers()
    {
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));   // → waiting

        var (channel, id) = store.Subscribe();
        store.CloseSession("test-host", "a");
        store.Unsubscribe(id);

        var sawEmptied = false;
        while (channel.Reader.TryRead(out var msg))
            if (msg is { Kind: "status", Data: GlobalStatus g } && g.SessionCount == 0)
                sawEmptied = true;
        Assert.True(sawEmptied);
    }

    [Fact]
    public void ClosingWorkingSessionDoesNotBroadcast()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));   // → working

        var (channel, id) = store.Subscribe();
        store.CloseSession("test-host", "a");
        store.Unsubscribe(id);

        var sawAnyStatus = false;
        while (channel.Reader.TryRead(out var msg))
            if (msg.Kind == "status") sawAnyStatus = true;
        Assert.False(sawAnyStatus);
    }
}
