using FoldGit.App.ViewModels;
using FoldGit.Core.Git;
using FoldGit.Core.History;
using System.Text.Json;
using FoldGit.Platform.Windows;

var root = Path.Combine(Path.GetTempPath(), "FoldGit-workbench-" + Guid.NewGuid());
Directory.CreateDirectory(root);
var gitPath = GitInstallation.Locate(Environment.GetEnvironmentVariable("FOLDGIT_GIT")) ?? throw new InvalidOperationException("Git is required.");
var git = new GitProcess(gitPath);
var store = new SettingsStore(Path.Combine(root, "settings"));
await store.SaveAsync(new AppSettings { GitPath = gitPath, Language = "en", RestoreSession = false });
// Watcher notifications are intentionally queued outside this deterministic navigation scenario.
var model = new WorkbenchViewModel(_ => Task.CompletedTask, store);
await model.InitializeAsync();
void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
var passed = 0;
async Task Test(string name, Func<Task> body)
{
    await body(); Console.WriteLine("PASS " + name); passed++;
}
async Task<string> CreateRepository(string name)
{
    var directory = Path.Combine(root, name); Directory.CreateDirectory(directory);
    await git.ExecuteAsync(directory, ["init", "--initial-branch=main"]);
    await git.ExecuteAsync(directory, ["config", "user.name", "FoldGit Workbench Tests"]);
    await git.ExecuteAsync(directory, ["config", "user.email", "tests@example.com"]);
    await git.ExecuteAsync(directory, ["config", "commit.gpgsign", "false"]);
    await git.ExecuteAsync(directory, ["config", "core.autocrlf", "false"]);
    await File.WriteAllTextAsync(Path.Combine(directory, "tracked.txt"), "first\n");
    await git.ExecuteAsync(directory, ["add", "--all"]);
    await git.ExecuteAsync(directory, ["commit", "-m", "first"]);
    await File.WriteAllTextAsync(Path.Combine(directory, "tracked.txt"), "second\n");
    await git.ExecuteAsync(directory, ["commit", "-am", "second"]);
    return directory;
}
try
{
    await Test("Commit time settings upgrade, persistence and reset", async () =>
    {
        Assert(JsonSerializer.Deserialize<AppSettings>("{\"Version\":1}")!.CommitTimeDisplayMode == CommitTimeDisplayMode.Hybrid,
            "Existing settings should default to hybrid.");
        foreach (var mode in Enum.GetValues<CommitTimeDisplayMode>())
        {
            await model.UpdateSettingsAsync(model.Settings with { CommitTimeDisplayMode = mode });
            Assert((await store.LoadAsync()).CommitTimeDisplayMode == mode, "Time mode should survive reloading settings.");
        }
        await model.UpdateSettingsAsync(model.Settings with { CommitTimeDisplayMode = CommitTimeDisplayMode.Absolute });
        await model.ResetAsync();
        Assert(model.Settings.CommitTimeDisplayMode == CommitTimeDisplayMode.Hybrid, "Reset should restore hybrid mode.");
    });
    var repository = await CreateRepository("first");
    await Test("Time mode changes refresh the selected commit without reloading its diff", async () =>
    {
        await model.SelectRepositoryAsync(repository);
        await model.ShowCommitAsync(model.History[0].Commit);
        var row = model.History[0];
        var commit = model.SelectedCommit!;
        var diff = model.Detail;
        await model.UpdateSettingsAsync(model.Settings with { CommitTimeDisplayMode = CommitTimeDisplayMode.Absolute });
        Assert(model.DetailCommitTime.Length == 19 && model.DetailCommitTime[4] == '-', "Absolute time should use the fixed format.");
        Assert(row.Time.Text == model.DetailCommitTime && row.Time.Tooltip == model.DetailCommitTimeTooltip, "History and detail metadata should use the same time display.");
        Assert(model.DetailTitle == commit.Message.TrimEnd(), "Author metadata should be separate from the original commit message.");
        var tooltip = model.DetailCommitTimeTooltip;
        await model.UpdateSettingsAsync(model.Settings with { CommitTimeDisplayMode = CommitTimeDisplayMode.Relative });
        Assert(model.DetailCommitTime.Length > 0 && model.DetailCommitTimeTooltip == tooltip, "Relative mode should keep the exact tooltip.");
        Assert(model.SelectedCommit == commit && ReferenceEquals(model.Detail, diff), "Time changes should preserve the current selection and diff.");
        Assert(ReferenceEquals(model.History[0], row), "Time changes should update the existing history row without rebuilding selection or graph data.");
        var timeUpdates = 0;
        row.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(row.Time)) timeUpdates++; };
        model.RefreshCommitTime(commit.Date.AddHours(2));
        Assert(model.DetailCommitTime == "2 hours ago", "Clock refresh should update relative text.");
        Assert(row.Time.Text == "2 hours ago" && timeUpdates == 1, "Clock refresh should notify the visible history metadata.");
        await model.UpdateSettingsAsync(model.Settings with { CommitTimeDisplayMode = CommitTimeDisplayMode.Hybrid });
        model.RefreshCommitTime(commit.Date.AddDays(7));
        Assert(model.DetailCommitTime.Length == 19, "Hybrid should switch to an absolute time at seven days.");
        model.ShowChanges();
        Assert(model.DetailCommitTime.Length == 0 && model.DetailCommitTimeTooltip.Length == 0, "Other views must not retain commit timestamps.");
        model.RefreshCommitTime(commit.Date.AddHours(3));
        Assert(row.Time.Text == "3 hours ago", "History timestamps should keep updating while another workspace view is active.");
    });
    await Test("Repository opens without implicitly entering the commit editor", async () =>
    {
        await model.SelectRepositoryAsync(repository);
        Assert(model.Mode == WorkbenchMode.None && model.Detail is null, "Opening a repository must leave detail unselected.");
    });
    await Test("History and changes are exclusive and stale details cannot replace changes", async () =>
    {
        var loading = model.ShowCommitAsync(model.History[0].Commit);
        Assert(model.Mode == WorkbenchMode.Commit, "Selection must change before loading finishes.");
        model.ShowChanges();
        await model.RunAsync(() => loading);
        Assert(model.Mode == WorkbenchMode.Changes && model.Detail is null && model.SelectedCommit is null, "Canceled history details overwrote the commit workspace.");
        model.CommitMessage = "draft message";
        await model.ShowCommitAsync(model.History[0].Commit);
        Assert(!model.ViewingChanges && model.CommitMessage == "draft message", "Viewing history must hide the editor and preserve its draft.");
    });
    await Test("Parent navigation can return to the original commit", async () =>
    {
        var original = model.SelectedCommit!;
        await model.NavigateToCommitAsync(original.Parents[0]);
        Assert(model.CanGoBack && model.SelectedCommit!.Hash == original.Parents[0], "Parent navigation lost its return path.");
        await model.GoBackAsync();
        Assert(!model.CanGoBack && model.SelectedCommit!.Hash == original.Hash, "Back did not return to the selected commit.");
    });
    await Test("Staging updates both panes without changing the active workspace", async () =>
    {
        await File.WriteAllTextAsync(Path.Combine(repository, "tracked.txt"), "third\n");
        await File.WriteAllTextAsync(Path.Combine(repository, "new.txt"), "untracked\n");
        await model.RefreshAsync(); model.ShowChanges();
        await model.MutateAsync((service, directory) => service.StagePathsAsync(directory, ["tracked.txt"], true));
        Assert(model.ViewingChanges && model.Snapshot!.Staged.Files.Single().Path == "tracked.txt" && model.Untracked.Single().Path == "new.txt", "Staging must retain the workspace and both current snapshots.");
        await model.MutateAsync((service, directory) => service.StagePathsAsync(directory, ["tracked.txt"], false));
        Assert(model.ViewingChanges && model.Snapshot!.Staged.Files.Length == 0 && model.Snapshot.Unstaged.Files.Single().Path == "tracked.txt", "Unstaging did not move the diff back to the unstaged pane.");
    });
    await Test("History comparison and refresh preserve their selection", async () =>
    {
        await model.ShowComparisonAsync(model.History[1].Commit.Hash, model.History[0].Commit.Hash);
        var detail = model.Detail;
        await model.MutateAsync((service, directory) => service.StagePathsAsync(directory, ["new.txt"], true));
        Assert(model.Mode == WorkbenchMode.Comparison && ReferenceEquals(detail, model.Detail), "An unrelated write forced the selection into the commit workspace.");
    });
    await Test("Commit finishes with no detail selection while keeping unstaged work", async () =>
    {
        model.ShowChanges(); model.CommitMessage = "commit staged new file";
        await model.CommitAsync();
        Assert(model.Mode == WorkbenchMode.None && model.CommitMessage.Length == 0 && model.Staged.Count == 0 && model.Unstaged.Any(file => file.Path == "tracked.txt"), "Commit completion must clear the selection and retain unstaged work.");
        var head = model.Snapshot!.Head;
        model.CommitMessage = "hidden draft";
        await model.CommitAsync();
        Assert(model.Snapshot.Head == head, "A hidden editor must not commit.");
    });
    await Test("Switching repositories cancels details and resets drafts", async () =>
    {
        var other = await CreateRepository("second");
        var loading = model.ShowCommitAsync(model.History[0].Commit);
        await model.SelectRepositoryAsync(other);
        await model.RunAsync(() => loading);
        Assert(model.Directory == other && model.Mode == WorkbenchMode.None && model.Detail is null && model.CommitMessage.Length == 0, "The old repository leaked selection or draft into the new repository.");
    });
    Console.WriteLine($"Passed {passed} workbench workflow suites.");
}
finally
{
    await model.DisposeAsync();
    foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
    Directory.Delete(root, true);
}
