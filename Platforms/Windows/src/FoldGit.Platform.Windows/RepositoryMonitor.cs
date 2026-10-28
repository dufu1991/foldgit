using System.Threading.Channels;
using FoldGit.Core.Git;

namespace FoldGit.Platform.Windows;

public sealed class RepositoryMonitor : IAsyncDisposable
{
    private readonly List<FileSystemWatcher> watchers = [];
    private readonly Channel<bool> changes = Channel.CreateBounded<bool>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task pump;

    private RepositoryMonitor(string[] roots, Func<Task> refresh, Action<Exception> failure)
    {
        foreach (var root in roots.DistinctBy(WindowsPathIdentity.Get))
        {
            var watcher = new FileSystemWatcher(root)
            {
                IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite,
                InternalBufferSize = 64 * 1024
            };
            FileSystemEventHandler changed = (_, _) => changes.Writer.TryWrite(true);
            watcher.Changed += changed; watcher.Created += changed; watcher.Deleted += changed;
            watcher.Renamed += (_, _) => changes.Writer.TryWrite(true);
            watcher.Error += (_, _) => changes.Writer.TryWrite(true);
            watcher.EnableRaisingEvents = true;
            watchers.Add(watcher);
        }
        pump = PumpAsync(refresh, failure);
    }
    public static async Task<RepositoryMonitor> CreateAsync(GitProcess git, string directory, Func<Task> refresh, Action<Exception> failure)
    {
        var locations = await git.ExecuteAsync(directory, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"]);
        return new([directory, .. locations.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)], refresh, failure);
    }
    private async Task PumpAsync(Func<Task> refresh, Action<Exception> failure)
    {
        try
        {
            await foreach (var notification in changes.Reader.ReadAllAsync(lifetime.Token))
            {
                await Task.Delay(500, lifetime.Token);
                while (changes.Reader.TryRead(out _)) { }
                try { await refresh(); }
                catch (Exception error) { failure(error); }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    public async ValueTask DisposeAsync()
    {
        foreach (var watcher in watchers) watcher.Dispose();
        await lifetime.CancelAsync();
        await pump;
        lifetime.Dispose();
    }
}
