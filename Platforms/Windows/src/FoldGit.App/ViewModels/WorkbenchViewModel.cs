using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using FoldGit.Core.Git;
using FoldGit.Core.History;
using FoldGit.Core.Resources;
using FoldGit.Core.Workspace;
using FoldGit.Platform.Windows;

namespace FoldGit.App.ViewModels;

public sealed partial class WorkbenchViewModel : ObservableObject, IAsyncDisposable
{
    private readonly SettingsStore store;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Dictionary<string, DateTimeOffset> lastFetch = new(StringComparer.Ordinal);
    private HashSet<string> enabledWorktreePaths = [];
    private readonly Func<Action, Task> dispatch;
    private RepositoryMonitor? monitor;
    private CancellationTokenSource? historyRequest;
    private CancellationTokenSource? detailRequest;
    private Task? scheduler;
    private int repositoryGeneration;
    private int historyGeneration;
    private int operations;
    private string branchQuery = "";
    private readonly Stack<Commit> parentTrail = new();
    public bool CanGoBack => parentTrail.Count > 0;
    public AppSettings Settings { get; private set; } = new();
    public TextCatalog Text { get; private set; } = new("automatic");
    public RepositoryService? Repositories { get; private set; }
    public WorktreeService? Trees { get; private set; }
    public ObservableCollection<RepositoryRow> RepositoryRows { get; } = [];
    public ObservableCollection<GraphCommit> History { get; } = [];
    public ObservableCollection<Branch> Branches { get; } = [];
    public ObservableCollection<Branch> LocalBranches { get; } = [];
    public ObservableCollection<Branch> RemoteBranches { get; } = [];
    public ObservableCollection<string> Tags { get; } = [];
    public ObservableCollection<Stash> Stashes { get; } = [];
    public ObservableCollection<Worktree> Worktrees { get; } = [];
    public ObservableCollection<FileStatus> Staged { get; } = [];
    public ObservableCollection<FileStatus> Unstaged { get; } = [];
    public ObservableCollection<FileStatus> Untracked { get; } = [];
    [ObservableProperty] public partial string? Directory { get; set; }
    [ObservableProperty] public partial RepositorySnapshot? Snapshot { get; set; }
    [ObservableProperty] public partial Diff? Detail { get; set; }
    [ObservableProperty] public partial string DetailTitle { get; set; } = "";
    [ObservableProperty] public partial string CommitMessage { get; set; } = "";
    [ObservableProperty] public partial bool Amend { get; set; }
    [ObservableProperty] public partial bool Busy { get; set; }
    [ObservableProperty] public partial string Error { get; set; } = "";
    [ObservableProperty] public partial string Status { get; set; } = "";
    [ObservableProperty] public partial string Search { get; set; } = "";
    [ObservableProperty] public partial string Filter { get; set; } = "";
    [ObservableProperty] public partial bool GitAvailable { get; set; }
    [ObservableProperty] public partial bool HasMoreHistory { get; private set; } = true;
    [ObservableProperty] public partial WorkbenchMode Mode { get; private set; }
    [ObservableProperty] public partial Commit? SelectedCommit { get; private set; }
    public bool ViewingChanges => Mode == WorkbenchMode.Changes;
    public string DetailOldVersion { get; internal set; } = "HEAD";
    public string DetailNewVersion { get; internal set; } = "working";
    public event Action? ResourcesChanged;
    public event Action? RepositoriesChanged;
    public event Action? HistoryChanging;
    public event Action? HistoryChanged;

