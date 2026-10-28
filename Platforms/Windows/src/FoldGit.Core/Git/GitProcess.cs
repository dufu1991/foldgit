using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

namespace FoldGit.Core.Git;

public sealed class GitException(string message, int? exitCode = null) : Exception(message)
{
    public int? ExitCode { get; } = exitCode;
}

public sealed record GitOutput(byte[] Bytes, string Error, int ExitCode)
{
    public string Text => new UTF8Encoding(false, true).GetString(Bytes);
}

public sealed class GitProcess(string executable, Func<string, string>? identity = null)
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Lanes = new(StringComparer.Ordinal);
    private readonly Func<string, string> identity = identity ?? Path.GetFullPath;
    public string Executable { get; } = executable;
    public string Identity(string path) => identity(path);

    public async Task<T> InRepositoryAsync<T>(string directory, Func<GitSession, Task<T>> operation,
        CancellationToken cancellationToken = default)
    {
        var location = await ExecuteAsync(directory, ["rev-parse", "--path-format=absolute", "--git-common-dir"], cancellationToken: cancellationToken);
        var key = identity(location.Text.TrimEnd('\r', '\n'));
        var lane = Lanes.GetOrAdd(key, _ => new(1, 1));
        await lane.WaitAsync(cancellationToken);
        try { return await operation(new(this, directory, cancellationToken)); }
        finally { lane.Release(); }
    }

    public async Task<GitOutput> ExecuteAsync(string directory, IReadOnlyList<string> arguments,
        byte[]? input = null, bool background = false, CancellationToken cancellationToken = default,
        int[]? acceptedExitCodes = null, TimeSpan? timeout = null)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout ?? TimeSpan.FromMinutes(10));
        GitException? limitFailure = null;
        var start = new ProcessStartInfo(Executable)
        {
            WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["LC_ALL"] = "C.UTF-8";
        start.Environment["GIT_PAGER"] = "cat";
        start.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        start.Environment["GIT_TERMINAL_PROMPT"] = "0";
        if (background)
        {
            start.Environment["GCM_INTERACTIVE"] = "never";
            start.Environment["SSH_ASKPASS_REQUIRE"] = "never";
        }
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new GitException("Git could not be started.");
        using var registration = deadline.Token.Register(() =>
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        });
        try
        {
            void LimitReached()
            {
                Interlocked.CompareExchange(ref limitFailure, new GitException("Git output exceeded the configured size limit."), null);
                deadline.Cancel();
            }
            var output = ReadAsync(process.StandardOutput.BaseStream, 64 * 1024 * 1024, deadline.Token, LimitReached);
            var error = ReadAsync(process.StandardError.BaseStream, 4 * 1024 * 1024, deadline.Token, LimitReached);
            var write = WriteAsync(process.StandardInput.BaseStream, input, deadline.Token);
            await Task.WhenAll(output, error, write, process.WaitForExitAsync(deadline.Token));
            var result = new GitOutput(await output, new UTF8Encoding(false, true).GetString(await error), process.ExitCode);
            if (!(acceptedExitCodes ?? [0]).Contains(result.ExitCode))
                throw new GitException(result.Error, result.ExitCode);
            return result;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw limitFailure ?? new GitException("The Git operation timed out.");
        }
        finally
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
        }
    }

    private static async Task<byte[]> ReadAsync(Stream stream, int limit, CancellationToken cancellationToken, Action limitReached)
    {
        using var result = new MemoryStream();
        var buffer = new byte[32 * 1024];
        int count;
        while ((count = await stream.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (result.Length + count > limit)
            {
                limitReached();
                throw new GitException("Git output exceeded the configured size limit.");
            }
            result.Write(buffer, 0, count);
        }
        return result.ToArray();
    }

    private static async Task WriteAsync(Stream stream, byte[]? input, CancellationToken cancellationToken)
    {
        await using (stream)
            if (input is not null) await stream.WriteAsync(input, cancellationToken);
    }
}

public sealed class GitSession(GitProcess process, string directory, CancellationToken cancellationToken)
{
    public string Directory { get; } = directory;
    public Task<GitOutput> RunAsync(IReadOnlyList<string> arguments, byte[]? input = null,
        bool background = false, int[]? acceptedExitCodes = null) =>
        process.ExecuteAsync(Directory, arguments, input, background, cancellationToken, acceptedExitCodes);
    public async Task<string> TextAsync(params string[] arguments) => (await RunAsync(arguments)).Text;
}
