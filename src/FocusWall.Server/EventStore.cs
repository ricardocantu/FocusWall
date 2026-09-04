namespace FocusWall.Server;

using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;

public record SessionKey(string Hostname, string SessionId)
{
    public string Short => $"{Hostname}/{(SessionId.Length > 4 ? SessionId[^4..] : SessionId)}";
    public static SessionKey Unknown => new("unknown", "unknown");
}

public record EventEntry(
    string Id,
    DateTimeOffset ReceivedAt,
    SessionKey SessionKey,
    JsonElement Payload);

public record SessionState(
    SessionKey Key,
    string Status,
    DateTimeOffset StatusSince,
    DateTimeOffset StartedAt,
    DateTimeOffset LastEventAt,
    string? Cwd,
    string? Branch,
    EventEntry? LastEvent);

public record GlobalStatus(
    string Value,                 // loudest across sessions
    DateTimeOffset Since,
    int SessionCount,
    int WaitingCount,
    int WorkingCount,
    int ErrorCount,
    List<SessionState> Sessions,
    // When non-null and in the future, the wall is snoozed: the client renders
    // "Snoozed (Nm left)" instead of the waiting pulse and the notifiers stay
    // quiet. Per-session Status values stay honest — snooze is an overlay, not
    // a state-machine transition (the core invariant: status is derived from
    // events, never overridden).
    DateTimeOffset? SnoozedUntil = null);

public record StreamMessage(string Kind, object Data);

public class EventStore
{
    private const int MaxEvents = 200;
    private static readonly TimeSpan DoneAgesToIdleAfter = TimeSpan.FromSeconds(30);
    // Long enough that a silent long-running tool call (test suite, build)
    // doesn't flap the hero; short enough that a killed terminal that never
    // sent SessionEnd doesn't show "Working" for hours.
    private static readonly TimeSpan WorkingAgesToIdleAfter = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan SessionPruneAfter  = TimeSpan.FromHours(2);

    // Priority — higher number is louder in the "who wins the hero" contest
    private static readonly Dictionary<string, int> _priority = new()
    {
        ["error"]   = 5,
        ["waiting"] = 4,
        ["working"] = 3,
        ["done"]    = 2,
        ["idle"]    = 1
    };

    private readonly LinkedList<EventEntry> _events = new();
    private readonly Dictionary<SessionKey, SessionState> _sessions = new();
    private readonly object _lock = new();
    private readonly ConcurrentDictionary<Guid, Channel<StreamMessage>> _subs = new();

    // Signature of every session's status. Broadcast when *any* session
    // transitions — coalescing on the global loudest value alone would
    // swallow e.g. a second session entering "waiting" while another is
    // already waiting (the notifiers would never hear about it, and the
    // hero subtitle would name the wrong session).
    private string _lastBroadcastSignature = "";

    // Global snooze overlay — user action via POST /snooze, not derived from
    // events. Null (or in the past) means not snoozed.
    private DateTimeOffset? _snoozedUntil;

    // Snooze (or clear) the wall. minutes <= 0 clears. Broadcasts a fresh status
    // immediately so every connected view + the notifiers react at once, rather
    // than waiting for the next event or heartbeat.
    public GlobalStatus Snooze(int minutes)
    {
        // Clamp to a sane range: <=0 clears, cap at 24h so a bogus LAN request
        // (?minutes=999999999) can't overflow AddMinutes into a 500.
        minutes = Math.Clamp(minutes, 0, 24 * 60);
        GlobalStatus global;
        lock (_lock)
        {
            _snoozedUntil = minutes > 0 ? DateTimeOffset.UtcNow.AddMinutes(minutes) : null;
            global = ComputeGlobalStatusLocked();
            // Refresh the signature so the natural expiry (snooze active → past)
            // still triggers a heartbeat rebroadcast; the user-action broadcast
            // below covers the set/clear itself.
            _lastBroadcastSignature = ComputeSignatureLocked();
        }
        Broadcast(new StreamMessage("status", global));
        return global;
    }

    // Manually dismiss a single idle/waiting/error session — e.g. a stale
    // "waiting" card nobody's coming back to. Removes it from the shared
    // EventStore, so it disappears from every view (grid/hero/wall/mobile)
    // at once, not just the client that closed it. If that session sends
    // another event later, it just reappears fresh, the same as any pruned
    // session would. Ineligible statuses (working, done) and unknown keys
    // are a harmless no-op — no state change, no broadcast.
    public GlobalStatus CloseSession(string hostname, string sessionId)
    {
        var key = new SessionKey(hostname, sessionId);
        GlobalStatus global;
        bool removed;
        lock (_lock)
        {
            removed = _sessions.TryGetValue(key, out var existing)
                && existing.Status is "idle" or "waiting" or "error"
                && _sessions.Remove(key);

            global = ComputeGlobalStatusLocked();
            if (removed) _lastBroadcastSignature = ComputeSignatureLocked();
        }
        if (removed) Broadcast(new StreamMessage("status", global));
        return global;
    }

