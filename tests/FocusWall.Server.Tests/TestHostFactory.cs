using FocusWall.Server;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

// In-process host for endpoint tests. Strips the production background
// services so a test never polls RSS/Slack/calendar feeds, never fires a
// notifier, and never starts the heartbeat timer.
public sealed class TestHostFactory : WebApplicationFactory<Program>
{
    private static readonly HashSet<Type> ProductionHostedServiceTypes =
    [
        typeof(HeartbeatService),
        typeof(RssService),
        typeof(SlackService),
        typeof(CalendarService),
        typeof(DiscordNotifier),
        typeof(EchoAnnouncer)
    ];

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        // No file watcher on the optional appsettings.*.local.json inside tests.
        builder.UseSetting("hostBuilder:reloadConfigOnChange", "false");
        builder.ConfigureTestServices(services =>
        {
            var production = services
                .Where(d => d.ServiceType == typeof(IHostedService)
                            && d.ImplementationType is not null
                            && ProductionHostedServiceTypes.Contains(d.ImplementationType))
                .ToArray();
            foreach (var d in production) services.Remove(d);
        });
    }
}
