using System.Text;
using System.Text.Json;

namespace FoldGit.Core.Git;

public sealed record SquashPlan(string Head, string Branch, Commit[] Commits, int FollowingCount)
{
    public string Message => string.Join(" | ", Commits.Select(commit => commit.Subject));
}

public sealed partial class RepositoryService
{
    private sealed record SquashRecovery(string Head, string Branch, string Tree, string Backup);

    private const string SquashAttention = "Squash recovery needs attention. The original history is saved under refs/foldgit/squash-backups.";

    public static SquashBlockReason? SquashSelectionError(IReadOnlySet<string> hashes, IEnumerable<Commit> commits, string head) =>
        hashes.Count < 2 ? SquashBlockReason.TooFewCommits : SquashSelectionError(hashes, FirstParentChain(commits, head));

    private static SquashBlockReason? SquashSelectionError(IReadOnlySet<string> hashes, List<Commit> chain)
    {
        if (hashes.Count < 2) return SquashBlockReason.TooFewCommits;
        var indices = chain.Select((commit, index) => (commit, index)).Where(value => hashes.Contains(value.commit.Hash)).Select(value => value.index).ToArray();
        if (indices.Length != hashes.Count || indices[^1] - indices[0] + 1 != hashes.Count)
            return SquashBlockReason.NotConsecutive;
        if (chain.Take(indices[^1] + 1).Any(commit => commit.Parents.Length > 1))
            return SquashBlockReason.MergeCommit;
        return null;
    }

    /// <summary>The English message for a block reason; it doubles as the localization key.</summary>
    public static string SquashBlockMessage(SquashBlockReason reason) => reason switch
    {
        SquashBlockReason.TooFewCommits => "Select at least two consecutive commits.",
        SquashBlockReason.NotConsecutive => "Select consecutive commits on the current branch.",
        SquashBlockReason.MergeCommit => "The affected history contains a merge commit.",
        SquashBlockReason.CommitSearchActive => "Clear the commit search before squashing commits.",
        _ => throw new ArgumentOutOfRangeException(nameof(reason))
    };

    private static List<Commit> FirstParentChain(IEnumerable<Commit> commits, string head)
    {
        var byHash = new Dictionary<string, Commit>(StringComparer.Ordinal);
        foreach (var commit in commits) byHash.TryAdd(commit.Hash, commit);
        var chain = new List<Commit>();
        while (byHash.TryGetValue(head, out var commit))
        {
            chain.Add(commit);
            head = commit.Parents.FirstOrDefault() ?? "";
        }
        return chain;
    }

    private static async Task<string> GitDirectoryAsync(GitSession session) =>
        (await session.TextAsync("rev-parse", "--absolute-git-dir")).TrimEnd('\r', '\n');

