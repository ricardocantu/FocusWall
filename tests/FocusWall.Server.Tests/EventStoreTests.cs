using System.Text.Json;
using FocusWall.Server;
using System.Linq;

public class EventStoreTests
{
    private static JsonElement Ev(string name, string sessionId, string host = "test-host") =>
        JsonDocument.Parse(
            $$"""{"hook_event_name":"{{name}}","session_id":"{{sessionId}}","_meta":{"hostname":"{{host}}"} }"""
        ).RootElement.Clone();

    [Fact]
    public void WaitingWinsOverWorking()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("Notification", "b"));
        Assert.Equal("waiting", store.GetStatus().Value);
    }

    [Fact]
    public void WaitingHoldsWhileOtherSessionKeepsWorking()
    {
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));
        for (var i = 0; i < 5; i++) store.Add(Ev("PostToolUse", "b"));

        var status = store.GetStatus();
        Assert.Equal("waiting", status.Value);
        Assert.Equal(1, status.WaitingCount);
    }

    [Fact]
    public void SessionEndRemovesSession()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("SessionEnd", "a"));

        var status = store.GetStatus();
        Assert.Equal("idle", status.Value);
        Assert.Equal(0, status.SessionCount);
    }

    [Fact]
    public void SessionStartShowsIdleNotWorking()
    {
        // A freshly started session — or the fresh conversation after /clear
        // (SessionEnd then SessionStart) — is present but idle until the first
        // prompt. It must not show as "working" with nothing running.
        var store = new EventStore();
        store.Add(Ev("SessionStart", "a"));

        var status = store.GetStatus();
        Assert.Equal(1, status.SessionCount);
        Assert.Equal("idle", status.Sessions.Single().Status);

        store.Add(Ev("UserPromptSubmit", "a"));   // first prompt → working
        Assert.Equal("working", store.GetStatus().Sessions.Single().Status);
    }

    [Fact]
    public void ClearLeavesSessionIdleNotWorking()
    {
        // /clear fires SessionEnd (removes the session) immediately followed by
        // SessionStart (fresh conversation). The card must come back as idle,
        // not resurrect as a phantom "working" card.
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));         // working
        store.Add(Ev("SessionEnd", "a"));         // /clear: end
        store.Add(Ev("SessionStart", "a"));       // /clear: fresh start

        var status = store.GetStatus();
        Assert.Equal(1, status.SessionCount);
        Assert.Equal("idle", status.Sessions.Single().Status);
    }

    [Fact]
    public void SecondSessionEnteringWaitingStillBroadcasts()
    {
        // Regression guard: the global status stays "waiting" and the session
        // count doesn't change, but subscribers must still hear about it —
        // otherwise the notifiers never announce the second session and the
        // hero subtitle names the wrong one.
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("PreToolUse", "b"));
        store.Add(Ev("Notification", "a"));

        var (channel, id) = store.Subscribe();
        store.Add(Ev("Notification", "b"));
        store.Unsubscribe(id);

        var sawBothWaiting = false;
        while (channel.Reader.TryRead(out var msg))
            if (msg is { Kind: "status", Data: GlobalStatus g } && g.WaitingCount == 2)
                sawBothWaiting = true;
        Assert.True(sawBothWaiting);
    }

    [Fact]
    public void StartedAtSurvivesStatusTransition()
    {
        var store = new EventStore();
        store.Add(Ev("UserPromptSubmit", "a"));
        var started = store.GetStatus().Sessions.Single().StartedAt;

        store.Add(Ev("PreToolUse", "a"));    // → working (a transition)
        store.Add(Ev("Notification", "a"));  // → waiting (another transition)

        Assert.Equal(started, store.GetStatus().Sessions.Single().StartedAt);
    }

    [Fact]
    public void StartedAtResetsAfterSessionEnd()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        var first = store.GetStatus().Sessions.Single().StartedAt;

        store.Add(Ev("SessionEnd", "a"));    // removes the session
        store.Add(Ev("PreToolUse", "a"));    // fresh session, same key

        Assert.True(store.GetStatus().Sessions.Single().StartedAt > first);
    }

    [Fact]
    public void BranchFromMetaSurfacesOnSession()
    {
        var store = new EventStore();
        store.Add(JsonDocument.Parse(
            """{"hook_event_name":"PreToolUse","session_id":"a","_meta":{"hostname":"h","branch":"feature/x"}}"""
        ).RootElement.Clone());

        Assert.Equal("feature/x", store.GetStatus().Sessions.Single().Branch);
    }

    [Fact]
    public void BranchIsNullWhenAbsent()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));    // Ev sets _meta.hostname only
        Assert.Null(store.GetStatus().Sessions.Single().Branch);
    }

    [Fact]
    public void WindowsCwdShowsOnlyLastSegment()
    {
        // Regression guard: the server runs in a Linux container, where
        // System.IO.Path treats '\' as an ordinary character. A backslash path
        // must still collapse to its last segment, not show the full path.
        var store = new EventStore();
        store.Add(JsonDocument.Parse(
            """{"hook_event_name":"PreToolUse","session_id":"a","_meta":{"hostname":"h","cwd":"C:\\Users\\you\\projects\\FocusWall"}}"""
        ).RootElement.Clone());

        Assert.Equal("FocusWall", store.GetStatus().Sessions.Single().Cwd);
    }

    [Fact]
    public void PosixCwdShowsOnlyLastSegment()
    {
        var store = new EventStore();
        store.Add(JsonDocument.Parse(
            """{"hook_event_name":"PreToolUse","session_id":"a","_meta":{"hostname":"h","cwd":"/home/you/projects/my-project"}}"""
        ).RootElement.Clone());

        Assert.Equal("my-project", store.GetStatus().Sessions.Single().Cwd);
    }

    [Fact]
    public void StopFailureEntersErrorStatus()
    {
        var store = new EventStore();
        store.Add(Ev("PreToolUse", "a"));
        store.Add(Ev("StopFailure", "a"));

        Assert.Equal("error", store.GetStatus().Sessions.Single().Status);
    }

    [Fact]
    public void ErrorOutranksWaiting()
    {
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));   // waiting
        store.Add(Ev("StopFailure", "b"));    // error

        var status = store.GetStatus();
        Assert.Equal("error", status.Value);
        Assert.Equal(1, status.ErrorCount);
    }

    [Fact]
    public void ErrorOutranksWaitingAndWorkingTogether()
    {
        var store = new EventStore();
        store.Add(Ev("Notification", "a"));   // waiting
        store.Add(Ev("PreToolUse", "b"));     // working
        store.Add(Ev("StopFailure", "c"));    // error

        var status = store.GetStatus();
        Assert.Equal("error", status.Value);
        Assert.Equal(1, status.ErrorCount);
        Assert.Equal(1, status.WaitingCount);
        Assert.Equal(1, status.WorkingCount);
    }

    [Fact]
    public void ErrorClearsOnNextRealEvent()
    {
        var store = new EventStore();
        store.Add(Ev("StopFailure", "a"));
        Assert.Equal("error", store.GetStatus().Sessions.Single().Status);

        store.Add(Ev("UserPromptSubmit", "a"));   // retried -> back to working
        Assert.Equal("working", store.GetStatus().Sessions.Single().Status);
    }

    [Fact]
    public void ErrorReasonSurfacesOnLastEvent()
    {
        // Mirrors the "waiting" precedent: the frontend reads the reason
        // straight off LastEvent.payload.error, no dedicated SessionState field.
        var store = new EventStore();
        store.Add(JsonDocument.Parse(
            """{"hook_event_name":"StopFailure","session_id":"a","error":"rate_limit","_meta":{"hostname":"h"}}"""
        ).RootElement.Clone());

        var session = store.GetStatus().Sessions.Single();
        Assert.Equal("error", session.Status);
        Assert.Equal("rate_limit", session.LastEvent!.Payload.GetProperty("error").GetString());
    }
}
