namespace FocusWall.Server;

// One configured workspace. Bound from Slack:Workspaces (appsettings) or the
// Slack__Workspaces__N__* env vars injected at deploy time. Token is the xoxc
// session token; Cookie is the `d` cookie value.
public record SlackWorkspace
{
    public string Label { get; init; } = "";
    public string Token { get; init; } = "";
    public string Cookie { get; init; } = "";
}

// Latest reduced summary for one workspace. Serializes as camelCase from
// GET /slack/state. Presence/status come from best-effort follow-up calls;
// they stay null when those calls fail, and the category counts still render.
public record SlackWorkspaceState(
    string Label, int Mentions, bool AnyUnread,
    int ChannelsUnread, int DmsUnread, int ThreadsUnread,
    int ChannelMentions, int DmMentions,
    string? Presence, string? StatusText, string? StatusEmoji,
    string? Error, DateTimeOffset UpdatedAt);

// Thread-safe holder; the service swaps the whole list at once (reference
// assignment is atomic), so readers always see a consistent snapshot. Mirrors
// RssCache.
public class SlackCache
{
    public IReadOnlyList<SlackWorkspaceState> Workspaces { get; set; } = Array.Empty<SlackWorkspaceState>();
}

// Polls Slack's internal client.counts per workspace on a timer, reduces each
// response, and updates the cache. Mirrors RssService's PeriodicTimer shape.
// Self-disables when no workspace has a token+cookie.
public class SlackService(
    SlackCache cache,
    IConfiguration config,
    IHttpClientFactory httpFactory,
    ILogger<SlackService> log) : BackgroundService
{
    // Auth-ish Slack error strings → the "re-grab your token" panel state.
    private static readonly HashSet<string> AuthErrors =
        new(StringComparer.Ordinal) { "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive" };

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var workspaces = (config.GetSection("Slack:Workspaces").Get<SlackWorkspace[]>() ?? Array.Empty<SlackWorkspace>())
            .Where(w => !string.IsNullOrEmpty(w.Token) && !string.IsNullOrEmpty(w.Cookie))
            .ToArray();

        if (workspaces.Length == 0)
        {
            log.LogInformation("SlackService disabled — no Slack:Workspaces configured");
            return;
        }

        var refreshSec = Math.Max(15, config.GetValue("Slack:RefreshSeconds", 60));
        var http = httpFactory.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(5);

        log.LogInformation("SlackService polling {Count} workspace(s) every {Sec}s", workspaces.Length, refreshSec);

        await Refresh(workspaces, http, ct);   // immediate first load

        var timer = new PeriodicTimer(TimeSpan.FromSeconds(refreshSec));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                await Refresh(workspaces, http, ct);
        }
        catch (OperationCanceledException) { }
    }

    private async Task Refresh(SlackWorkspace[] workspaces, HttpClient http, CancellationToken ct)
    {
        var states = new List<SlackWorkspaceState>(workspaces.Length);
        foreach (var ws in workspaces)
            states.Add(await FetchOne(ws, http, ct));
        cache.Workspaces = states;
    }

    // One authenticated POST to a Slack internal API method. Token goes in the
    // form body, the `d` cookie in the header — exactly as the web client does.
    private static async Task<string> PostSlack(HttpClient http, string method, SlackWorkspace ws, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, $"https://slack.com/api/{method}");
        req.Content = new FormUrlEncodedContent(new Dictionary<string, string> { ["token"] = ws.Token });
        req.Headers.TryAddWithoutValidation("Cookie", $"d={ws.Cookie}");
        using var res = await http.SendAsync(req, ct);
        res.EnsureSuccessStatusCode();
        return await res.Content.ReadAsStringAsync(ct);
    }

    private async Task<SlackWorkspaceState> FetchOne(SlackWorkspace ws, HttpClient http, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        try
        {
            var json = await PostSlack(http, "client.counts", ws, ct);
            var counts = SlackCounts.Reduce(json);

            // Best-effort presence + custom status: a failure here must NOT drop
            // the counts we already have, so each is guarded independently. Real
            // cancellation still propagates (guarded on ct).
            string? presence = null, statusText = null, statusEmoji = null;
            try { presence = SlackProfile.ParsePresence(await PostSlack(http, "users.getPresence", ws, ct)); }
            catch (Exception) when (!ct.IsCancellationRequested) { }
            try { (statusText, statusEmoji) = SlackProfile.ParseStatus(await PostSlack(http, "users.profile.get", ws, ct)); }
            catch (Exception) when (!ct.IsCancellationRequested) { }

            return new SlackWorkspaceState(
                ws.Label, counts.Mentions, counts.AnyUnread,
                counts.ChannelsUnread, counts.DmsUnread, counts.ThreadsUnread,
                counts.ChannelMentions, counts.DmMentions,
                presence, statusText, statusEmoji, null, now);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (SlackApiException ex)
        {
            var marker = AuthErrors.Contains(ex.SlackError) ? "auth_expired" : "fetch_failed";
            log.LogWarning("Slack workspace {Label}: {Marker} ({Error})", ws.Label, marker, ex.SlackError);
            return new SlackWorkspaceState(ws.Label, 0, false, 0, 0, 0, 0, 0, null, null, null, marker, now);
        }
        catch (Exception ex)
        {
            log.LogWarning("Slack workspace {Label}: fetch_failed ({Message})", ws.Label, ex.Message);
            return new SlackWorkspaceState(ws.Label, 0, false, 0, 0, 0, 0, 0, null, null, null, "fetch_failed", now);
        }
    }
}
