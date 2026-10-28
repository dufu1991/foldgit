using System.Text;

namespace FoldGit.Core.Git;

public sealed record Worktree(string Path, string? Head, string? Branch, bool Main, bool Bare, bool Detached, string? Locked, string? Prunable);
public enum WorktreeBranchMode { Existing, New, Detached }
public enum ConflictResolution { Target, Incoming, Edited, Delete }
public sealed record MergeConflict(string Path, bool TargetExists, bool IncomingExists);
public sealed record MergeState(string[] Heads, MergeConflict[] Conflicts, bool Unstaged)
{
    public bool Merging => Heads.Length > 0;
    public bool CanContinue => Merging && Conflicts.Length == 0 && !Unstaged;
}
public sealed record CompletionPlan(string Source, string SourceBranch, string SourceCommit,
    string Target, string TargetBranch, string TargetCommit, string? OriginalTargetBranch, int CommitCount);
public sealed record MergeResult(bool Complete, MergeState State, string Diagnostic);

public sealed class WorktreeService(GitProcess process)
{
    public Task<Worktree[]> ListAsync(string directory, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, ListAsync, cancellationToken);

    public static Worktree[] Parse(string output)
    {
        var result = new List<Worktree>();
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        void Complete()
        {
            if (fields.Count == 0) return;
            var branch = fields.GetValueOrDefault("branch");
            result.Add(new(Path.GetFullPath(fields["worktree"]), fields.GetValueOrDefault("HEAD"), branch?.StartsWith("refs/heads/", StringComparison.Ordinal) == true ? branch[11..] : branch,
                result.Count == 0, fields.ContainsKey("bare"), fields.ContainsKey("detached"), fields.GetValueOrDefault("locked"), fields.GetValueOrDefault("prunable")));
            fields.Clear();
        }
        foreach (var field in output.Split('\0'))
        {
            if (field.Length == 0) { Complete(); continue; }
            var split = field.IndexOf(' ');
            fields.Add(split < 0 ? field : field[..split], split < 0 ? "" : field[(split + 1)..]);
        }
        Complete();
        return result.ToArray();
    }

    public Task AddAsync(string directory, string destination, WorktreeBranchMode mode, string name,
        string start, CancellationToken cancellationToken = default) => process.InRepositoryAsync(directory, async session =>
    {
        var hash = await RepositoryService.ResolveAsync(session, start);
        if (mode != WorktreeBranchMode.Detached) await RepositoryService.ValidateBranchAsync(session, name);
        await session.RunAsync(mode switch
        {
            WorktreeBranchMode.New => ["worktree", "add", "-b", name, "--", destination, hash],
            WorktreeBranchMode.Existing => ["worktree", "add", "--", destination, name],
            _ => ["worktree", "add", "--detach", "--", destination, hash]
        });
        return true;
    }, cancellationToken);

    public Task ChangeAsync(string directory, string action, string? path = null, string? destination = null,
        CancellationToken cancellationToken = default)
    {
        if (action is not ("remove" or "move" or "lock" or "unlock" or "prune")) throw new ArgumentOutOfRangeException(nameof(action));
        if (action != "prune" && path is null) throw new ArgumentNullException(nameof(path));
        if (action == "move" && destination is null) throw new ArgumentNullException(nameof(destination));
        return process.InRepositoryAsync(directory, async session =>
        {
            await session.RunAsync(action switch
            {
                "prune" => ["worktree", "prune", "--expire=now"],
                "move" => ["worktree", "move", "--", path!, destination!],
                _ => ["worktree", action, "--", path!]
            }); return true;
        }, cancellationToken);
    }

