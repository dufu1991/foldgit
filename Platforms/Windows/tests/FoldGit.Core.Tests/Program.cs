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
    await Test("Squash middle and root ranges, editable multiline messages and unchanged trees", async () =>
    {
        var directory = await Repository("squash middle '$() 中文");
        for (var index = 0; index < 4; index++) await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "commit " + index]);
        var before = await service.HistoryAsync(directory);
        var selected = new HashSet<string> { before[2].Hash, before[3].Hash };
        await git.ExecuteAsync(directory, ["branch", "keep", before[2].Hash]);
        await git.ExecuteAsync(directory, ["config", "rebase.updateRefs", "true"]);
        var tree = (await git.ExecuteAsync(directory, ["rev-parse", "HEAD^{tree}"])).Text;
        var plan = await service.PrepareSquashAsync(directory, selected);
        Assert(plan.Message == before[3].Subject + " | " + before[2].Subject);
        Assert(plan.FollowingCount == 2);
        var message = "feat: 压缩提交\nbody $() `literal` 'quoted'\nCo-authored-by: Other <other@example.com>";
        var result = await service.SquashAsync(directory, plan, message);
        var after = await service.HistoryAsync(directory);
        Assert(after.Length == before.Length - 1);
        Assert(after[2].Hash == result && after[2].Message.TrimEnd('\r', '\n') == message);
        Assert(after[0].Message == before[0].Message && after[1].Message == before[1].Message);
        Assert((await git.ExecuteAsync(directory, ["rev-parse", "HEAD^{tree}"])).Text == tree);
        Assert((await git.ExecuteAsync(directory, ["rev-parse", "refs/heads/keep"])).Text.Trim() == before[2].Hash);
        Assert((await git.ExecuteAsync(directory, ["status", "--porcelain"])).Text.Length == 0);
        Assert((await git.ExecuteAsync(directory, ["for-each-ref", "refs/foldgit/squash-backups"])).Text.Length == 0);
        Assert(!File.Exists(Path.Combine(directory, ".git", "foldgit-squash.json")));
        var root = await service.PrepareSquashAsync(directory, after.Select(commit => commit.Hash).ToHashSet());
        await service.SquashAsync(directory, root, "one\ntwo\nthree");
        var final = await service.HistoryAsync(directory);
        Assert(final.Length == 1 && final[0].Parents.Length == 0 && final[0].Message.TrimEnd('\r', '\n') == "one\ntwo\nthree");
        Assert(final[0].Subject == "one");
        var detail = await service.GetCommitAsync(directory, "HEAD");
        Assert(detail.Subject == "one" && detail.Message.TrimEnd('\r', '\n') == "one\ntwo\nthree");
    });
    await Test("Commit and squash messages store Windows text box line breaks as LF", async () =>
    {
        var directory = await Repository("line endings");
        await File.WriteAllTextAsync(Path.Combine(directory, "file.txt"), "one");
        await service.StageAllAsync(directory, true);
        await service.CommitAsync(directory, "feat: first\r\rbody\r\nmore", false);
        var first = (await git.ExecuteAsync(directory, ["log", "-1", "--format=%B"])).Text;
        Assert(!first.Contains('\r') && first.TrimEnd('\n') == "feat: first\n\nbody\nmore");
        await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "second"]);
        var commits = await service.HistoryAsync(directory);
        var plan = await service.PrepareSquashAsync(directory, commits.Select(commit => commit.Hash).ToHashSet());
        await service.SquashAsync(directory, plan, "squashed\r\rbody");
        var raw = (await git.ExecuteAsync(directory, ["log", "-1", "--format=%B"])).Text;
        Assert(!raw.Contains('\r') && raw.TrimEnd('\n') == "squashed\n\nbody");
    });
    await Test("Squash recovery reports a corrupt journal as needing attention", async () =>
    {
        var directory = await Repository("squash journal");
        for (var index = 0; index < 2; index++) await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "commit " + index]);
        var commits = await service.HistoryAsync(directory);
        var journal = Path.Combine(directory, ".git", "foldgit-squash.json");
        await File.WriteAllTextAsync(journal, "{");
        await Throws(async () => await service.PrepareSquashAsync(directory, commits.Select(commit => commit.Hash).ToHashSet()));
        await Throws(async () => await service.RecoverSquashAsync(directory));
        Assert(File.Exists(journal));
        File.Delete(journal);
        await service.RecoverSquashAsync(directory);
    });
    await Test("Squash rejects gaps, foreign commits, dirty worktrees, stale plans and unavailable remotes", async () =>
    {
        var directory = await Repository("squash rejected");
        for (var index = 0; index < 3; index++) await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "commit " + index]);
        var before = await service.HistoryAsync(directory);
        await Throws(async () => await service.PrepareSquashAsync(directory, new HashSet<string> { before[0].Hash, before[2].Hash }));
        var selected = new HashSet<string> { before[0].Hash, before[1].Hash };
        await File.WriteAllTextAsync(Path.Combine(directory, "untracked.txt"), "keep");
        await Throws(async () => await service.PrepareSquashAsync(directory, selected));
        File.Delete(Path.Combine(directory, "untracked.txt"));
        var plan = await service.PrepareSquashAsync(directory, selected);
        var indexLock = Path.Combine(directory, ".git", "index.lock");
        await File.WriteAllTextAsync(indexLock, "");
        await Throws(async () => await service.PrepareSquashAsync(directory, selected));
        await Throws(async () => await service.SquashAsync(directory, plan, "combined"));
        Assert(File.Exists(indexLock));
        Assert((await git.ExecuteAsync(directory, ["rev-parse", "HEAD"])).Text.Trim() == plan.Head);
        Assert((await git.ExecuteAsync(directory, ["for-each-ref", "refs/foldgit/squash-backups"])).Text.Length == 0);
        File.Delete(indexLock);
        await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "agent change"]);
        await Throws(async () => await service.SquashAsync(directory, plan, "combined"));
        await git.ExecuteAsync(directory, ["checkout", "--detach"]);
        await Throws(async () => await service.PrepareSquashAsync(directory, selected));
        await git.ExecuteAsync(directory, ["switch", "main"]);
        await git.ExecuteAsync(directory, ["remote", "add", "offline", Path.Combine(directory, "missing.git")]);
        await Throws(async () => await service.PrepareSquashAsync(directory, selected));
    });
    await Test("Squash checks all remote branches and tags and rechecks publication before execution", async () =>
    {
        var directory = await Repository("squash remote");
        var remote = await Repository("squash published");
        await git.ExecuteAsync(remote, ["config", "receive.denyCurrentBranch", "ignore"]);
        await git.ExecuteAsync(directory, ["remote", "add", "origin", remote]);
        await git.ExecuteAsync(directory, ["config", "remote.origin.fetch", "+refs/heads/missing:refs/remotes/origin/missing"]);
        await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "base"]);
        await git.ExecuteAsync(directory, ["push", "origin", "HEAD:refs/heads/topic"]);
        await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "one\n\nbody"]);
        await git.ExecuteAsync(directory, ["commit", "--allow-empty", "-m", "two"]);
        var commits = await service.HistoryAsync(directory);
        var selected = new HashSet<string> { commits[0].Hash, commits[1].Hash };
        var plan = await service.PrepareSquashAsync(directory, selected);
        Assert(plan.Message == "one | two");
        await git.ExecuteAsync(directory, ["push", "origin", "HEAD:refs/heads/topic"]);
        await Throws(async () => await service.SquashAsync(directory, plan, plan.Message));
        await git.ExecuteAsync(directory, ["push", "origin", ":refs/heads/topic"]);
        await git.ExecuteAsync(directory, ["push", "origin", "HEAD:refs/tags/published"]);
        await Throws(async () => await service.PrepareSquashAsync(directory, selected));
        Assert((await git.ExecuteAsync(directory, ["for-each-ref", "refs/foldgit/squash-check"])).Text.Length == 0);
    });
    await Test("Commit time modes, elapsed boundaries, localization and time zones", () =>
    {
        var now = DateTimeOffset.Parse("2024-11-04T00:00:00Z");
        var english = new TextCatalog("en");
        foreach (var (age, exact) in new[] { (0d, false), (604799d, false), (604800d, true), (604801d, true), (-1d, true) })
        {
            var date = now.AddSeconds(-age);
            var hybrid = CommitTimeFormatter.Format(date, CommitTimeDisplayMode.Hybrid, now, english, TimeZoneInfo.Utc);
            Assert(hybrid.IsAbsolute == exact);
            Assert(CommitTimeFormatter.Format(date, CommitTimeDisplayMode.Absolute, now, english, TimeZoneInfo.Utc).IsAbsolute);
            Assert(!CommitTimeFormatter.Format(date, CommitTimeDisplayMode.Relative, now, english, TimeZoneInfo.Utc).IsAbsolute);
            Assert(hybrid.Tooltip.EndsWith("UTC+00:00"));
        }
        Assert(CommitTimeFormatter.Format(now, CommitTimeDisplayMode.Relative, now, english, TimeZoneInfo.Utc).Text == "Just now");
        Assert(CommitTimeFormatter.Format(now.AddHours(-1), CommitTimeDisplayMode.Relative, now, english, TimeZoneInfo.Utc).Text == "1 hour ago");
        Assert(CommitTimeFormatter.Format(now.AddHours(1), CommitTimeDisplayMode.Relative, now, english, TimeZoneInfo.Utc).Text == "in 1 hour");
        foreach (var language in TextCatalog.Languages)
        {
            var catalog = new TextCatalog(language);
            foreach (var age in new[] { 10d, 120, 7200, 3 * 86400, 60 * 86400, 400 * 86400 })
                foreach (var direction in new[] { -1, 1 })
                {
                    var text = CommitTimeFormatter.Format(now.AddSeconds(direction * age), CommitTimeDisplayMode.Relative, now, catalog, TimeZoneInfo.Utc).Text;
                    Assert(text.Length > 0 && !text.Contains('%'));
                }
        }
        Assert(CommitTimeFormatter.Format(now.AddHours(-1), CommitTimeDisplayMode.Relative, now, new("zh-Hans"), TimeZoneInfo.Utc).Text == "1 小时前");
        var shanghai = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
        Assert(CommitTimeFormatter.Format(DateTimeOffset.Parse("2021-01-01T00:00:00Z"), CommitTimeDisplayMode.Absolute, now, new("zh-Hans"), shanghai).Text == "2021-01-01 08:00:00");
        var pacific = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var before = DateTimeOffset.Parse("2024-03-10T09:59:59Z");
        Assert(CommitTimeFormatter.Format(before, CommitTimeDisplayMode.Absolute, now, english, pacific).Tooltip == "2024-03-10 01:59:59 UTC-08:00");
        Assert(CommitTimeFormatter.Format(before.AddSeconds(1), CommitTimeDisplayMode.Absolute, now, english, pacific).Tooltip == "2024-03-10 03:00:00 UTC-07:00");
        Assert(CommitTimeFormatter.Format(now.AddDays(-7), CommitTimeDisplayMode.Hybrid, now, english, pacific).IsAbsolute);
        foreach (var (mode, identifier) in new[] { (CommitTimeDisplayMode.Relative, "relative"), (CommitTimeDisplayMode.Absolute, "absolute"), (CommitTimeDisplayMode.Hybrid, "hybrid") })
        {
            Assert(JsonSerializer.Serialize(mode) == "\"" + identifier + "\"");
            Assert(JsonSerializer.Deserialize<CommitTimeDisplayMode>("\"" + identifier + "\"") == mode);
        }
        return Task.CompletedTask;
    });
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
        var prose = Diff.Parse("diff --git a/notes.txt b/notes.txt\nindex 1111111..2222222 100644\n--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-old\n+Binary files are mentioned here\n").Files.Single();
        Assert(!prose.Binary && prose.Additions == 1, "Hunk text that mentions binary files must stay text.");
        var image = Diff.Parse("diff --git a/image.png b/image.png\nindex 1111111..2222222 100644\nBinary files a/image.png and b/image.png differ\n").Files.Single();
        Assert(image.Binary && image.Path == "image.png", "The binary header must still mark binary changes.");
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
            Assert(text.GetErrorMessage("fatal: remote repository is unavailable\nDetails from Git.") == "fatal: remote repository is unavailable\nDetails from Git.");
            Assert(text.GetErrorMessage("The Git index is locked. Wait for other Git operations to finish. If the lock remains, check for an interrupted Git process.")
                == text.Get("The Git index is locked. Wait for other Git operations to finish. If the lock remains, check for an interrupted Git process."));
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
