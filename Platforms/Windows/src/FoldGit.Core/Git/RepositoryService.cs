using System.Collections.Concurrent;
using System.Text;

namespace FoldGit.Core.Git;

public sealed class RepositoryService(GitProcess process)
{
    private readonly ConcurrentDictionary<string, Lazy<Task>> fetches = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, (string Head, Commit[] Commits)> searchIndexes = new(StringComparer.Ordinal);
    private static readonly string[] DiffArguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--full-index", "--binary", "--find-renames", "--src-prefix=a/", "--dst-prefix=b/"];
    public GitProcess Process => process;

    public Task<RepositorySnapshot> SnapshotAsync(string directory, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var branch = await session.RunAsync(["symbolic-ref", "--quiet", "--short", "HEAD"], acceptedExitCodes: [0, 1]);
            var head = await session.RunAsync(["rev-parse", "--verify", "--quiet", "HEAD"], acceptedExitCodes: [0, 1]);
            var files = GitRecords.Status(await session.TextAsync("status", "--porcelain=v2", "-z", "--untracked-files=all"));
            var staged = Diff.Parse(await session.TextAsync([.. DiffArguments, "--cached"]));
            var unstaged = Diff.Parse(await session.TextAsync(DiffArguments));
            var branches = await BranchesAsync(session);
            var tags = SplitLines(await session.TextAsync("tag", "--list", "--sort=-creatordate"));
            var remotes = SplitLines(await session.TextAsync("remote"));
            var stashFields = (await session.TextAsync("stash", "list", "--format=%gd%x00%H%x00%gs%x00")).Split('\0');
            var stashes = new List<Stash>();
            for (var i = 0; i + 2 < stashFields.Length; i += 3)
                stashes.Add(new(stashFields[i].TrimStart('\r', '\n'), stashFields[i + 1], stashFields[i + 2]));
            var currentBranch = branches.FirstOrDefault(value => value.Current);
            var ahead = 0; var behind = 0;
            if (currentBranch is not null && currentBranch.Upstream.Length > 0)
            {
                var counts = (await session.TextAsync("rev-list", "--left-right", "--count", "HEAD..." + currentBranch.Upstream)).Trim().Split('\t');
                ahead = int.Parse(counts[0]); behind = int.Parse(counts[1]);
            }
            var gitDirectory = (await session.TextAsync("rev-parse", "--absolute-git-dir")).TrimEnd('\r', '\n');
            var merging = File.Exists(Path.Combine(gitDirectory, "MERGE_HEAD"));
            var message = merging ? await File.ReadAllTextAsync(Path.Combine(gitDirectory, "MERGE_MSG"), cancellationToken) : "";
            return new RepositorySnapshot(branch.Text.TrimEnd('\r', '\n'), head.Text.Trim(), files, staged, unstaged,
                branches, tags, stashes.ToArray(), ahead, behind, merging, message, remotes);
        }, cancellationToken);

    public Task<Commit[]> HistoryAsync(string directory, int skip = 0, int count = 100, string query = "",
        CancellationToken cancellationToken = default) => process.InRepositoryAsync(directory, async session =>
    {
        var head = await session.RunAsync(["rev-parse", "--verify", "--quiet", "HEAD"], acceptedExitCodes: [0, 1]);
        if (head.ExitCode == 1) return [];
        if (query.Length == 0)
            return GitRecords.Commits(await session.TextAsync("log", "--topo-order", "--skip=" + skip,
                "--max-count=" + count, "--format=" + GitRecords.CommitFormat));
        var hash = head.Text.Trim();
        if (!searchIndexes.TryGetValue(directory, out var index) || index.Head != hash)
        {
            index = (hash, GitRecords.Commits(await session.TextAsync("log", "--topo-order", "--format=" + GitRecords.CommitFormat)));
            searchIndexes[directory] = index;
        }
        cancellationToken.ThrowIfCancellationRequested();
        return index.Commits.Where(commit =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            return commit.Author.Contains(query, StringComparison.OrdinalIgnoreCase)
                || commit.Email.Contains(query, StringComparison.OrdinalIgnoreCase)
                || commit.Message.Contains(query, StringComparison.OrdinalIgnoreCase);
        }).Skip(skip).Take(count).ToArray();
    }, cancellationToken);

    public Task<Diff> CommitDiffAsync(string directory, Commit commit, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var hash = await ResolveAsync(session, commit.Hash);
            return Diff.Parse(await session.TextAsync(["show", "--format=", "--first-parent", "--root", .. DiffArguments.Skip(1), hash, "--"]));
        }, cancellationToken);

    public Task<Commit> GetCommitAsync(string directory, string reference, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var hash = await ResolveAsync(session, reference);
            return GitRecords.Commits(await session.TextAsync("log", "--no-walk", "--format=" + GitRecords.CommitFormat, hash)).Single();
        }, cancellationToken);

    public Task<Diff> CompareAsync(string directory, string left, string? right, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var from = await ResolveAsync(session, left);
            var args = new List<string>(DiffArguments) { from };
            if (right is not null) args.Add(await ResolveAsync(session, right));
            args.Add("--");
            return Diff.Parse(await session.TextAsync(args.ToArray()));
        }, cancellationToken);

    public Task StagePathsAsync(string directory, IEnumerable<string> paths, bool stage, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            if (stage) await session.RunAsync(["--literal-pathspecs", "add", "--", .. paths]);
            else
            {
                var head = await session.RunAsync(["rev-parse", "--verify", "--quiet", "HEAD"], acceptedExitCodes: [0, 1]);
                await session.RunAsync(head.ExitCode == 0 ? ["--literal-pathspecs", "restore", "--staged", "--", .. paths]
                    : ["--literal-pathspecs", "rm", "--cached", "-r", "--ignore-unmatch", "--", .. paths]);
            }
            return true;
        }, cancellationToken);

    public Task StageAllAsync(string directory, bool stage, CancellationToken cancellationToken = default) =>
        stage ? ActionAsync(directory, ["add", "--all", "--", "."], cancellationToken) : StagePathsAsync(directory, ["."], false, cancellationToken);

    public Task StageFileAsync(string directory, FileDiff file, bool stage, CancellationToken cancellationToken = default) =>
        StagePathsAsync(directory, new[] { file.OldPath, file.Path }.Where(path => path is not null).Select(path => path!).Distinct(StringComparer.Ordinal), stage, cancellationToken);

    public Task StageHunkAsync(string directory, FileDiff file, DiffHunk hunk, bool stage, CancellationToken cancellationToken = default)
    {
        if (!file.Hunks.Contains(hunk) || file.Binary)
            throw new GitException("Stage this change as a complete file.");
        if (file.Hunks.Length == 1 && (file.Header.Contains("rename from ", StringComparison.Ordinal)
            || file.Header.Contains("new file mode ", StringComparison.Ordinal) || file.Header.Contains("deleted file mode ", StringComparison.Ordinal)))
            return StageFileAsync(directory, file, stage, cancellationToken);
        return process.InRepositoryAsync(directory, async session =>
        {
            await session.RunAsync(["apply", "--cached", "--whitespace=nowarn", .. stage ? Array.Empty<string>() : ["--reverse"]],
                Encoding.UTF8.GetBytes(file.Patch(hunk)));
            return true;
        }, cancellationToken);
    }

    public Task CommitAsync(string directory, string message, bool amend, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            if (string.IsNullOrWhiteSpace(message)) throw new GitException("A commit message is required.");
            await session.RunAsync(["commit", .. amend ? new[] { "--amend" } : [], "--file=-"], Encoding.UTF8.GetBytes(message));
            return true;
        }, cancellationToken);

    public Task CreateBranchAsync(string directory, string name, string start, bool checkout, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            await ValidateBranchAsync(session, name);
            var hash = await ResolveAsync(session, start);
            await session.RunAsync(checkout ? ["switch", "--create", name, hash] : ["branch", name, hash]);
            return true;
        }, cancellationToken);

    public Task SwitchAsync(string directory, string reference, bool detached = false, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            if (detached) await session.RunAsync(["switch", "--detach", await ResolveAsync(session, reference)]);
            else { await ValidateBranchAsync(session, reference); await session.RunAsync(["switch", "--", reference]); }
            return true;
        }, cancellationToken);

    public Task RenameBranchAsync(string directory, string oldName, string newName, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            await ValidateBranchAsync(session, oldName); await ValidateBranchAsync(session, newName);
            await session.RunAsync(["branch", "--move", oldName, newName]); return true;
        }, cancellationToken);

    public Task TrackBranchAsync(string directory, string remoteBranch, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            await RepositoryService.ValidateBranchAsync(session, remoteBranch);
            await session.RunAsync(["switch", "--track", "--", remoteBranch]); return true;
        }, cancellationToken);

    public Task DeleteBranchAsync(string directory, string name, bool remote, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            await ValidateBranchAsync(session, name);
            await session.RunAsync(remote ? ["branch", "--delete", "--remotes", "--", name] : ["branch", "--delete", "--", name]); return true;
        }, cancellationToken);

    public Task TagAsync(string directory, string name, string? target, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            await session.RunAsync(["check-ref-format", "refs/tags/" + name]);
            await session.RunAsync(target is null ? ["tag", "--delete", "--", name] : ["tag", "--", name, await ResolveAsync(session, target)]);
            return true;
        }, cancellationToken);

    public Task RevertAsync(string directory, string revision, int? mainline = null, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            await session.RunAsync(["revert", "--no-edit", .. mainline.HasValue ? new[] { "--mainline", mainline.Value.ToString() } : [], await ResolveAsync(session, revision)]);
            return true;
        }, cancellationToken);

    public async Task FetchAsync(string directory, bool background, CancellationToken cancellationToken = default)
    {
        // Waiters share the fetch, but cancelling one waiter must not cancel other callers.
        var key = (await process.ExecuteAsync(directory, ["rev-parse", "--path-format=absolute", "--git-common-dir"], cancellationToken: cancellationToken)).Text.Trim();
        var task = fetches.GetOrAdd(key, _ => new Lazy<Task>(async () =>
        {
            try
            {
                await process.InRepositoryAsync(directory, async session =>
                {
                    await session.RunAsync(["fetch", "--all", "--prune"], background: background); return true;
                });
            }
            finally { fetches.TryRemove(key, out var completed); }
        })).Value;
        await task.WaitAsync(cancellationToken);
    }

    public Task PullAsync(string directory, CancellationToken cancellationToken = default) => ActionAsync(directory, ["pull", "--no-edit"], cancellationToken);
    public Task PushAsync(string directory, CancellationToken cancellationToken = default) => ActionAsync(directory, ["push"], cancellationToken);
    public Task PushReferenceAsync(string directory, string remote, string reference, CancellationToken cancellationToken = default) =>
        ActionAsync(directory, ["push", "--set-upstream", "--", remote, reference], cancellationToken);
    public Task PushTagAsync(string directory, string remote, string tag, CancellationToken cancellationToken = default) =>
        ActionAsync(directory, ["push", "--", remote, "refs/tags/" + tag], cancellationToken);
    public Task StashAsync(string directory, string message, CancellationToken cancellationToken = default) =>
        ActionAsync(directory, ["stash", "push", "--include-untracked", "--message", message], cancellationToken);

    public Task StashActionAsync(string directory, string reference, string action, CancellationToken cancellationToken = default)
    {
        if (action is not ("apply" or "pop" or "drop")) throw new ArgumentOutOfRangeException(nameof(action));
        if (!System.Text.RegularExpressions.Regex.IsMatch(reference, @"^stash@\{\d+\}$")) throw new GitException("Invalid stash reference.");
        return ActionAsync(directory, ["stash", action, reference], cancellationToken);
    }

    public Task<Diff> StashDiffAsync(string directory, string reference, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var hash = await ResolveAsync(session, reference);
            return Diff.Parse(await session.TextAsync("stash", "show", "--include-untracked", "--patch", "--full-index", "--binary", hash));
        }, cancellationToken);

    public Task<byte[]?> FileAsync(string directory, string path, string version, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync<byte[]?>(directory, async session =>
        {
            if (version == "working")
            {
                var full = Path.GetFullPath(Path.Combine(directory, path));
                if (!Path.GetRelativePath(directory, full).Split(Path.DirectorySeparatorChar).Contains("..") && File.Exists(full))
                    return await File.ReadAllBytesAsync(full, cancellationToken);
                return null;
            }
            var spec = version == "index" ? ":" + path : (await ResolveAsync(session, version)) + ":" + path;
            var output = await session.RunAsync(["cat-file", "blob", spec], acceptedExitCodes: [0, 128]);
            return output.ExitCode == 0 ? output.Bytes : null;
        }, cancellationToken);

    public Task<byte[]> BlobAsync(string directory, string hash, CancellationToken cancellationToken = default)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(hash, "^(?:[0-9a-f]{40}|[0-9a-f]{64})$")) throw new GitException("Invalid blob identifier.");
        return process.InRepositoryAsync(directory, async session => (await session.RunAsync(["cat-file", "blob", hash])).Bytes, cancellationToken);
    }

    public async Task CloneAsync(string remote, string destination, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(remote) || remote.StartsWith('-')) throw new GitException("A repository URL is required.");
        if (Directory.Exists(destination) && Directory.EnumerateFileSystemEntries(destination).Any()) throw new GitException("Choose an empty destination directory.");
        var parent = Path.GetDirectoryName(Path.GetFullPath(destination))!;
        await process.ExecuteAsync(parent, ["clone", "--", remote, destination], cancellationToken: cancellationToken, timeout: TimeSpan.FromHours(1));
    }

    public Task ActionAsync(string directory, string[] arguments, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session => { await session.RunAsync(arguments); return true; }, cancellationToken);

    internal static async Task<string> ResolveAsync(GitSession session, string reference) =>
        (await session.TextAsync("rev-parse", "--verify", "--end-of-options", reference + "^{commit}")).Trim();
    internal static async Task ValidateBranchAsync(GitSession session, string name) =>
        _ = await session.RunAsync(["check-ref-format", "--branch", name]);
    private static string[] SplitLines(string text) => text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
    private static async Task<Branch[]> BranchesAsync(GitSession session)
    {
        var raw = await session.TextAsync("for-each-ref", "--sort=-authordate", "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(upstream)%00%(symref)", "refs/heads", "refs/remotes");
        return SplitLines(raw).Select(line => line.Split('\0')).Where(parts => parts[4].Length == 0).Select(parts =>
        {
            var remote = parts[0].StartsWith("refs/remotes/", StringComparison.Ordinal);
            return new Branch(parts[0][(remote ? 13 : 11)..], parts[1], parts[2] == "*", remote, parts[3]);
        }).ToArray();
    }
}