    public EventEntry Add(JsonElement payload)
    {
        var key = ExtractSessionKey(payload);
        var eventName = payload.TryGetProperty("hook_event_name", out var n) ? n.GetString() : null;
        var cwd = ExtractCwd(payload);
        var branch = ExtractBranch(payload);

        var entry = new EventEntry(
            Id: Guid.NewGuid().ToString("N")[..12],
            ReceivedAt: DateTimeOffset.UtcNow,
            SessionKey: key,
            Payload: payload);

        GlobalStatus globalAfter;
        bool shouldBroadcastStatus;

        lock (_lock)
        {
            _events.AddFirst(entry);
            while (_events.Count > MaxEvents) _events.RemoveLast();

            var previousStatus = _sessions.TryGetValue(key, out var existing) ? existing.Status : "idle";
            var newStatus = DeriveSessionStatus(eventName, previousStatus);

            if (eventName == "SessionEnd")
            {
                _sessions.Remove(key);
            }
            else
            {
                _sessions[key] = new SessionState(
                    Key: key,
                    Status: newStatus,
                    StatusSince: newStatus != previousStatus ? entry.ReceivedAt : (existing?.StatusSince ?? entry.ReceivedAt),
                    StartedAt: existing?.StartedAt ?? entry.ReceivedAt,
                    LastEventAt: entry.ReceivedAt,
                    Cwd: cwd ?? existing?.Cwd,
                    Branch: branch ?? existing?.Branch,
                    LastEvent: entry);
            }

            globalAfter = ComputeGlobalStatusLocked();
            var signature = ComputeSignatureLocked();
            shouldBroadcastStatus = signature != _lastBroadcastSignature;
            _lastBroadcastSignature = signature;
        }

        Broadcast(new StreamMessage("event", entry));
        if (shouldBroadcastStatus)
            Broadcast(new StreamMessage("status", globalAfter));

        return entry;
    }

    private static string DeriveSessionStatus(string? eventName, string current) => eventName switch
    {
        "Notification"     => "waiting",
        "StopFailure"      => "error",
        "Stop"             => "done",
        "PreToolUse"       => "working",
        "PostToolUse"      => "working",
        "UserPromptSubmit" => "working",
        // SessionStart means the session exists but nothing is running yet —
        // a freshly opened terminal, or the fresh conversation after /clear
        // (which fires SessionEnd then SessionStart). Idle, not working: work
        // begins at the first UserPromptSubmit. Keeps a cleared session on the
        // wall as Idle instead of resurrecting it as a phantom "Working" card.
        "SessionStart"     => "idle",
        "SessionEnd"       => "idle",
        _ => current
    };

    private static SessionKey ExtractSessionKey(JsonElement payload)
    {
        var hostname = "unknown";
        if (payload.TryGetProperty("_meta", out var meta) &&
            meta.TryGetProperty("hostname", out var h) &&
            h.ValueKind == JsonValueKind.String)
        {
            hostname = h.GetString() ?? "unknown";
        }

        var sessionId = "unknown";
        if (payload.TryGetProperty("session_id", out var s) &&
            s.ValueKind == JsonValueKind.String)
        {
            sessionId = s.GetString() ?? "unknown";
        }

        return new SessionKey(hostname, sessionId);
    }

    private static string? ExtractCwd(JsonElement payload)
    {
        // Prefer the wrapper's _meta.cwd, but fall back to the cwd field
        // Claude Code includes natively in hook payloads — project names
        // keep working even if the wrapper's jq augmentation is unavailable.
        string? full = null;
        if (payload.TryGetProperty("_meta", out var meta) &&
            meta.TryGetProperty("cwd", out var mc) &&
            mc.ValueKind == JsonValueKind.String)
        {
            full = mc.GetString();
        }
        else if (payload.TryGetProperty("cwd", out var pc) &&
                 pc.ValueKind == JsonValueKind.String)
        {
            full = pc.GetString();
        }

        // Show just the last path segment — "my-project" not the whole path.
        // Split on both separators explicitly: the server runs in a Linux container,
        // so System.IO.Path uses POSIX rules and would NOT treat '\' as a separator,
        // leaving Windows paths ("C:\Users\...\FocusWall") shown in full.
        if (full is null) return null;
        var trimmed = full.TrimEnd('/', '\\');
        var lastSep = trimmed.LastIndexOfAny(new[] { '/', '\\' });
        return lastSep >= 0 ? trimmed[(lastSep + 1)..] : trimmed;
    }