    public Task<CompletionPlan> PrepareAsync(string source, string targetBranch, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(source, async session =>
        {
            await RepositoryService.ValidateBranchAsync(session, targetBranch);
            var trees = await ListAsync(session);
            var sourcePath = Path.GetFullPath((await session.TextAsync("rev-parse", "--show-toplevel")).TrimEnd('\r', '\n'));
            var sourceTree = trees.Single(tree => SamePath(tree.Path, sourcePath));
            if (sourceTree.Main || sourceTree.Bare || sourceTree.Branch is null || sourceTree.Head is null)
                throw new GitException("Finish requires a linked worktree with a local branch.");
            if (sourceTree.Branch == targetBranch) throw new GitException("Choose a different target branch.");
            var target = trees.FirstOrDefault(tree => tree.Branch == targetBranch && !tree.Bare && tree.Prunable is null)
                ?? trees.First(tree => tree.Main && !SamePath(tree.Path, sourcePath) && tree.Prunable is null);
            await RequireCleanAsync(session);
            var targetSession = new GitSession(process, target.Path, cancellationToken);
            await RequireFamilyAsync(session, targetSession);
            var merge = await ReadMergeAsync(targetSession);
            if (!merge.Merging) await RequireCleanAsync(targetSession);
            else if (target.Branch != targetBranch || !merge.Heads.SequenceEqual([sourceTree.Head]))
                throw new GitException("Finish the existing operation before starting another merge.");
            var targetCommit = await RepositoryService.ResolveAsync(session, "refs/heads/" + targetBranch);
            var count = int.Parse((await session.TextAsync("rev-list", "--count", targetCommit + ".." + sourceTree.Head)).Trim());
            return new CompletionPlan(sourcePath, sourceTree.Branch, sourceTree.Head, target.Path, targetBranch, targetCommit, target.Branch, count);
        }, cancellationToken);

    public Task<MergeResult> MergeAsync(CompletionPlan plan, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(plan.Source, async source =>
        {
            await ValidateSourceAsync(source, plan);
            var target = new GitSession(process, plan.Target, cancellationToken);
            await RequireFamilyAsync(source, target);
            await RequireCleanAsync(target);
            var branch = await CurrentBranchAsync(target);
            if (branch != plan.OriginalTargetBranch || await RepositoryService.ResolveAsync(target, "refs/heads/" + plan.TargetBranch) != plan.TargetCommit)
                throw new GitException("The branch or commit changed. Refresh the merge preview.");
            if (branch != plan.TargetBranch) await target.RunAsync(["switch", "--", plan.TargetBranch]);
            var output = await target.RunAsync(["merge", "--no-edit", "--commit", "--no-squash", "--message",
                "Merge branch '" + plan.SourceBranch + "' into " + plan.TargetBranch, "--", plan.SourceCommit], acceptedExitCodes: [0, 1, 128]);
            var state = await ReadMergeAsync(target);
            if (state.Merging && state.Heads.Contains(plan.SourceCommit)) return new MergeResult(false, state, output.Error);
            if (output.ExitCode != 0) throw new GitException(output.Error, output.ExitCode);
            await RequireIntegratedAsync(target, plan);
            return new MergeResult(true, state, "");
        }, cancellationToken);

    public Task CleanupAsync(CompletionPlan plan, bool removeDirectory, bool deleteBranch, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(plan.Target, async target =>
        {
            await RequireIntegratedAsync(target, plan);
            if (await RepositoryService.ResolveAsync(target, "refs/heads/" + plan.SourceBranch) != plan.SourceCommit)
                throw new GitException("The source branch changed. The worktree and branch were kept.");
            var trees = await ListAsync(target);
            var sourceTree = trees.FirstOrDefault(tree => SamePath(tree.Path, plan.Source));
            if (removeDirectory && sourceTree is not null)
            {
                if (sourceTree.Main || sourceTree.Locked is not null || sourceTree.Prunable is not null)
                    throw new GitException("Unlock or restore the worktree before cleanup.");
                var source = new GitSession(process, plan.Source, cancellationToken);
                await RequireFamilyAsync(target, source);
                await ValidateSourceAsync(source, plan);
                await target.RunAsync(["worktree", "remove", "--", plan.Source]);
            }
            if (deleteBranch)
            {
                trees = await ListAsync(target);
                if (trees.Any(tree => tree.Branch == plan.SourceBranch)) throw new GitException("The source branch is still checked out.");
                await target.RunAsync(["branch", "--delete", "--", plan.SourceBranch]);
            }
            return true;
        }, cancellationToken);

    public Task<MergeState> MergeStateAsync(string directory, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, ReadMergeAsync, cancellationToken);

    public Task<byte[]?> ConflictContentAsync(string directory, string path, bool incoming, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync<byte[]?>(directory, async session =>
        {
            var state = await ReadMergeAsync(session);
            var conflict = state.Conflicts.Single(value => value.Path == path);
            if (!(incoming ? conflict.IncomingExists : conflict.TargetExists)) return null;
            return (await session.RunAsync(["cat-file", "blob", (incoming ? ":3:" : ":2:") + path])).Bytes;
        }, cancellationToken);

    public Task ResolveAsync(string directory, string path, ConflictResolution resolution, CancellationToken cancellationToken = default) =>
        process.InRepositoryAsync(directory, async session =>
        {
            var state = await ReadMergeAsync(session);
            if (!state.Merging) throw new GitException("There is no active merge.");
            var conflict = state.Conflicts.Single(value => value.Path == path);
            if (resolution is ConflictResolution.Target or ConflictResolution.Incoming)
            {
                var exists = resolution == ConflictResolution.Target ? conflict.TargetExists : conflict.IncomingExists;
                if (!exists) await session.RunAsync(["--literal-pathspecs", "rm", "--", path]);
                else
                {
                    await session.RunAsync(["--literal-pathspecs", "checkout", resolution == ConflictResolution.Target ? "--ours" : "--theirs", "--", path]);
                    await session.RunAsync(["--literal-pathspecs", "add", "--", path]);
                }
            }
            else if (resolution == ConflictResolution.Delete) await session.RunAsync(["--literal-pathspecs", "rm", "--", path]);
            else
            {
                var content = await File.ReadAllTextAsync(Path.Combine(directory, path), cancellationToken);
                if (content.Split('\n').Any(line => line.StartsWith("<<<<<<< ", StringComparison.Ordinal)
                    || line.StartsWith(">>>>>>> ", StringComparison.Ordinal) || line.TrimEnd('\r') == "======="))
                    throw new GitException("Remove the conflict markers before marking this file as resolved.");
                await session.RunAsync(["--literal-pathspecs", "add", "--", path]);
            }
            return true;
        }, cancellationToken);

    public Task ContinueAsync(string directory, CancellationToken cancellationToken = default) => process.InRepositoryAsync(directory, async session =>
    {
        if (!(await ReadMergeAsync(session)).CanContinue) throw new GitException("Resolve all conflicts and stage changes before continuing.");
        await session.RunAsync(["commit", "--no-edit"]); return true;
    }, cancellationToken);

    public Task AbortAsync(string directory, CancellationToken cancellationToken = default) => process.InRepositoryAsync(directory, async session =>
    {
        if (!(await ReadMergeAsync(session)).Merging) throw new GitException("There is no active merge.");
        await session.RunAsync(["merge", "--abort"]); return true;
    }, cancellationToken);

    private static async Task<Worktree[]> ListAsync(GitSession session) => Parse(await session.TextAsync("worktree", "list", "--porcelain", "-z"));
    private async Task RequireFamilyAsync(GitSession left, GitSession right)
    {
        var leftCommon = (await left.TextAsync("rev-parse", "--path-format=absolute", "--git-common-dir")).TrimEnd('\r', '\n');
        var rightCommon = (await right.TextAsync("rev-parse", "--path-format=absolute", "--git-common-dir")).TrimEnd('\r', '\n');
        if (!SamePath(leftCommon, rightCommon)) throw new GitException("The worktree no longer belongs to this repository.");
    }
    private bool SamePath(string left, string right) => process.Identity(left) == process.Identity(right);
    private static async Task<string?> CurrentBranchAsync(GitSession session)
    {
        var output = await session.RunAsync(["symbolic-ref", "--quiet", "--short", "HEAD"], acceptedExitCodes: [0, 1]);
        return output.ExitCode == 0 ? output.Text.TrimEnd('\r', '\n') : null;
    }
    private static async Task<MergeState> ReadMergeAsync(GitSession session)
    {
        var git = (await session.TextAsync("rev-parse", "--absolute-git-dir")).TrimEnd('\r', '\n');
        var headPath = Path.Combine(git, "MERGE_HEAD");
        var heads = File.Exists(headPath) ? (await File.ReadAllLinesAsync(headPath)).Where(line => line.Length > 0).ToArray() : [];
        var stages = new Dictionary<string, HashSet<int>>(StringComparer.Ordinal);
        foreach (var record in (await session.TextAsync("ls-files", "--unmerged", "-z")).Split('\0', StringSplitOptions.RemoveEmptyEntries))
        {
            var tab = record.IndexOf('\t');
            if (tab < 0) throw new GitException("Invalid merge information from Git.");
            var stage = int.Parse(record[..tab].Split(' ')[2]);
            var path = record[(tab + 1)..];
            if (!stages.TryGetValue(path, out var values)) stages[path] = values = [];
            values.Add(stage);
        }
        return new(heads, stages.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => new MergeConflict(pair.Key, pair.Value.Contains(2), pair.Value.Contains(3))).ToArray(),
            (await session.TextAsync("diff", "--name-only", "-z")).Length > 0);
    }
    private static async Task RequireCleanAsync(GitSession session)
    {
        var git = (await session.TextAsync("rev-parse", "--absolute-git-dir")).TrimEnd('\r', '\n');
        foreach (var name in new[] { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply" })
            if (File.Exists(Path.Combine(git, name)) || Directory.Exists(Path.Combine(git, name))) throw new GitException("Finish the existing operation first.");
        if ((await session.TextAsync("status", "--porcelain=v2", "-z", "--untracked-files=all")).Length > 0)
            throw new GitException("Commit or stash changes before continuing.");
    }
    private static async Task ValidateSourceAsync(GitSession source, CompletionPlan plan)
    {
        await RequireCleanAsync(source);
        if (await CurrentBranchAsync(source) != plan.SourceBranch || await RepositoryService.ResolveAsync(source, "HEAD") != plan.SourceCommit
            || await RepositoryService.ResolveAsync(source, "refs/heads/" + plan.SourceBranch) != plan.SourceCommit)
            throw new GitException("The source branch changed. Refresh the merge preview.");
    }
    private static async Task RequireIntegratedAsync(GitSession target, CompletionPlan plan)
    {
        if ((await ReadMergeAsync(target)).Merging) throw new GitException("Finish the active merge before cleanup.");
        var ancestor = await target.RunAsync(["merge-base", "--is-ancestor", plan.SourceCommit, "refs/heads/" + plan.TargetBranch], acceptedExitCodes: [0, 1]);
        if (ancestor.ExitCode != 0) throw new GitException("The target does not contain all source commits. The worktree and branch were kept.");
    }
}
