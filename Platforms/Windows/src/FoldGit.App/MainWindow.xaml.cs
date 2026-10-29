using System.ComponentModel;
using FoldGit.App.ViewModels;
using FoldGit.App.Controls;
using FoldGit.Core.Git;
using FoldGit.Core.History;
using FoldGit.Core.Workspace;
using FoldGit.Platform.Windows;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;

namespace FoldGit.App;

public sealed partial class MainWindow : Window
{
    public WorkbenchViewModel Model { get; }
    private bool initialized;
    private bool composingSearch;
    private bool closingApproved;
    private bool closeWhenIdle;
    private bool updatingSelection;
    private bool loadingMore;
    private double stagedPaneHeight = 180;
    private string[] historySelection = [];
    private readonly ListView TagList = new();
    private readonly ListView StashList = new();
    private string[] draggedRepositories = [];
    private readonly SemaphoreSlim dialogs = new(1, 1);
    private string L(string key) => Model.Text.Get(key);

    public MainWindow()
    {
        InitializeComponent();
        Title = "FoldGit";
        ExtendsContentIntoTitleBar = true; SetTitleBar(TitleRegion);
        SystemBackdrop = new MicaBackdrop();
        Model = new(DispatchAsync);
        Root.DataContext = Model;
        BranchList.ItemsSource = Model.LocalBranches; RemoteBranchList.ItemsSource = Model.RemoteBranches; WorktreeList.ItemsSource = Model.Worktrees;
        Model.ResourcesChanged += ApplyResources;
        Model.PropertyChanged += ModelChanged;
        Model.HistoryChanging += () => { historySelection = HistoryList.SelectedItems.OfType<GraphCommit>().Select(row => row.Commit.Hash).ToArray(); updatingSelection = true; };
        Model.HistoryChanged += () =>
        {
            foreach (var row in Model.History.Where(row => historySelection.Contains(row.Commit.Hash))) HistoryList.SelectedItems.Add(row);
            updatingSelection = false;
            if (historySelection.Length > 0 && HistoryList.SelectedItems.Count == 0) Model.ClearSelection();
            UpdateRepositoryControls();
        };
        Root.Loaded += async (_, _) =>
        {
            if (initialized) return;
            initialized = true;
            await Model.RunAsync(Model.InitializeAsync);
#if FOLDGIT_CLOUD_DEBUG
            var demoRepository = Environment.GetEnvironmentVariable("FOLDGIT_DEBUG_REPOSITORY");
            if (Model.GitAvailable && demoRepository is not null && Directory.Exists(demoRepository))
                await Model.RunAsync(() => Model.ImportAsync(demoRepository));
#endif
            var scale = Root.XamlRoot.RasterizationScale;
            var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
            AppWindow.Resize(new(Math.Min(workArea.Width, Math.Max((int)Math.Ceiling(1050 * scale), Model.Settings.WindowWidth)),
                Math.Min(workArea.Height, Math.Max((int)Math.Ceiling(650 * scale), Model.Settings.WindowHeight))));
            AppWindow.Move(new(Math.Clamp(AppWindow.Position.X, workArea.X, workArea.X + workArea.Width - AppWindow.Size.Width),
                Math.Clamp(AppWindow.Position.Y, workArea.Y, workArea.Y + workArea.Height - AppWindow.Size.Height)));
            AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "FoldGit.ico"));
            if (!Model.GitAvailable) await ShowGitSetupAsync();
        };
        CommitSearch.Loaded += (_, _) =>
        {
            if (VisualChild<TextBox>(CommitSearch) is not { } editor) return;
            editor.TextCompositionStarted += (_, _) => composingSearch = true;
            editor.TextCompositionEnded += async (_, _) => { composingSearch = false; await Model.RunAsync(() => Model.SearchAsync(CommitSearch.Text)); };
        };
        AppWindow.Closing += async (_, args) =>
        {
            if (closingApproved) return;
            args.Cancel = true;
            if (Model.Busy) { closeWhenIdle = true; return; }
            await Model.RunAsync(async () =>
            {
                await Model.UpdateSettingsAsync(Model.Settings with { WindowWidth = AppWindow.Size.Width, WindowHeight = AppWindow.Size.Height });
                await Model.DisposeAsync(); closingApproved = true; Close();
            });
        };
        Shortcut(VirtualKey.O, VirtualKeyModifiers.Control, AddAsync);
        Shortcut(VirtualKey.F5, VirtualKeyModifiers.None, Model.RefreshAsync);
        Shortcut(VirtualKey.Enter, VirtualKeyModifiers.Control, () => Model.ViewingChanges ? Model.CommitAsync() : Task.CompletedTask);
        Shortcut((VirtualKey)188, VirtualKeyModifiers.Control, ShowSettingsAsync);
        Shortcut(VirtualKey.F, VirtualKeyModifiers.Control, () => { CommitSearch.Focus(FocusState.Keyboard); return Task.CompletedTask; });
        Shortcut(VirtualKey.B, VirtualKeyModifiers.Control, () => { SidebarColumn.Width = SidebarColumn.Width.Value == 0 ? new(260) : new(0); return Task.CompletedTask; });
        UnstagedDiffContent.UseParentScrollViewer();
        Root.ActualThemeChanged += (_, _) => RenderDetail();

    }
    private Task DispatchAsync(Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!DispatcherQueue.TryEnqueue(() => { action(); completion.SetResult(); })) completion.SetCanceled();
        return completion.Task;
    }
    private static T? VisualChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match) return match;
            if (VisualChild<T>(child) is { } nested) return nested;
        }
        return null;
    }
    private void Shortcut(VirtualKey key, VirtualKeyModifiers modifiers, Func<Task> action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += async (_, args) => { args.Handled = true; await Model.RunAsync(action); };
        Root.KeyboardAccelerators.Add(accelerator);
    }
    private void ApplyResources()
    {
        Root.RequestedTheme = Model.Settings.Appearance switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        foreach (var (item, key) in new (MenuFlyoutItem, string)[] { (AddButton, "Add"), (CloneButton, "Clone"), (RefreshButton, "Refresh"), (TagsButton, "Tags"), (StashesButton, "Stashed Changes"), (CompareButton, "Compare Branches or Tags") }) item.Text = L(key);
        foreach (var (button, key) in new (Button, string)[] { (BranchButton, "New Branch"), (MoreButton, "More"), (NewWorktreeButton, "New Worktree"), (PruneButton, "Prune Missing Worktrees"), (ResolveButton, "Resolve Merge"), (CommitButton, "Commit"), (StageAllButton, "Stage All"), (UnstageAllButton, "Unstage All"), (StashButton, "Stash All Changes"), (TemplatesButton, "Commit Message Snippets") }) button.Content = L(key);
        foreach (var (element, key) in new (FrameworkElement, string)[] { (AddMenuButton, "Add"), (FetchButton, "Fetch"), (PullButton, "Pull"), (PushButton, "Push"), (BranchSelector, "Select Branch"), (RepositoryMenuButton, "More"), (OpenButton, "Open in"), (SettingsButton, "Settings"), (WorktreesButton, "Worktrees"), (LayoutButton, "Diff Layout"), (ChangesLayoutButton, "Diff Layout"), (ExpandButton, "Expand All Files"), (ChangesExpandButton, "Expand All Files"), (CollapseButton, "Collapse All Files"), (ChangesCollapseButton, "Collapse All Files") })
        { AutomationProperties.SetName(element, L(key)); ToolTipService.SetToolTip(element, L(key)); }
        RepositoriesHeading.Text = L("Repositories"); BranchesHeading.Text = L("Local Branches"); BranchFilter.PlaceholderText = L("Filter"); RemoteBranchesSection.Header = L("Remote Branches");
        ChangesLabel.Text = L("Uncommitted Changes"); WorkingTreeLabel.Text = L("Working Tree");
        UnstagedHeading.Text = L("Unstaged Changes"); StagedHeading.Text = L("Staged Changes"); EmptySelection.Text = L("No Selection");
        RepositoryFilter.PlaceholderText = L("Filter Repositories"); CommitSearch.PlaceholderText = L("Search Commits");
        CommitSearch.ItemsSource = Model.Settings.SearchHistory;
        MessageEditor.PlaceholderText = L("Commit Message"); AmendToggle.Content = L("Amend");
        AutomationProperties.SetName(MessageEditor, L("Commit Message"));
        AutomationProperties.SetName(RepositoryList, L("Repositories")); AutomationProperties.SetName(HistoryList, L("Commit History"));
        AutomationProperties.SetName(UnstagedDiffContent, L("Unstaged Changes")); AutomationProperties.SetName(StagedDiffContent, L("Staged Changes"));
        UpdateRepositoryControls(); RenderDetail();
    }
    private void UpdateRepositoryControls()
    {
        var enabled = Model.Directory is not null && Model.GitAvailable;
        foreach (var control in new Control[] { BranchSelector, FetchButton, PullButton, PushButton, RepositoryMenuButton }) control.IsEnabled = enabled && !Model.Busy;
        AddMenuButton.IsEnabled = Model.GitAvailable && !Model.Busy;
        OpenButton.IsEnabled = enabled;
        WorktreesButton.Visibility = Model.Settings.WorktreesEnabled && enabled && Model.IsWorktreeEnabled(Model.Directory!) ? Visibility.Visible : Visibility.Collapsed;
        CurrentBranchLabel.Text = Model.Snapshot is { } snapshot ? snapshot.Branch.Length > 0 ? snapshot.Branch : L("Detached HEAD") : L("Branches");
        HistoryCount.Text = Model.Text.Count("%lld commits", Model.History.Count);
        StageAllButton.IsEnabled = !Model.Busy && Model.Snapshot?.Files.Any(file => file.IsUnstaged || file.Conflict) == true;
        UnstageAllButton.IsEnabled = !Model.Busy && Model.Snapshot?.Files.Any(file => file.IsStaged) == true;
        StashButton.IsEnabled = !Model.Busy && Model.Snapshot?.Files.Length > 0;
        CommitButton.IsEnabled = Model.ViewingChanges && !Model.Busy && !string.IsNullOrWhiteSpace(Model.CommitMessage)
            && (Model.Snapshot?.Files.Any(file => file.IsStaged) == true || Model.Amend || Model.Snapshot?.Merging == true);
        MoreButton.IsEnabled = !Model.Busy && Model.HasMoreHistory;
        MoreButton.Visibility = Model.HasMoreHistory ? Visibility.Visible : Visibility.Collapsed;
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(Model.Directory))
        {
            RepositoryList.SelectedItem = Model.Directory is null ? null : Model.RepositoryRows.FirstOrDefault(row => row.Id == WindowsPathIdentity.Get(Model.Directory));
            CommitSearch.Text = ""; BranchFilter.Text = "";
        }
        if (args.PropertyName is nameof(Model.Mode) or nameof(Model.Detail) or nameof(Model.SelectedCommit) or nameof(Model.Snapshot)) RenderDetail();
        if (args.PropertyName == nameof(Model.Snapshot))
        {
            var pending = Model.Settings.PendingCompletions.Any(plan => plan.Target == Model.Directory);
            MergeBanner.IsOpen = Model.Snapshot?.Merging == true || pending;
            MergeBanner.Title = L(Model.Snapshot?.Merging == true ? "Merge in Progress" : "Worktree Finished");
            ResolveButton.Content = L(Model.Snapshot?.Merging == true ? "Resolve Merge" : "Return to Workflow");
        }
        if (args.PropertyName == nameof(Model.Mode) && Model.Mode is WorkbenchMode.None or WorkbenchMode.Changes)
        {
            updatingSelection = true; HistoryList.SelectedItems.Clear(); updatingSelection = false;
        }
        if (args.PropertyName == nameof(Model.Error)) { ErrorBar.Title = L("Error"); ErrorBar.Message = Model.Error; ErrorBar.IsOpen = Model.Error.Length > 0; }
        if (args.PropertyName == nameof(Model.Busy)) Progress.Visibility = Model.Busy ? Visibility.Visible : Visibility.Collapsed;
        if (args.PropertyName == nameof(Model.Busy) && !Model.Busy && closeWhenIdle && !closingApproved)
        { closeWhenIdle = false; DispatcherQueue.TryEnqueue(Close); }
        UpdateRepositoryControls();
    }
    private void ConfigureDiff(DiffViewer viewer, string oldVersion, string newVersion, bool? staging = null)
    {
        viewer.Text = Model.Text; viewer.SideBySide = Model.Settings.SideBySide; viewer.WordWrap = Model.Settings.WordWrap;
        viewer.LineNumbers = Model.Settings.LineNumbers; viewer.FontSizeSetting = Model.Settings.FontSize; viewer.DefaultExpanded = Model.Settings.ExpandFiles;
        viewer.StagingLabel = staging.HasValue ? L(staging.Value ? "Stage This File" : "Unstage This File") : null;
        viewer.StageFile = staging.HasValue ? file => Model.RunAsync(() => Model.MutateAsync((service, directory) => service.StageFileAsync(directory, file, staging.Value))) : null;
        viewer.StageHunk = staging.HasValue && Model.Snapshot?.Files.Any(file => file.Conflict) != true
            ? (file, hunk) => Model.RunAsync(() => Model.MutateAsync((service, directory) => service.StageHunkAsync(directory, file, hunk, staging.Value))) : null;
        viewer.Failed = error => Model.Error = error.Message;
        viewer.OpenFile = path => { if (Model.Directory is not null) ExternalApplications.OpenDefault(Path.Combine(Model.Directory, path)); };
        var repository = Model.Directory;
        viewer.ReadImage = async (file, oldSide) =>
        {
            var version = oldSide ? oldVersion : newVersion;
            if (Model.Repositories is null || repository is null || version == "absent") return null;
            if (oldSide && file.Header.Contains("new file mode ", StringComparison.Ordinal) || !oldSide && file.Header.Contains("deleted file mode ", StringComparison.Ordinal)) return null;
            var blob = oldSide ? file.OldBlob : file.NewBlob;
            if (version is not ("working" or "index") && blob is { Length: 40 or 64 } && blob.Any(character => character != '0'))
                return await Model.Repositories.BlobAsync(repository, blob);
            return await Model.Repositories.FileAsync(repository, oldSide ? file.OldPath ?? file.Path : file.Path, version);
        };
    }
    private void RenderDetail()
    {
        CommitPane.Visibility = Model.ViewingChanges ? Visibility.Visible : Visibility.Collapsed;
        DetailPane.Visibility = Model.Mode is WorkbenchMode.Commit or WorkbenchMode.Comparison ? Visibility.Visible : Visibility.Collapsed;
        EmptySelection.Visibility = Model.Mode == WorkbenchMode.None ? Visibility.Visible : Visibility.Collapsed;
        ChangesButton.BorderBrush = Model.ViewingChanges ? (Brush)Root.Resources["SelectionBrush"] : new SolidColorBrush(Colors.Transparent);
        ConfigureDiff(DiffContent, Model.DetailOldVersion, Model.DetailNewVersion);
        DiffContent.Show(Model.Detail);
        ConfigureDiff(UnstagedDiffContent, "index", "working", true);
        ConfigureDiff(StagedDiffContent, "HEAD", "index", false);
        UnstagedDiffContent.Show(Model.ViewingChanges ? Model.Snapshot?.Unstaged : null);
        StagedDiffContent.Show(Model.ViewingChanges ? Model.Snapshot?.Staged : null);
        UpdateStagedHeight();
        ParentLinks.Children.Clear();
        if (Model.SelectedCommit is { } commit)
        {
            if (Model.CanGoBack)
            {
                var back = new Button { Content = new FontIcon { Glyph = "\uE72B", FontSize = 14 } };
                AutomationProperties.SetName(back, L("Back"));
                back.Click += async (_, _) => await Model.RunAsync(Model.GoBackAsync); ParentLinks.Children.Add(back);
            }
            var hash = new TextBlock { Text = commit.ShortHash, VerticalAlignment = VerticalAlignment.Center, IsTextSelectionEnabled = true };
            ToolTipService.SetToolTip(hash, commit.Hash); ParentLinks.Children.Add(hash);
            foreach (var parent in commit.Parents)
            {
                var link = new HyperlinkButton { Content = "→ " + parent[..Math.Min(8, parent.Length)], Padding = new(4, 0, 4, 0) };
                link.Click += async (_, _) => await Model.RunAsync(() => Model.NavigateToCommitAsync(parent));
                ParentLinks.Children.Add(link);
            }
        }
        DetailStatistics.Text = Model.Detail is { } diff ? $"{diff.Files.Length}   +{diff.Files.Sum(file => file.Additions)}   −{diff.Files.Sum(file => file.Deletions)}" : "";
    }
    private async Task<string?> FolderAsync()
    {
        var picker = new FolderPicker(); picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSingleFolderAsync())?.Path;
    }
    private async Task<string?> FileAsync(string extension)
    {
        var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSingleFileAsync())?.Path;
    }
    private async Task<bool> DialogAsync(string title, UIElement content, string accept = "OK")
    {
        await dialogs.WaitAsync();
        try
        {
            var dialog = new ContentDialog { Title = L(title), Content = content, PrimaryButtonText = L(accept), CloseButtonText = L("Cancel"), DefaultButton = ContentDialogButton.Primary, XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme };
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        finally { dialogs.Release(); }
    }
    private async Task<string?> PromptAsync(string title, string label, string value = "")
    {
        var field = new TextBox { Header = L(label), Text = value, MinWidth = 340 };
        return await DialogAsync(title, field) ? field.Text : null;
    }
    private Task<bool> ConfirmAsync(string title, string message, string action) => DialogAsync(title, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 }, action);
    private async Task AddAsync() { var path = await FolderAsync(); if (path is not null) await Model.ImportAsync(path); }
    private async void AddClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(AddAsync);
    private async void CloneClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        var remote = await PromptAsync("Clone Remote Repository", "Repository Address"); if (remote is null) return;
        var parent = await FolderAsync(); if (parent is null) return;
        var name = await PromptAsync("Clone Remote Repository", "Folder Name", Path.GetFileNameWithoutExtension(remote.TrimEnd('/'))); if (name is null) return;
        if (name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name is "" or "." or "..") throw new InvalidDataException(L("Enter a valid folder name."));
        var destination = Path.Combine(parent, name);
        using var cancellation = new CancellationTokenSource();
        var progress = new ContentDialog { Title = L("Cloning Repository"), Content = new ProgressBar { IsIndeterminate = true, MinWidth = 360 }, CloseButtonText = L("Cancel"), XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme };
        var cloning = Model.Repositories!.CloneAsync(remote, destination, cancellation.Token);
        var showing = progress.ShowAsync().AsTask();
        try
        {
            if (await Task.WhenAny(cloning, showing) == showing) await cancellation.CancelAsync();
            await cloning;
        }
        finally { progress.Hide(); }
        await Model.ImportAsync(destination);
    });
    private async void RefreshClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () => { await Model.RefreshAsync(); await Model.LoadHistoryAsync(); });
    private async void FetchClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => Model.MutateAsync((service, directory) => service.FetchAsync(directory, false)));
    private async void PullClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => Model.MutateAsync((service, directory) => service.PullAsync(directory)));
    private async void PushClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        var branch = Model.Snapshot?.Branches.FirstOrDefault(value => value.Current);
        if (branch is null) throw new GitException(L("No Branches"));
        if (branch.Upstream.Length > 0) { await Model.MutateAsync((service, directory) => service.PushAsync(directory)); return; }
        if (Model.Snapshot!.Remotes.Length == 0) throw new GitException(L("No remote repository is configured."));
        var remote = new ComboBox { Header = L("Remotes"), ItemsSource = Model.Snapshot.Remotes, SelectedIndex = 0, MinWidth = 340 };
        if (await DialogAsync("Push", remote, "Push")) await Model.MutateAsync((service, directory) => service.PushReferenceAsync(directory, (string)remote.SelectedItem, branch.Name));
    });
    private async void StageAllClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => Model.MutateAsync((service, directory) => service.StageAllAsync(directory, true)));
    private async void UnstageAllClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => Model.MutateAsync((service, directory) => service.StageAllAsync(directory, false)));
    private async void CommitClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(Model.CommitAsync);
    private async void StashClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        var message = await PromptAsync("Stash All Changes", "Commit Message");
        if (message is not null) { await Model.MutateAsync((service, directory) => service.StashAsync(directory, message)); Model.ClearSelection(); }
    });
    private async void AmendChanged(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        if (Model.Directory is null || Model.Repositories is null) return;
        Model.CommitMessage = (await Model.Repositories.HistoryAsync(Model.Directory, count: 1)).FirstOrDefault()?.Message ?? "";
    });
    private void ChangesClicked(object sender, RoutedEventArgs args) => Model.ShowChanges();
    private async void UntrackedClicked(object sender, ItemClickEventArgs args) => await Model.RunAsync(() => Model.MutateAsync((service, directory) => service.StagePathsAsync(directory, [((FileStatus)args.ClickedItem).Path], true)));
    private async void RepositorySelected(object sender, SelectionChangedEventArgs args)
    {
        if (RepositoryList.SelectedItems.Count != 1 || RepositoryList.SelectedItem is not RepositoryRow { Path: { } path } || path == Model.Directory) return;
        await Model.RunAsync(() => Model.SelectRepositoryAsync(path));
    }
    private async void CommitSelected(object sender, SelectionChangedEventArgs args)
    {
        if (updatingSelection) return;
        var rows = HistoryList.SelectedItems.OfType<GraphCommit>().ToArray();
        if (rows.Length == 1) await Model.RunAsync(() => Model.ShowCommitAsync(rows[0].Commit));
        else if (rows.Length == 2)
        {
            var ordered = rows.OrderBy(row => Model.History.IndexOf(row)).ToArray();
            await Model.RunAsync(() => Model.ShowComparisonAsync(ordered[1].Commit.Hash, ordered[0].Commit.Hash));
        }
    }
    private void HistoryLoaded(object sender, RoutedEventArgs args)
    {
        if (VisualChild<ScrollViewer>(HistoryList) is { } scroll) scroll.ViewChanged += HistoryScrolled;
    }
    private async void HistoryScrolled(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        if (sender is not ScrollViewer scroll || args.IsIntermediate || loadingMore || Model.Busy || !Model.HasMoreHistory || scroll.ScrollableHeight <= 0
            || scroll.VerticalOffset < scroll.ScrollableHeight - 160) return;
        loadingMore = true;
        try { await Model.RunAsync(() => Model.LoadHistoryAsync(true)); }
        finally { loadingMore = false; }
    }
    private void UpdateStagedHeight() => StagedRow.Height = new(Model.Snapshot?.Staged.Files.Length > 0
        ? Math.Clamp(stagedPaneHeight, 72, Math.Max(72, CommitPane.ActualHeight - 260)) : 44);
    private void CommitPaneResized(object sender, SizeChangedEventArgs args) => UpdateStagedHeight();
    private void StagedResized(object sender, DragDeltaEventArgs args)
    {
        if (Model.Snapshot?.Staged.Files.Length is not > 0) return;
        stagedPaneHeight = Math.Clamp(StagedRow.ActualHeight - args.VerticalChange, 72, Math.Max(72, CommitPane.ActualHeight - 260));
        UpdateStagedHeight();
    }
    private void ChangesCommandsResized(object sender, SizeChangedEventArgs args)
    {
        var narrow = args.NewSize.Width < 620;
        Grid.SetRow(StagingActions, narrow ? 1 : 0); Grid.SetColumn(StagingActions, narrow ? 0 : 1); Grid.SetColumnSpan(StagingActions, narrow ? 2 : 1);
    }
    private void StagedSizeReset(object sender, DoubleTappedRoutedEventArgs args) { stagedPaneHeight = 180; UpdateStagedHeight(); }
    private void BranchFilterChanged(object sender, TextChangedEventArgs args) => Model.FilterBranches(BranchFilter.Text);
    private void FilterChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) { Model.Filter = sender.Text; Model.RebuildRepositories(); }
    private async void SearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (!composingSearch && args.Reason == AutoSuggestionBoxTextChangeReason.UserInput && args.CheckCurrent()) await Model.RunAsync(() => Model.SearchAsync(sender.Text));
    }
    private async void SearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args) => await Model.RunAsync(Model.RememberSearchAsync);
    private async void SearchChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args) => await Model.RunAsync(() => Model.SearchAsync((string)args.SelectedItem));
    private async void MoreClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => Model.LoadHistoryAsync(true));
    private void HistoryResized(object sender, DragDeltaEventArgs args) => HistoryColumn.Width = new(Math.Clamp(HistoryColumn.ActualWidth + args.HorizontalChange, 320, 640));
    private async void LayoutClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => Model.UpdateSettingsAsync(Model.Settings with { SideBySide = !Model.Settings.SideBySide }));
    private void ExpandClicked(object sender, RoutedEventArgs args) { DiffContent.ExpandAll(true); UnstagedDiffContent.ExpandAll(true); StagedDiffContent.ExpandAll(true); }
    private void CollapseClicked(object sender, RoutedEventArgs args) { DiffContent.ExpandAll(false); UnstagedDiffContent.ExpandAll(false); StagedDiffContent.ExpandAll(false); }
    private async Task CreateBranchAsync(string revision)
    {
        BranchesFlyout.Hide();
        if (Model.Directory is null) return;
        var name = await PromptAsync("New Branch", "New Branch Name");
        if (name is not null) await Model.MutateAsync((service, directory) => service.CreateBranchAsync(directory, name, revision, true));
    }
    private async void BranchClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(() => CreateBranchAsync("HEAD"));
    private async Task CreateTagAsync(string revision)
    {
        var name = new TextBox { Header = L("New tag name"), MinWidth = 340 };
        var push = new CheckBox { Content = L("Create & Push"), IsEnabled = Model.Snapshot?.Remotes.Length > 0 };
        var remote = new ComboBox { Header = L("Remotes"), ItemsSource = Model.Snapshot?.Remotes, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(name); panel.Children.Add(push); panel.Children.Add(remote);
        if (!await DialogAsync("New Tag", panel, "Create")) return;
        await Model.MutateAsync(async (service, directory) =>
        {
            await service.TagAsync(directory, name.Text, revision);
            if (push.IsChecked == true) await service.PushTagAsync(directory, (string)remote.SelectedItem, name.Text);
        });
    }
    private async void CompareClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        if (Model.Directory is null || Model.Repositories is null) return;
        var references = new[] { "HEAD" }.Concat(Model.Branches.Select(branch => branch.Name)).Concat(Model.Tags).ToArray();
        var left = new ComboBox { Header = L("Base"), ItemsSource = references, SelectedIndex = 0, IsEditable = true, MinWidth = 340 };
        var right = new ComboBox { Header = L("Compare"), ItemsSource = references, SelectedIndex = 0, IsEditable = true, MinWidth = 340 };
        var working = new CheckBox { Content = L("Working Tree") };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(left); panel.Children.Add(right); panel.Children.Add(working);
        if (!await DialogAsync("Compare Branches or Tags", panel, "Compare")) return;
        var from = left.Text; var to = working.IsChecked == true ? null : right.Text;
        await Model.ShowComparisonAsync(from, to);
    });
    private async void BranchSelected(object sender, ItemClickEventArgs args) => await Model.RunAsync(async () =>
    {
        BranchesFlyout.Hide();
        var branch = (Branch)args.ClickedItem;
        if (Model.Directory is null || Model.Trees is null) return;
        var trees = await Model.Trees.ListAsync(Model.Directory);
        var occupied = Model.IsWorktreeEnabled(Model.Directory) ? trees.FirstOrDefault(tree => tree.Branch == branch.Name) : null;
        if (occupied is not null) await Model.SelectRepositoryAsync(occupied.Path);
        else if (branch.Remote) await Model.MutateAsync((service, directory) => service.SwitchAsync(directory, branch.Name, true));
        else await Model.MutateAsync((service, directory) => service.SwitchAsync(directory, branch.Name));
    });
    private async void WorktreeSelected(object sender, ItemClickEventArgs args)
    {
        WorktreesFlyout.Hide();
        await Model.RunAsync(() => Model.SelectRepositoryAsync(((Worktree)args.ClickedItem).Path));
    }
    private async void SettingsClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(ShowSettingsAsync);
    private MenuFlyoutItem Menu(string key, Func<Task> action)
    {
        var item = new MenuFlyoutItem { Text = L(key) }; item.Click += async (_, _) => await Model.RunAsync(action); return item;
    }
    private static T? ItemAt<T>(RightTappedRoutedEventArgs args) where T : class =>
        (args.OriginalSource as FrameworkElement)?.DataContext as T;
    private void ShowMenu(MenuFlyout menu, RightTappedRoutedEventArgs args, FrameworkElement target) { menu.ShowAt(target, args.GetPosition(target)); args.Handled = true; }
    private void CommitRightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<GraphCommit>(args) is not { } row) return;
        var menu = new MenuFlyout();
        menu.Items.Add(Menu("New Branch", () => CreateBranchAsync(row.Commit.Hash)));
        menu.Items.Add(Menu("New Tag", () => CreateTagAsync(row.Commit.Hash)));
        var copy = new MenuFlyoutItem { Text = Model.Text.Get("Copy %@", row.Commit.ShortHash) };
        copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(row.Commit.Hash); Clipboard.SetContent(data); }; menu.Items.Add(copy);
        menu.Items.Add(Menu("Checkout", () => Model.MutateAsync((service, directory) => service.SwitchAsync(directory, row.Commit.Hash, true))));
        menu.Items.Add(Menu("Revert", async () =>
        {
            int? mainline = null;
            if (row.Commit.Parents.Length > 1)
            {
                var choice = await PromptAsync("Revert", "Base", "1"); if (choice is null) return;
                mainline = int.Parse(choice);
            }
            if (await ConfirmAsync("Revert", row.Commit.Subject, "Revert")) await Model.MutateAsync((service, directory) => service.RevertAsync(directory, row.Commit.Hash, mainline));
        }));
        ShowMenu(menu, args, HistoryList);
    }
    private void BranchRightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<Branch>(args) is not { } branch) return;
        var menu = new MenuFlyout();
        menu.Items.Add(Menu("New Branch", () => CreateBranchAsync(branch.Hash)));
        if (!branch.Remote) menu.Items.Add(Menu("Rename Branch", async () => { BranchesFlyout.Hide(); var name = await PromptAsync("Rename Branch", "New Branch Name", branch.Name); if (name is not null) await Model.MutateAsync((service, directory) => service.RenameBranchAsync(directory, branch.Name, name)); }));
        menu.Items.Add(Menu("Delete", async () => { BranchesFlyout.Hide(); if (await ConfirmAsync("Delete", branch.Name, "Delete")) await Model.MutateAsync((service, directory) => service.DeleteBranchAsync(directory, branch.Name, branch.Remote)); }));
        menu.Items.Add(Menu("Merge", async () =>
        {
            BranchesFlyout.Hide();
            if (await ConfirmAsync("Merge", branch.Name, "Merge"))
            {
                try { await Model.MutateAsync((service, directory) => service.ActionAsync(directory, ["merge", "--no-edit", "--", branch.Hash])); }
                finally { await Model.RefreshAsync(); }
            }
        }));
        ShowMenu(menu, args, (FrameworkElement)sender);
    }
    private void FileMenu(ListView list, bool staged, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<FileStatus>(args) is not { } file) return;
        var paths = list.SelectedItems.OfType<FileStatus>().SelectMany(value => new[] { value.OriginalPath, value.Path }).Where(value => value is not null).Select(value => value!).Distinct().ToArray();
        if (!paths.Contains(file.Path)) paths = new[] { file.OriginalPath, file.Path }.Where(value => value is not null).Select(value => value!).ToArray();
        var menu = new MenuFlyout();
        menu.Items.Add(Menu(staged ? "Unstage This File" : "Stage This File", () => Model.MutateAsync((service, directory) => service.StagePathsAsync(directory, paths, !staged))));
        menu.Items.Add(Menu("Open File", () => { ExternalApplications.OpenDefault(Path.Combine(Model.Directory!, file.Path)); return Task.CompletedTask; }));
        ShowMenu(menu, args, list);
    }
    private void UnstagedRightTapped(object sender, RightTappedRoutedEventArgs args) => FileMenu(UnstagedList, false, args);
    private void RepositoryDragStarting(object sender, DragItemsStartingEventArgs args)
    {
        draggedRepositories = args.Items.OfType<RepositoryRow>().Where(row => !row.Group).Select(row => row.Id).ToArray();
        args.Data.SetText(string.Join('\n', draggedRepositories)); args.Data.RequestedOperation = DataPackageOperation.Move;
    }
    private void RepositoryDragOver(object sender, DragEventArgs args) => args.AcceptedOperation = args.DataView.Contains(StandardDataFormats.StorageItems) ? DataPackageOperation.Copy : DataPackageOperation.Move;
    private async void RepositoryDrop(object sender, DragEventArgs args) => await Model.RunAsync(async () =>
    {
        var deferral = args.GetDeferral();
        try
        {
            if (args.DataView.Contains(StandardDataFormats.StorageItems))
                foreach (var item in await args.DataView.GetStorageItemsAsync()) { if (item is StorageFolder) await Model.ImportAsync(item.Path); }
            else if (draggedRepositories.Length > 0)
            {
                var row = (args.OriginalSource as FrameworkElement)?.DataContext as RepositoryRow;
                var workspace = Model.Settings.Workspace;
                if (row is { Group: true }) workspace = workspace with { Repositories = workspace.Repositories.Select(repository => draggedRepositories.Contains(repository.Id) ? repository with { GroupId = row.Id } : repository).ToArray() };
                else workspace = workspace.Move(draggedRepositories, row is null ? workspace.Repositories.Length : Array.FindIndex(workspace.Repositories, repository => repository.Id == row.Id));
                await Model.UpdateSettingsAsync(Model.Settings with { Workspace = workspace });
            }
        }
        finally { deferral.Complete(); draggedRepositories = []; }
    });
}