    private static string? ExtractBranch(JsonElement payload)
    {
        // Branch only comes from the wrapper's _meta — Claude Code doesn't emit
        // it natively, so there's no payload fallback like cwd has.
        if (payload.TryGetProperty("_meta", out var meta) &&
            meta.TryGetProperty("branch", out var b) &&
            b.ValueKind == JsonValueKind.String)
        {
            var s = b.GetString();
            return string.IsNullOrEmpty(s) ? null : s;
        }
        return null;
    }

    private GlobalStatus ComputeGlobalStatusLocked()
    {
        var now = DateTimeOffset.UtcNow;

        // Age out done → idle, and prune long-abandoned sessions
        var toPrune = new List<SessionKey>();
        var keys = _sessions.Keys.ToList();
        foreach (var k in keys)
        {
            var s = _sessions[k];
            if (now - s.LastEventAt > SessionPruneAfter) { toPrune.Add(k); continue; }
            if (s.Status == "done" && now - s.LastEventAt > DoneAgesToIdleAfter)
                _sessions[k] = s with { Status = "idle", StatusSince = now };
            else if (s.Status == "working" && now - s.LastEventAt > WorkingAgesToIdleAfter)
                _sessions[k] = s with { Status = "idle", StatusSince = now };
            // "waiting" never decays — Claude stays blocked until you act.
        }
        foreach (var k in toPrune) _sessions.Remove(k);

        var snoozedUntil = _snoozedUntil > now ? _snoozedUntil : null;

        var active = _sessions.Values.ToList();
        if (active.Count == 0)
            return new GlobalStatus("idle", now, 0, 0, 0, 0, new(), snoozedUntil);

        var loudest = active.MaxBy(s => _priority[s.Status])!;
        var loudestSince = active
            .Where(s => s.Status == loudest.Status)
            .Min(s => s.StatusSince);

        return new GlobalStatus(
            Value: loudest.Status,
            Since: loudestSince,
            SessionCount: active.Count,
            WaitingCount: active.Count(s => s.Status == "waiting"),
            WorkingCount: active.Count(s => s.Status == "working"),
            ErrorCount: active.Count(s => s.Status == "error"),
            Sessions: active.OrderByDescending(s => _priority[s.Status]).ToList(),
            SnoozedUntil: snoozedUntil);
    }

    private string ComputeSignatureLocked() =>
        // Include whether snooze is currently active so its expiry flips the
        // signature and a heartbeat rebroadcasts the un-snoozed status.
        string.Join("|", _sessions
            .OrderBy(kv => kv.Key.Hostname).ThenBy(kv => kv.Key.SessionId)
            .Select(kv => $"{kv.Key.Hostname}/{kv.Key.SessionId}={kv.Value.Status}"))
        + $"|snooze={_snoozedUntil > DateTimeOffset.UtcNow}";

    public IReadOnlyList<EventEntry> Snapshot()
    {
        lock (_lock) return _events.ToList();
    }

    public GlobalStatus GetStatus()
    {
        lock (_lock) return ComputeGlobalStatusLocked();
    }

    public (Channel<StreamMessage> channel, Guid id) Subscribe()
    {
        var ch = Channel.CreateBounded<StreamMessage>(new BoundedChannelOptions(200)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false
        });
        var id = Guid.NewGuid();
        _subs[id] = ch;
        return (ch, id);
    }

    public void Unsubscribe(Guid id)
    {
        if (_subs.TryRemove(id, out var ch)) ch.Writer.TryComplete();
    }

    public void Heartbeat()
    {
        GlobalStatus globalAfter;
        bool shouldBroadcastStatus;
        lock (_lock)
        {
            globalAfter = ComputeGlobalStatusLocked();
            var signature = ComputeSignatureLocked();
            shouldBroadcastStatus = signature != _lastBroadcastSignature;
            _lastBroadcastSignature = signature;
        }

        Broadcast(new StreamMessage("heartbeat", new { t = DateTimeOffset.UtcNow }));
        if (shouldBroadcastStatus)
            Broadcast(new StreamMessage("status", globalAfter));
    }

    private void Broadcast(StreamMessage msg)
    {
        foreach (var ch in _subs.Values) ch.Writer.TryWrite(msg);
    }
}
