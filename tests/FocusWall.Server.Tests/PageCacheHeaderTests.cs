using System.Net;

// The kiosk views must never be cached: the wall's Chromium once heuristically
// cached /hero (served with Last-Modified but no Cache-Control) and kept
// rendering a stale DOM against fresh no-store JS, breaking the hero card.
// Static files get no-store from UseStaticFiles; the extensionless page routes
// are MapGet + Results.File and must set the header themselves.
public sealed class PageCacheHeaderTests : IDisposable
{
    private readonly TestHostFactory _app = new();
    private readonly HttpClient _client;

    public PageCacheHeaderTests() { _client = _app.CreateClient(); }

    public void Dispose()
    {
        _client.Dispose();
        _app.Dispose();
    }

    [Theory]
    [InlineData("/")]
    [InlineData("/hero")]
    [InlineData("/wall")]
    [InlineData("/mobile")]
    [InlineData("/usage")]
    public async Task PageRoutesAreServedWithNoStore(string path)
    {
        using var response = await _client.GetAsync(path);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True(response.Headers.CacheControl?.NoStore,
            $"{path} must send Cache-Control: no-store");
    }
}