    public WorkbenchViewModel(Func<Action, Task> dispatch, SettingsStore? settingsStore = null)
    {
        this.dispatch = dispatch;
        store = settingsStore ?? new();
    }
    public async Task InitializeAsync()
    {
        Settings = await store.LoadAsync();
        Text = new(Settings.Language);
        ResourcesChanged?.Invoke();
        await ConfigureGitAsync();
        RebuildRepositories();
        if (Settings.RestoreSession && Settings.SelectedRepository is not null && System.IO.Directory.Exists(Settings.SelectedRepository) && GitAvailable)
            await SelectRepositoryAsync(Settings.SelectedRepository);
        scheduler = AutoFetchAsync();
    }
    public async Task ConfigureGitAsync()
    {
        var executable = GitInstallation.Locate(Settings.GitPath);
        GitAvailable = executable is not null;
        if (executable is null) { Repositories = null; Trees = null; Status = Text.Get("Git was not found. Install Git for Windows or choose git.exe."); return; }
        Status = await GitInstallation.ValidateAsync(executable);
        var process = new GitProcess(executable, WindowsPathIdentity.Get);
        Repositories = new(process); Trees = new(process);
    }
    public async Task UpdateSettingsAsync(AppSettings settings)
    {
        var gitChanged = Settings.GitPath != settings.GitPath;
        Settings = settings;
        await store.SaveAsync(Settings);
        if (gitChanged) await ConfigureGitAsync();
        RebuildRepositories();
        ResourcesChanged?.Invoke();
    }
    public Task SaveAsync() => store.SaveAsync(Settings);
    public async Task ResetAsync()
    {
        await store.ResetAsync();
        await UpdateSettingsAsync(new AppSettings { Workspace = Settings.Workspace, SelectedRepository = Settings.SelectedRepository, GitPath = Settings.GitPath });
    }
    public async Task ImportAsync(string path)
    {
        if (Repositories is null) return;
        var paths = new List<string>();
        if (File.Exists(Path.Combine(path, ".git")) || System.IO.Directory.Exists(Path.Combine(path, ".git"))) paths.Add(path);
        else paths.AddRange(System.IO.Directory.EnumerateDirectories(path).Where(child =>
            File.Exists(Path.Combine(child, ".git")) || System.IO.Directory.Exists(Path.Combine(child, ".git"))));
        if (paths.Count == 0) throw new GitException(Text.Get("Please add a folder that contains a Git repository."));
        var workspace = Settings.Workspace;
        var group = paths.Count > 1 ? new WorkspaceGroup(Guid.NewGuid().ToString(), Path.GetFileName(path)) : null;
        if (group is not null) workspace = workspace with { Groups = [.. workspace.Groups, group] };
        foreach (var candidate in paths)
        {
            var top = Path.GetFullPath((await Repositories.Process.ExecuteAsync(candidate, ["rev-parse", "--show-toplevel"])).Text.TrimEnd('\r', '\n'));
            workspace = workspace.Add(top, WindowsPathIdentity.Get(top), group?.Id);
        }
        await UpdateSettingsAsync(Settings with { Workspace = workspace });
        await SelectRepositoryAsync(paths[0]);
    }
    public async Task SelectRepositoryAsync(string path)
    {
        path = Path.GetFullPath(path);
        var generation = ++repositoryGeneration;
        historyRequest?.Cancel(); detailRequest?.Cancel();
        if (monitor is not null) { await monitor.DisposeAsync(); monitor = null; }
        ClearSelection();
        Directory = path; CommitMessage = ""; Amend = false; Search = ""; branchQuery = ""; Snapshot = null;
        History.Clear(); Branches.Clear(); Tags.Clear(); Stashes.Clear(); Worktrees.Clear(); Staged.Clear(); Unstaged.Clear(); Untracked.Clear();
        Settings = Settings with
        {
            SelectedRepository = Settings.RestoreSession ? path : null,
            Workspace = Settings.Workspace with { Repositories = Settings.Workspace.Repositories.Select(repository => WindowsPathIdentity.Get(path) == repository.Id ? repository with { Opened = DateTimeOffset.UtcNow } : repository).ToArray() }
        };
        await SaveAsync();
        await RefreshAsync(); await LoadHistoryAsync();
        if (generation != repositoryGeneration || Repositories is null) return;
        monitor = await RepositoryMonitor.CreateAsync(Repositories.Process, path,
            () => dispatch(() => _ = RunAsync(RefreshAsync)), exception => _ = dispatch(() => Error = exception.Message));
    }
    public Task RelocateAsync(string oldPath, string newPath) => UpdateSettingsAsync(Settings with
    {
        Workspace = Settings.Workspace with { Repositories = Settings.Workspace.Repositories.Select(repository => repository.Path == oldPath ? repository with { Path = newPath, Id = WindowsPathIdentity.Get(newPath) } : repository).ToArray() },
        SelectedRepository = Settings.SelectedRepository == oldPath ? newPath : Settings.SelectedRepository,
        PendingCompletions = Settings.PendingCompletions.Select(plan => plan with { Source = plan.Source == oldPath ? newPath : plan.Source, Target = plan.Target == oldPath ? newPath : plan.Target }).ToArray()
    });
    public async Task RefreshAsync()
    {
        var directory = Directory; var repositories = Repositories;
        if (directory is null || repositories is null) return;
        var generation = repositoryGeneration;
        await refreshGate.WaitAsync(lifetime.Token);
        try
        {
            var snapshot = await repositories.SnapshotAsync(directory, lifetime.Token);
            var family = Settings.WorktreesEnabled ? await Trees!.ListAsync(directory, lifetime.Token) : [];
            var identities = family.Select(tree => WindowsPathIdentity.Get(tree.Path)).ToHashSet();
            var worktreeEnabled = Settings.WorktreesEnabled && Settings.Workspace.Repositories.Any(repository => repository.WorktreesEnabled && identities.Contains(repository.Id));
            var trees = worktreeEnabled ? family : [];
            if (generation != repositoryGeneration) return;
            enabledWorktreePaths = worktreeEnabled ? identities : [];
            var previousHead = Snapshot?.Head;
            Snapshot = snapshot;
            Replace(Branches, snapshot.Branches); Replace(Tags, snapshot.Tags); Replace(Stashes, snapshot.Stashes); Replace(Worktrees, trees);
            Replace(Staged, snapshot.Files.Where(file => file.IsStaged)); Replace(Unstaged, snapshot.Files.Where(file => file.IsUnstaged || file.Conflict));
            Replace(Untracked, snapshot.Files.Where(file => file.IsUntracked));
            FilterBranches(branchQuery);
            RebuildRepositories();
            Status = (snapshot.Branch.Length > 0 ? snapshot.Branch : Text.Get("Detached HEAD")) + $"   ↑ {snapshot.Ahead}   ↓ {snapshot.Behind}";
            if (CommitMessage.Length == 0 && snapshot.Merging) CommitMessage = snapshot.MergeMessage;
            if (previousHead is not null && previousHead != snapshot.Head) await LoadHistoryAsync();
        }
        finally { refreshGate.Release(); }
    }
    public void FilterBranches(string query)
    {
        branchQuery = query;
        var visible = Branches.Where(branch => branch.Name.Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        Replace(LocalBranches, visible.Where(branch => !branch.Remote));
        Replace(RemoteBranches, visible.Where(branch => branch.Remote));
    }
    public bool IsWorktreeEnabled(string path)
    {
        var identity = WindowsPathIdentity.Get(path);
        if (Settings.Workspace.Repositories.Any(repository => repository.Id == identity && repository.WorktreesEnabled)) return true;
        return enabledWorktreePaths.Contains(identity);
    }
    public async Task LoadHistoryAsync(bool more = false)
    {
        if (Directory is null || Repositories is null) return;
        historyRequest?.Cancel(); historyRequest?.Dispose();
        historyRequest = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var token = historyRequest.Token; var generation = ++historyGeneration;
        var directory = Directory; var repositories = Repositories; var search = Search; var skip = more ? History.Count : 0;
        var commits = await Task.Run(() => repositories.HistoryAsync(directory, skip, 100, search, token), token);
        if (generation != historyGeneration) return;
        var all = more ? History.Select(row => row.Commit).Concat(commits).ToArray() : commits;
        HasMoreHistory = commits.Length == 100;
        HistoryChanging?.Invoke();
        Replace(History, CommitGraph.Layout(all));
        HistoryChanged?.Invoke();
    }
    public async Task SearchAsync(string text)
    {
        Search = text;
        historyRequest?.Cancel();
        var generation = ++historyGeneration;
        await Task.Delay(300, lifetime.Token);
        if (generation != historyGeneration) return;
        await LoadHistoryAsync();
    }
    public async Task RememberSearchAsync()
    {
        if (Search.Length == 0) return;
        Settings = Settings with { SearchHistory = new[] { Search }.Concat(Settings.SearchHistory).Distinct(StringComparer.Ordinal).Take(30).ToArray() };
        await SaveAsync();
    }
    private CancellationToken BeginDetail(WorkbenchMode mode)
    {
        detailRequest?.Cancel(); detailRequest?.Dispose();
        detailRequest = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        SelectedCommit = null; Detail = null; DetailTitle = "";
        Mode = mode;
        return detailRequest.Token;
    }
    public void ClearSelection()
    {
        detailRequest?.Cancel();
        parentTrail.Clear();
        SelectedCommit = null; Detail = null; DetailTitle = ""; Mode = WorkbenchMode.None;
    }
    public async Task ShowCommitAsync(Commit commit)
    {
        if (Repositories is null || Directory is null) return;
        parentTrail.Clear();
        var token = BeginDetail(WorkbenchMode.Commit);
        await LoadCommitDetailAsync(commit, token);
    }
    public async Task NavigateToCommitAsync(string hash)
    {
        if (Repositories is null || Directory is null) return;
        var previous = SelectedCommit;
        var token = BeginDetail(WorkbenchMode.Commit);
        var commit = await Repositories.GetCommitAsync(Directory, hash, token);
        if (token.IsCancellationRequested) return;
        if (previous is not null) parentTrail.Push(previous);
        await LoadCommitDetailAsync(commit, token);
    }
    public async Task GoBackAsync()
    {
        if (!parentTrail.TryPop(out var commit)) return;
        var token = BeginDetail(WorkbenchMode.Commit);
        await LoadCommitDetailAsync(commit, token);
    }
    private async Task LoadCommitDetailAsync(Commit commit, CancellationToken token)
    {
        if (Repositories is null || Directory is null) return;
        SelectedCommit = commit;
        DetailOldVersion = commit.Parents.FirstOrDefault() ?? "absent";
        DetailNewVersion = commit.Hash;
        DetailTitle = commit.Message.TrimEnd() + "\n\n" + commit.Author + " <" + commit.Email + "> · " + commit.Date.ToLocalTime().ToString("g");
        var diff = await Repositories.CommitDiffAsync(Directory, commit, token);
        if (!token.IsCancellationRequested) Detail = diff;
    }
    public void ShowChanges()
    {
        parentTrail.Clear();
        BeginDetail(WorkbenchMode.Changes);
    }
    public async Task ShowComparisonAsync(string from, string? to)
    {
        if (Repositories is null || Directory is null) return;
        parentTrail.Clear();
        var token = BeginDetail(WorkbenchMode.Comparison);
        DetailOldVersion = from; DetailNewVersion = to ?? "working";
        DetailTitle = from + " → " + (to ?? Text.Get("Working Tree"));
        var diff = await Repositories.CompareAsync(Directory, from, to, token);
        if (!token.IsCancellationRequested) Detail = diff;
    }
    public async Task CommitAsync()
    {
        if (!ViewingChanges || Directory is null || Repositories is null) return;
        await Repositories.CommitAsync(Directory, CommitMessage, Amend, lifetime.Token);
        CommitMessage = ""; Amend = false;
        await RefreshAsync(); await LoadHistoryAsync(); ClearSelection();
    }
    public async Task MutateAsync(Func<RepositoryService, string, Task> action)
    {
        if (Repositories is null || Directory is null) return;
        await action(Repositories, Directory); await RefreshAsync();
    }
    public async Task RunAsync(Func<Task> action)
    {
        Busy = ++operations > 0; Error = "";
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception exception) { Error = exception.Message; }
        finally { Busy = --operations > 0; }
    }
    public void RebuildRepositories()
    {
        var result = new List<RepositoryRow>();
        var visible = Settings.Workspace.Visible(Filter, Settings.Sort);
        foreach (var group in Settings.Workspace.Groups)
        {
            var members = visible.Where(repository => repository.GroupId == group.Id).ToArray();
            if (members.Length == 0) continue;
            result.Add(new(group.Name, null, group.Id, true, false));
            result.AddRange(members.Select(repository => new RepositoryRow(repository.Name, repository.Path, repository.Id, false, repository.Infrequent, repository.Infrequent ? Text.Get("Inactive") : "")));
        }
        result.AddRange(visible.Where(repository => repository.GroupId is null).Select(repository => new RepositoryRow(repository.Name, repository.Path, repository.Id, false, repository.Infrequent, repository.Infrequent ? Text.Get("Inactive") : "")));
        if (Settings.WorktreesEnabled && Worktrees.Count > 0)
        {
            var saved = Settings.Workspace.Repositories.Select(repository => repository.Id).ToHashSet();
            var anchor = result.FindIndex(row => !row.Group && enabledWorktreePaths.Contains(row.Id));
            if (anchor >= 0)
                result.InsertRange(anchor + 1, Worktrees.Where(tree => !saved.Contains(WindowsPathIdentity.Get(tree.Path)))
                    .Select(tree => new RepositoryRow("  " + Path.GetFileName(tree.Path), tree.Path, WindowsPathIdentity.Get(tree.Path), false, false, tree.Branch ?? Text.Get("Detached HEAD"), true)));
        }
        if (!RepositoryRows.SequenceEqual(result)) { Replace(RepositoryRows, result); RepositoriesChanged?.Invoke(); }
    }
    private async Task AutoFetchAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(30));
        try
        {
            while (await timer.WaitForNextTickAsync(lifetime.Token))
            {
                foreach (var repository in Settings.Workspace.Repositories.Where(repository => repository.AutoFetchMinutes > 0))
                {
                    if (Repositories is null || !System.IO.Directory.Exists(repository.Path)) continue;
                    if (lastFetch.TryGetValue(repository.Id, out var success) && DateTimeOffset.UtcNow - success < TimeSpan.FromMinutes(repository.AutoFetchMinutes)) continue;
                    try
                    {
                        await Repositories.FetchAsync(repository.Path, true, lifetime.Token);
                        lastFetch[repository.Id] = DateTimeOffset.UtcNow;
                        if (Directory == repository.Path) await dispatch(() => _ = RunAsync(RefreshAsync));
                    }
                    catch (GitException exception) { await dispatch(() => Status = Text.Get("Sync Error") + ": " + exception.Message); }
                }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    private static void Replace<T>(ObservableCollection<T> collection, IEnumerable<T> values)
    {
        collection.Clear(); foreach (var value in values) collection.Add(value);
    }
    public async ValueTask DisposeAsync()
    {
        historyRequest?.Cancel(); detailRequest?.Cancel();
        await lifetime.CancelAsync();
        if (monitor is not null) await monitor.DisposeAsync();
        if (scheduler is not null) await scheduler;
        historyRequest?.Dispose(); detailRequest?.Dispose(); lifetime.Dispose();
        await SaveAsync();
    }
}

public sealed record RepositoryRow(string Name, string? Path, string Id, bool Group, bool Infrequent, string State = "", bool Linked = false)
{
    public string Glyph => Linked ? "\uE8A5" : Group ? "\uE8B7" : "\uE943";
}

public enum WorkbenchMode { None, Changes, Commit, Comparison }
