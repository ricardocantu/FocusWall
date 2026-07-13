namespace FocusWall.Server;

public class HeartbeatService(EventStore store) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                store.Heartbeat();
        }
        catch (OperationCanceledException) { }
    }
}