    public Task<SquashPlan> PrepareSquashAsync(string directory, IReadOnlySet<string> hashes, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var gitDirectory = await GitDirectoryAsync(session);
            await RecoverSquashAsync(session, gitDirectory);
            return (await PrepareSquashAsync(session, gitDirectory, hashes)).Plan;
        }, cancellationToken);

    // Returns the plan with the first-parent chain from HEAD it was validated against.
    private static async Task<(SquashPlan Plan, List<Commit> Chain)> PrepareSquashAsync(GitSession session, string gitDirectory, IReadOnlySet<string> hashes)
    {
        var branch = (await session.TextAsync("branch", "--show-current")).Trim();
        if (branch.Length == 0) throw new GitException("Switch to a local branch before squashing commits.");
        if ((await session.TextAsync("rev-parse", "--is-shallow-repository")).Trim() != "false")
            throw new GitException("The repository history is incomplete. Fetch the complete history before squashing.");
        if (File.Exists(Path.Combine(gitDirectory, "index.lock")))
            throw new GitException("The Git index is locked. Wait for other Git operations to finish. If the lock remains, check for an interrupted Git process.");
        if (new[] { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG", "sequencer" }
            .Any(name => File.Exists(Path.Combine(gitDirectory, name)) || Directory.Exists(Path.Combine(gitDirectory, name))))
            throw new GitException("Finish the current Git operation before squashing commits.");
        if ((await session.TextAsync("status", "--porcelain=v2", "-z", "--untracked-files=all")).Length > 0)
            throw new GitException("Commit or stash all changes before squashing commits.");
        var head = (await session.TextAsync("rev-parse", "HEAD")).Trim();
        // %P still lists every parent under --first-parent, so merge commits are still detected.
        var chain = FirstParentChain(GitRecords.Commits(await session.TextAsync("log", "--first-parent", "--format=" + GitRecords.CommitFormat, "HEAD")), head);
        if (SquashSelectionError(hashes, chain) is { } error) throw new GitException(SquashBlockMessage(error));
        var first = chain.FindIndex(commit => hashes.Contains(commit.Hash));
        var last = chain.FindLastIndex(commit => hashes.Contains(commit.Hash));
        await CheckSquashPublicationAsync(session, chain[last].Hash);
        return (new(head, branch, chain.Where(commit => hashes.Contains(commit.Hash)).Reverse().ToArray(), first), chain);
    }

    private static async Task RemoveSquashRefsAsync(GitSession session, string prefix)
    {
        var references = SplitLines(await session.TextAsync("for-each-ref", "--format=%(refname)", prefix));
        if (references.Length == 0) return;
        // One transaction instead of one process per fetched ref.
        var input = string.Concat(references.Select(reference => "delete " + reference + "\n"));
        await session.RunAsync(["update-ref", "--stdin"], new UTF8Encoding(false).GetBytes(input));
    }

    // The affected commits form one first-parent chain, so the history is published exactly when its oldest commit is.
    private static async Task CheckSquashPublicationAsync(GitSession session, string oldest)
    {
        var remotes = SplitLines(await session.TextAsync("remote"));
        if (remotes.Length == 0) return;
        var prefix = "refs/foldgit/squash-check/" + Guid.NewGuid().ToString("N");
        try
        {
            var targets = new HashSet<string>(StringComparer.Ordinal);
            foreach (var remote in remotes)
            {
                targets.UnionWith(SplitLines(await session.TextAsync("remote", "get-url", "--all", remote)));
                targets.UnionWith(SplitLines(await session.TextAsync("remote", "get-url", "--push", "--all", remote)));
            }
            var index = 0;
            foreach (var target in targets.Order(StringComparer.Ordinal))
            {
                await session.RunAsync(["fetch", "--no-tags", "--no-write-fetch-head", "--", target,
                    $"+refs/heads/*:{prefix}/{index}/heads/*", $"+refs/tags/*:{prefix}/{index}/tags/*"]);
                index++;
            }
            if ((await session.TextAsync("for-each-ref", "--count=1", "--format=%(refname)", "--contains", oldest, prefix)).Trim().Length > 0)
                throw new GitException("The affected history includes commits that have already been pushed.");
        }
        finally
        {
            try { await RemoveSquashRefsAsync(session, prefix); }
            catch (Exception) { /* Leftover check refs are harmless and must not hide the real result. */ }
        }
    }

    public Task RecoverSquashAsync(string directory, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session => { await RecoverSquashAsync(session, await GitDirectoryAsync(session)); return true; }, cancellationToken);

    private static async Task RecoverSquashAsync(GitSession session, string gitDirectory)
    {
        var journal = Path.Combine(gitDirectory, "foldgit-squash.json");
        if (!File.Exists(journal)) return;
        SquashRecovery? record;
        try { record = JsonSerializer.Deserialize<SquashRecovery>(await File.ReadAllTextAsync(journal)); }
        catch (JsonException) { throw new GitException(SquashAttention); }
        if (record is null || string.IsNullOrEmpty(record.Head) || string.IsNullOrEmpty(record.Branch) || string.IsNullOrEmpty(record.Tree))
            throw new GitException(SquashAttention);
        var rebase = Path.Combine(gitDirectory, "rebase-merge");
        if (Directory.Exists(rebase))
        {
            string originalHead, headName;
            try
            {
                originalHead = (await File.ReadAllTextAsync(Path.Combine(rebase, "orig-head"))).Trim();
                headName = (await File.ReadAllTextAsync(Path.Combine(rebase, "head-name"))).Trim();
            }
            catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
            {
                throw new GitException(SquashAttention);
            }
            if (originalHead != record.Head || headName != "refs/heads/" + record.Branch)
                throw new GitException("The repository changed. Review its Git operation before recovering the squash.");
            await session.RunAsync(["rebase", "--abort"]);
        }
        var head = (await session.TextAsync("rev-parse", "HEAD")).Trim();
        var tree = (await session.TextAsync("rev-parse", "HEAD^{tree}")).Trim();
        if (head != record.Head && tree != record.Tree) throw new GitException(SquashAttention);
        File.Delete(journal);
    }

    private static async Task WriteJournalAsync(string journal, SquashRecovery record)
    {
        // Write next to the journal and rename, so recovery never reads a partially written file.
        var temporary = journal + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(record), new UTF8Encoding(false));
            File.Move(temporary, journal, overwrite: true);
        }
        catch
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    public Task<string> SquashAsync(string directory, SquashPlan plan, string message, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            if (string.IsNullOrWhiteSpace(message)) throw new GitException("A commit message is required.");
            message = message.ReplaceLineEndings("\n");
            var gitDirectory = await GitDirectoryAsync(session);
            var (current, chain) = await PrepareSquashAsync(session, gitDirectory, plan.Commits.Select(commit => commit.Hash).ToHashSet());
            if (current.Head != plan.Head || current.Branch != plan.Branch) throw new GitException("The repository changed. Select the commits again.");
            var tree = (await session.TextAsync("rev-parse", "HEAD^{tree}")).Trim();
            var journal = Path.Combine(gitDirectory, "foldgit-squash.json");
            var temporary = Path.Combine(Path.GetTempPath(), "FoldGit-Squash-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temporary);
            try
            {
                var backup = "refs/foldgit/squash-backups/" + Guid.NewGuid().ToString("N");
                await session.RunAsync(["update-ref", backup, plan.Head]);
                await WriteJournalAsync(journal, new SquashRecovery(plan.Head, plan.Branch, tree, backup));
                var selected = plan.Commits.Select(commit => commit.Hash).ToHashSet();
                var affected = chain.Take(chain.FindIndex(commit => commit.Hash == plan.Commits[0].Hash) + 1).Reverse();
                var todo = string.Join("\n", affected.Select(commit => (selected.Contains(commit.Hash) && commit.Hash != plan.Commits[0].Hash ? "squash " : "pick ") + commit.Hash)) + "\n";
                await File.WriteAllTextAsync(Path.Combine(temporary, "todo"), todo, new UTF8Encoding(false));
                await File.WriteAllTextAsync(Path.Combine(temporary, "message"), message, new UTF8Encoding(false));
                var helper = Path.Combine(temporary, "editor.sh");
                await File.WriteAllTextAsync(helper, "cp -- \"$FOLDGIT_SQUASH_FILES/$1\" \"$2\"\n", new UTF8Encoding(false));
                var quoted = "'" + helper.Replace('\\', '/').Replace("'", "'\\''", StringComparison.Ordinal) + "'";
                var environment = new Dictionary<string, string>
                {
                    ["GIT_SEQUENCE_EDITOR"] = "sh " + quoted + " todo", ["GIT_EDITOR"] = "sh " + quoted + " message",
                    ["FOLDGIT_SQUASH_FILES"] = temporary.Replace('\\', '/')
                };
                if ((await session.TextAsync("rev-parse", "HEAD")).Trim() != plan.Head
                    || (await session.TextAsync("branch", "--show-current")).Trim() != plan.Branch
                    || (await session.TextAsync("status", "--porcelain=v2", "-z", "--untracked-files=all")).Length > 0) throw new GitException("The repository changed. Select the commits again.");
                await session.RunAsync(["-c", "rebase.abbreviateCommands=false", "-c", "rebase.instructionFormat=%s", "rebase", "-i",
                    "--no-autosquash", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--keep-empty", "--empty=keep", "--reapply-cherry-picks",
                    .. plan.Commits[0].Parents.Length > 0 ? new[] { plan.Commits[0].Parents[0] } : ["--root"]], environment: environment);
                if ((await session.TextAsync("rev-parse", "HEAD^{tree}")).Trim() != tree)
                {
                    // Restore the original history so recovery finds HEAD unchanged and clears the journal.
                    try { await session.RunAsync(["reset", "--keep", backup]); }
                    catch (GitException) { }
                    throw new GitException("Squash verification failed. The original history is saved under refs/foldgit/squash-backups.");
                }
                File.Delete(journal);
                var result = (await session.TextAsync("rev-parse", "HEAD~" + plan.FollowingCount)).Trim();
                // The squash succeeded, so the backup is no longer needed; a leftover ref is harmless.
                try { await session.RunAsync(["update-ref", "-d", backup]); }
                catch (Exception) { }
                return result;
            }
            catch
            {
                // Recovery must not inherit a cancelled UI request, and its own failure must not hide the original error.
                try { await process.InRepositoryRecoveryAsync(directory, recovery => RecoverSquashAsync(recovery, gitDirectory)); }
                catch (Exception) { }
                throw;
            }
            finally
            {
                try { Directory.Delete(temporary, recursive: true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }, cancellationToken);
}

public enum SquashBlockReason { TooFewCommits, NotConsecutive, MergeCommit, CommitSearchActive }
