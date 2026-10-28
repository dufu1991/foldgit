using System.Text;
using System.Text.Json;
using FoldGit.Core.Git;
using FoldGit.Core.History;
using FoldGit.Core.Resources;
using FoldGit.Core.Workspace;

if (args.Contains("--child-wait")) { await Task.Delay(TimeSpan.FromMinutes(1)); return; }
if (args.Contains("--child-output")) { await Console.OpenStandardError().WriteAsync(new byte[5 * 1024 * 1024]); return; }

var passed = 0;
async Task Test(string name, Func<Task> body)
{
    await body();
    Console.WriteLine("PASS " + name);
    passed++;
}
void Assert(bool value, string message = "Assertion failed") { if (!value) throw new InvalidOperationException(message); }
async Task Throws(Func<Task> action)
{
    var threw = false;
    try { await action(); }
    catch (Exception error) when (error is GitException or OperationCanceledException) { threw = true; }
    Assert(threw, "Expected the operation to fail safely.");
}

var git = new GitProcess(Environment.GetEnvironmentVariable("FOLDGIT_GIT") ?? "git");
var service = new RepositoryService(git);
var trees = new WorktreeService(git);
var temporary = Path.Combine(Path.GetTempPath(), "FoldGit-tests-" + Guid.NewGuid());
Directory.CreateDirectory(temporary);
async Task<string> Repository(string name)
{
    var directory = Path.Combine(temporary, name); Directory.CreateDirectory(directory);
    await git.ExecuteAsync(directory, ["init", "--initial-branch=main"]);
    await git.ExecuteAsync(directory, ["config", "user.name", "FoldGit Tests"]);
    await git.ExecuteAsync(directory, ["config", "user.email", "tests@example.com"]);
    await git.ExecuteAsync(directory, ["config", "commit.gpgsign", "false"]);
    await git.ExecuteAsync(directory, ["config", "core.autocrlf", "false"]);
    return directory;
}
try
{
    await Test("Shared fixtures, icons and graph", () =>
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "behavior.json")));
        var theme = FileIconTheme.Load(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MaterialFileIcons.json"));
        foreach (var item in fixture.RootElement.GetProperty("icons").EnumerateArray())
            Assert(theme.Icon(item.GetProperty("path").GetString()!, true) == item.GetProperty("icon").GetString());
        foreach (var item in fixture.RootElement.GetProperty("diffs").EnumerateArray())
        {
            var file = Diff.Parse(item.GetProperty("raw").GetString()!).Files.Single();
            Assert(file.Path == item.GetProperty("path").GetString());
            Assert(file.Additions == item.GetProperty("added").GetInt32() && file.Deletions == item.GetProperty("removed").GetInt32());
        }
        foreach (var item in fixture.RootElement.GetProperty("inline").EnumerateArray())
        {
            var changes = InlineDiff.Compare(item.GetProperty("old").GetString()!, item.GetProperty("new").GetString()!);
            var expectedOld = item.GetProperty("oldSpans").EnumerateArray().Select(span => new TextSpan(span[0].GetInt32(), span[1].GetInt32()));
            var expectedNew = item.GetProperty("newSpans").EnumerateArray().Select(span => new TextSpan(span[0].GetInt32(), span[1].GetInt32()));
            Assert(changes.Old.SequenceEqual(expectedOld) && changes.New.SequenceEqual(expectedNew));
        }
        var entries = fixture.RootElement.GetProperty("graph").EnumerateArray().ToArray();
        var commits = entries.Select(item => new Commit(item.GetProperty("hash").GetString()!, item.GetProperty("parents").EnumerateArray().Select(value => value.GetString()!).ToArray(), "Developer", "dev@example.com", DateTimeOffset.UtcNow, "message", "")).ToArray();
        Assert(CommitGraph.Layout(commits).Select(row => row.Column).SequenceEqual(entries.Select(item => item.GetProperty("column").GetInt32())));
        return Task.CompletedTask;
    });
    await Test("Eight localization catalogs and plural selection", () =>
    {
        foreach (var language in TextCatalog.Languages)
        {
            var text = new TextCatalog(language);
            Assert(text.Get("Commit").Length > 0);
            foreach (var count in new long[] { 0, 1, 2, 5, 11, 21, 22, 25 }) Assert(!text.Count("%lld commits", count).Contains('%'));
        }
        Assert(TextCatalog.PluralCategory("ru", 21) == "one" && TextCatalog.PluralCategory("ru", 22) == "few");
        return Task.CompletedTask;
    });
    await Test("Workspace grouping, filtering and noncontiguous ordering", () =>
    {
        var state = WorkspaceState.Empty.Add("/one", "1").Add("/two", "2").Add("/three", "3").Group(["1", "3"], "Group");
        Assert(state.Visible("Group", WorkspaceSort.Manual).Length == 2);
        Assert(state.Move(["1", "3"], 3).Repositories.Select(repository => repository.Id).SequenceEqual(["2", "1", "3"]));
        Assert(state.Dissolve(state.Groups.Single().Id).Repositories.All(repository => repository.GroupId is null));
        return Task.CompletedTask;
    });
    var repository = await Repository("仓库 with spaces");
    await Test("Empty repository and literal special filenames", async () =>
    {
        Assert((await service.SnapshotAsync(repository)).Head.Length == 0);
        Assert((await service.HistoryAsync(repository)).Length == 0);
        var paths = new[] { "中文 file.txt", "[literal].txt", "--option.txt" };
        foreach (var path in paths) await File.WriteAllTextAsync(Path.Combine(repository, path), "first\nsecond\n");
        await service.StagePathsAsync(repository, paths, true);
        Assert((await service.SnapshotAsync(repository)).Files.All(file => file.IsStaged));
        await service.StageAllAsync(repository, false);
        Assert((await service.SnapshotAsync(repository)).Files.All(file => file.IsUntracked));
        await service.StagePathsAsync(repository, paths, true);
        await service.CommitAsync(repository, "feat: initial\n\nAuthor search body", false);
        Assert((await service.HistoryAsync(repository, query: "SEARCH BODY")).Length == 1);
        Assert((await service.HistoryAsync(repository, query: ".*")).Length == 0);
    });
    await Test("Hunk staging, reverse staging and stale patch rejection", async () =>
    {
        var path = Path.Combine(repository, "中文 file.txt");
        await File.WriteAllTextAsync(path, "changed\nsecond\n");
        var snapshot = await service.SnapshotAsync(repository);
        var file = snapshot.Unstaged.Files.Single(); var hunk = file.Hunks.Single();
        await service.StageHunkAsync(repository, file, hunk, true);
        await Throws(() => service.StageHunkAsync(repository, file, hunk, true));
        var staged = (await service.SnapshotAsync(repository)).Staged.Files.Single();
        await service.StageHunkAsync(repository, staged, staged.Hunks.Single(), false);
        Assert((await service.SnapshotAsync(repository)).Staged.Files.Length == 0);
        await service.StageAllAsync(repository, true);
        await service.CommitAsync(repository, "fix: change", false);
    });
    await Test("Independent hunks, CRLF, renames and amend", async () =>
    {
        var directory = await Repository("hunks");
        var path = Path.Combine(directory, "lines.txt");
        var original = Enumerable.Range(1, 40).Select(number => "line " + number).ToArray();
        await File.WriteAllTextAsync(path, string.Join("\r\n", original) + "\r\n");
        await service.StageAllAsync(directory, true); await service.CommitAsync(directory, "feat: lines", false);
        var modified = original.ToArray(); modified[1] = "modified first"; modified[30] = "modified second";
        await File.WriteAllTextAsync(path, string.Join("\r\n", modified) + "\r\n");
        var file = (await service.SnapshotAsync(directory)).Unstaged.Files.Single();
        Assert(file.Hunks.Length == 2);
        await service.StageHunkAsync(directory, file, file.Hunks[0], true);
        var index = Encoding.UTF8.GetString((await service.FileAsync(directory, "lines.txt", "index"))!);
        Assert(index.Contains("modified first", StringComparison.Ordinal) && !index.Contains("modified second", StringComparison.Ordinal));
        Assert(index.Contains("\r\n", StringComparison.Ordinal));
        await service.StageAllAsync(directory, true); await service.CommitAsync(directory, "fix: lines", true);
        Assert((await service.HistoryAsync(directory)).Length == 1);
        await service.ActionAsync(directory, ["mv", "--", "lines.txt", "renamed.txt"]);
        var rename = (await service.SnapshotAsync(directory)).Staged.Files.Single();
        Assert(rename.Path == "renamed.txt" && rename.OldPath == "lines.txt");
        await service.StageFileAsync(directory, rename, false);
        Assert((await service.SnapshotAsync(directory)).Staged.Files.Length == 0);
        await service.StageFileAsync(directory, rename, true); await service.CommitAsync(directory, "refactor: rename", false);
        Assert((await service.CompareAsync(directory, "HEAD^", "HEAD")).Files.Single().Path == "renamed.txt");
    });
    await Test("References, detached HEAD, binary contents and stash", async () =>
    {
        await service.CreateBranchAsync(repository, "feature", "HEAD", false);
        await service.RenameBranchAsync(repository, "feature", "feature-renamed");
        await service.TagAsync(repository, "v1", "HEAD");
        Assert((await service.GetCommitAsync(repository, "refs/tags/v1")).Hash == (await service.SnapshotAsync(repository)).Head);
        await service.SwitchAsync(repository, "v1", true);
        Assert((await service.SnapshotAsync(repository)).Branch.Length == 0);
        await service.SwitchAsync(repository, "main");
        var bytes = new byte[] { 0, 255, 1, 128, 3 };
        await File.WriteAllBytesAsync(Path.Combine(repository, "binary.dat"), bytes);
        await service.StageAllAsync(repository, true); await service.CommitAsync(repository, "feat: binary", false);
        Assert((await service.FileAsync(repository, "binary.dat", "HEAD"))!.SequenceEqual(bytes));
        await File.WriteAllTextAsync(Path.Combine(repository, "untracked.txt"), "stash");
        await service.StashAsync(repository, "saved work");
        var stash = (await service.SnapshotAsync(repository)).Stashes.Single();
        Assert((await service.StashDiffAsync(repository, stash.Reference)).Files.Any(file => file.Path == "untracked.txt"));
        await service.StashActionAsync(repository, stash.Reference, "pop");
        Assert(File.Exists(Path.Combine(repository, "untracked.txt")));
        File.Delete(Path.Combine(repository, "untracked.txt"));
        await service.TagAsync(repository, "v1", null);
        await service.DeleteBranchAsync(repository, "feature-renamed", false);
    });
    await Test("Worktree lifecycle, completion and safe cleanup", async () =>
    {
        var source = Path.Combine(temporary, "linked worktree");
        await trees.AddAsync(repository, source, WorktreeBranchMode.New, "linked", "HEAD");
        await trees.ChangeAsync(repository, "lock", source);
        await Throws(() => trees.ChangeAsync(repository, "remove", source));
        await trees.ChangeAsync(repository, "unlock", source);
        await File.WriteAllTextAsync(Path.Combine(source, "feature.txt"), "feature\n");
        await service.StageAllAsync(source, true); await service.CommitAsync(source, "feat: linked", false);
        var plan = await trees.PrepareAsync(source, "main");
        Assert(plan.CommitCount == 1);
        Assert((await trees.MergeAsync(plan)).Complete);
        await trees.CleanupAsync(plan, true, true);
        Assert(!Directory.Exists(source));
        Assert(!(await service.SnapshotAsync(repository)).Branches.Any(branch => branch.Name == "linked"));
    });
    await Test("Merge conflict resolution and resume", async () =>
    {
        var source = Path.Combine(temporary, "conflict");
        await trees.AddAsync(repository, source, WorktreeBranchMode.New, "conflict", "HEAD");
        await File.WriteAllTextAsync(Path.Combine(source, "中文 file.txt"), "incoming\n");
        await service.StageAllAsync(source, true); await service.CommitAsync(source, "feat: incoming", false);
        await File.WriteAllTextAsync(Path.Combine(repository, "中文 file.txt"), "target\n");
        await service.StageAllAsync(repository, true); await service.CommitAsync(repository, "feat: target", false);
        var plan = await trees.PrepareAsync(source, "main");
        Assert(!(await trees.MergeAsync(plan)).Complete);
        Assert((await trees.MergeStateAsync(repository)).Conflicts.Length == 1);
        await Throws(() => trees.ContinueAsync(repository));
        Assert((await trees.PrepareAsync(source, "main")).SourceCommit == plan.SourceCommit);
        await trees.ResolveAsync(repository, "中文 file.txt", ConflictResolution.Incoming);
        await trees.ContinueAsync(repository);
        await trees.CleanupAsync(plan, true, true);
        Assert(await File.ReadAllTextAsync(Path.Combine(repository, "中文 file.txt")) == "incoming\n");
    });
    await Test("Clone, remote synchronization and concurrent snapshots", async () =>
    {
        var clone = Path.Combine(temporary, "clone");
        await service.CloneAsync(repository, clone);
        await Task.WhenAll(Enumerable.Range(0, 6).Select(_ => service.SnapshotAsync(clone)));
        await Task.WhenAll(service.FetchAsync(clone, true), service.FetchAsync(clone, true));
        Assert((await service.SnapshotAsync(clone)).Behind == 0);
        var bare = Path.Combine(temporary, "remote.git"); Directory.CreateDirectory(bare);
        await git.ExecuteAsync(bare, ["init", "--bare", "--initial-branch=main"]);
        await service.ActionAsync(clone, ["remote", "set-url", "origin", bare]);
        await service.PushReferenceAsync(clone, "origin", "main");
        await service.TagAsync(clone, "published", "HEAD"); await service.PushTagAsync(clone, "origin", "published");
        var mirror = Path.Combine(temporary, "mirror"); await service.CloneAsync(bare, mirror);
        Assert((await service.SnapshotAsync(mirror)).Tags.Contains("published"));
        await service.CreateBranchAsync(clone, "remote-feature", "HEAD", true);
        await service.PushReferenceAsync(clone, "origin", "remote-feature");
        await service.FetchAsync(mirror, false);
        await service.TrackBranchAsync(mirror, "origin/remote-feature");
        Assert((await service.SnapshotAsync(mirror)).Branch == "remote-feature");
        await service.PullAsync(mirror);
    });
    await Test("Changed source commits and dirty worktrees block cleanup", async () =>
    {
        var source = Path.Combine(temporary, "protected");
        await trees.AddAsync(repository, source, WorktreeBranchMode.New, "protected", "HEAD");
        var plan = await trees.PrepareAsync(source, "main");
        await File.WriteAllTextAsync(Path.Combine(source, "untracked.txt"), "keep");
        await Throws(() => trees.CleanupAsync(plan, true, true));
        Assert(File.Exists(Path.Combine(source, "untracked.txt")));
        await service.StageAllAsync(source, true); await service.CommitAsync(source, "feat: new source commit", false);
        await Throws(() => trees.MergeAsync(plan)); await Throws(() => trees.CleanupAsync(plan, true, true));
        var refreshed = await trees.PrepareAsync(source, "main"); await trees.MergeAsync(refreshed);
        await trees.CleanupAsync(refreshed, true, true);
    });
    await Test("Cancellation and output limits terminate children", async () =>
    {
        var child = new GitProcess(Environment.ProcessPath!);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
        await Throws(() => child.ExecuteAsync(temporary, ["--child-wait"], cancellationToken: cancellation.Token));
        await Throws(() => child.ExecuteAsync(temporary, ["--child-output"]));
    });
    Console.WriteLine($"Passed {passed} behavior suites.");
}
finally
{
    // Git object files are read-only on Windows; clear that flag before removing test fixtures.
    foreach (var file in Directory.EnumerateFiles(temporary, "*", SearchOption.AllDirectories))
        File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
    Directory.Delete(temporary, true);
}
