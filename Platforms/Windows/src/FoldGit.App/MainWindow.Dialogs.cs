using System.Text;
using FoldGit.Core.Git;
using FoldGit.Core.Resources;
using FoldGit.Core.Workspace;
using FoldGit.Platform.Windows;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel;

namespace FoldGit.App;

public sealed partial class MainWindow
{
    private void RepositoryRightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<ViewModels.RepositoryRow>(args) is not { } row) return;
        var selected = RepositoryList.SelectedItems.OfType<ViewModels.RepositoryRow>().Where(value => !value.Group).Select(value => value.Id).ToArray();
        if (!selected.Contains(row.Id)) selected = row.Group ? Model.Settings.Workspace.Repositories.Where(repository => repository.GroupId == row.Id).Select(repository => repository.Id).ToArray() : [row.Id];
        var menu = new MenuFlyout();
        menu.Items.Add(Menu(row.Group ? "Rename Group" : "Rename Repository", async () =>
        {
            var name = await PromptAsync(row.Group ? "Rename Group" : "Rename Repository", "Name", row.Name); if (name is null) return;
            var workspace = Model.Settings.Workspace;
            workspace = row.Group ? workspace with { Groups = workspace.Groups.Select(group => group.Id == row.Id ? group with { Name = name } : group).ToArray() }
                : workspace with { Repositories = workspace.Repositories.Select(repository => repository.Id == row.Id ? repository with { Name = name.Length > 0 ? name : Path.GetFileName(repository.Path) } : repository).ToArray() };
            await Model.UpdateSettingsAsync(Model.Settings with { Workspace = workspace });
        }));
        menu.Items.Add(Menu("New Group with Selection", async () =>
        {
            var name = await PromptAsync("New Group", "Group Name");
            if (!string.IsNullOrWhiteSpace(name)) await Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace.Group(selected, name) });
        }));
        if (row.Group)
        {
            menu.Items.Add(Menu("Manage Group", async () =>
            {
                var list = new ListView { ItemsSource = Model.Settings.Workspace.Repositories, DisplayMemberPath = "Name", SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 400, MinWidth = 380 };
                foreach (var repository in Model.Settings.Workspace.Repositories.Where(repository => repository.GroupId == row.Id)) list.SelectedItems.Add(repository);
                if (await DialogAsync("Manage Group", list, "Save"))
                {
                    var members = list.SelectedItems.OfType<RepositoryEntry>().Select(repository => repository.Id).ToHashSet();
                    await Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Select(repository => members.Contains(repository.Id) ? repository with { GroupId = row.Id } : repository.GroupId == row.Id ? repository with { GroupId = null } : repository).ToArray() } });
                }
            }));
            menu.Items.Add(Menu("Dissolve Group", () => Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace.Dissolve(row.Id) })));
        }
        else
        {
            var groups = new MenuFlyoutSubItem { Text = L("Move to Group") };
            foreach (var group in Model.Settings.Workspace.Groups)
            {
                var item = new MenuFlyoutItem { Text = group.Name };
                item.Click += async (_, _) => await Model.RunAsync(() => Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Select(repository => selected.Contains(repository.Id) ? repository with { GroupId = group.Id } : repository).ToArray() } })); groups.Items.Add(item);
            }
            groups.Items.Add(Menu("Ungrouped", () => Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Select(repository => selected.Contains(repository.Id) ? repository with { GroupId = null } : repository).ToArray() } })));
            menu.Items.Add(groups);
            menu.Items.Add(Menu(row.Infrequent ? "Mark as Active" : "Mark as Inactive", () => Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Select(repository => selected.Contains(repository.Id) ? repository with { Infrequent = !row.Infrequent } : repository).ToArray() } })));
            menu.Items.Add(Menu("Show in Finder", () => { ExternalApplications.Reveal(row.Path!); return Task.CompletedTask; }));
            if (Model.Settings.WorktreesEnabled)
            {
                menu.Items.Add(Menu("Enable Worktrees", async () =>
                {
                    var trees = await Model.Trees!.ListAsync(row.Path!);
                    var family = trees.Select(tree => WindowsPathIdentity.Get(tree.Path)).ToHashSet();
                    var enabled = !Model.Settings.Workspace.Repositories.Any(repository => family.Contains(repository.Id) && repository.WorktreesEnabled);
                    await Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Select(repository => family.Contains(repository.Id) ? repository with { WorktreesEnabled = enabled } : repository).ToArray() } });
                    await Model.RefreshAsync();
                }));
            }
            var fetch = new MenuFlyoutSubItem { Text = L("Automatic Fetch") };
            foreach (var minutes in new[] { 0, 5, 10, 30, 60, 1440 })
            {
                var label = minutes switch { 0 => "Off", 1440 => "Every 24 Hours", _ => "Every " + minutes + " Minutes" };
                fetch.Items.Add(Menu(label, () => Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Select(repository => selected.Contains(repository.Id) ? repository with { AutoFetchMinutes = minutes } : repository).ToArray() } })));
            }
            menu.Items.Add(fetch);
            menu.Items.Add(Menu("Remove from Sidebar", async () =>
            {
                await Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Where(repository => !selected.Contains(repository.Id)).ToArray() } });
            }));
        }
        var sorting = new MenuFlyoutSubItem { Text = L("Sort Repositories") };
        foreach (var (sort, key) in new[] { (WorkspaceSort.Manual, "Manual Order"), (WorkspaceSort.Name, "Name"), (WorkspaceSort.LastOpened, "Recently Opened"), (WorkspaceSort.LastModified, "Recently Modified"), (WorkspaceSort.Added, "Recently Added") })
            sorting.Items.Add(Menu(key, () => Model.UpdateSettingsAsync(Model.Settings with { Sort = sort })));
        menu.Items.Add(sorting);
        ShowMenu(menu, args, RepositoryList);
    }
    private async Task ShowGitSetupAsync()
    {
        var panel = new StackPanel { Spacing = 12, MaxWidth = 460 };
        panel.Children.Add(new TextBlock { Text = L("Git was not found. Install Git for Windows or choose git.exe."), TextWrapping = TextWrapping.Wrap });
        var install = new HyperlinkButton { Content = L("Install Git"), NavigateUri = new Uri("https://git-scm.com/install/windows") }; panel.Children.Add(install);
        if (await DialogAsync("Git Installation", panel, "Choose Git"))
        {
            var executable = await FileAsync(".exe");
            if (executable is not null) { await GitInstallation.ValidateAsync(executable); await Model.UpdateSettingsAsync(Model.Settings with { GitPath = executable }); }
        }
    }
    private async void NewWorktreeClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        if (Model.Directory is null || Model.Trees is null) return;
        var parent = await FolderAsync(); if (parent is null) return;
        var occupied = (await Model.Trees.ListAsync(Model.Directory)).Select(tree => tree.Branch).ToHashSet();
        var available = Model.Branches.Where(branch => !branch.Remote && !occupied.Contains(branch.Name)).Select(branch => branch.Name).ToArray();
        var name = new TextBox { Header = L("Folder Name"), MinWidth = 360 };
        var branch = new ComboBox { Header = L("Branch"), Text = "feature/", IsEditable = true, ItemsSource = available, HorizontalAlignment = HorizontalAlignment.Stretch };
        var start = new TextBox { Header = L("Start Point"), Text = "HEAD" };
        var mode = new ComboBox { Header = L("Worktree"), ItemsSource = new[] { L("New Branch"), L("Existing Branch"), L("Detached HEAD") }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        mode.SelectionChanged += (_, _) =>
        {
            branch.IsEnabled = mode.SelectedIndex != 2; branch.IsEditable = mode.SelectedIndex == 0;
            if (mode.SelectedIndex == 1 && available.Length > 0) branch.SelectedIndex = 0;
            else if (mode.SelectedIndex == 0) branch.Text = "feature/";
        };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(name); panel.Children.Add(mode); panel.Children.Add(branch); panel.Children.Add(start);
        if (!await DialogAsync("New Worktree", panel, "Create")) return;
        if (name.Text.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Text is "" or "." or "..") throw new InvalidDataException(L("Enter a valid folder name."));
        await Model.Trees.AddAsync(Model.Directory, Path.Combine(parent, name.Text), mode.SelectedIndex switch { 0 => WorktreeBranchMode.New, 1 => WorktreeBranchMode.Existing, _ => WorktreeBranchMode.Detached }, branch.Text, start.Text);
        await Model.RefreshAsync();
    });
    private async void PruneClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        if (Model.Directory is not null && Model.Trees is not null) { await Model.Trees.ChangeAsync(Model.Directory, "prune"); await Model.RefreshAsync(); }
    });
    private void WorktreeRightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<Worktree>(args) is not { } tree) return;
        var menu = new MenuFlyout();
        menu.Items.Add(Menu("Open Worktree", () => Model.SelectRepositoryAsync(tree.Path)));
        if (!tree.Main)
        {
            menu.Items.Add(Menu(tree.Locked is null ? "Lock Worktree" : "Unlock Worktree", async () => { await Model.Trees!.ChangeAsync(Model.Directory!, tree.Locked is null ? "lock" : "unlock", tree.Path); await Model.RefreshAsync(); }));
            menu.Items.Add(Menu("Move Worktree", async () =>
            {
                var parent = await FolderAsync(); if (parent is null) return;
                var destination = Path.Combine(parent, Path.GetFileName(tree.Path));
                var selected = WindowsPathIdentity.Get(Model.Directory!) == WindowsPathIdentity.Get(tree.Path);
                await Model.Trees!.ChangeAsync(Model.Directory!, "move", tree.Path, destination);
                await Model.RelocateAsync(tree.Path, destination);
                if (selected) await Model.SelectRepositoryAsync(destination); else await Model.RefreshAsync();
            }));
            menu.Items.Add(Menu("Remove Worktree", async () =>
            {
                if (await ConfirmAsync("Remove Worktree?", Model.Text.Get("This removes the folder at %@. The branch is kept. Git refuses removal if the worktree has uncommitted changes or untracked files.", tree.Path), "Remove"))
                {
                    var main = Model.Worktrees.First(value => value.Main).Path;
                    var identity = WindowsPathIdentity.Get(tree.Path);
                    var selected = WindowsPathIdentity.Get(Model.Directory!) == identity;
                    await Model.Trees!.ChangeAsync(main, "remove", tree.Path);
                    await Model.UpdateSettingsAsync(Model.Settings with { Workspace = Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Where(repository => repository.Id != identity).ToArray() } });
                    if (selected) await Model.SelectRepositoryAsync(main); else await Model.RefreshAsync();
                }
            }));
            if (tree.Branch is not null) menu.Items.Add(Menu("Finish Worktree", () => FinishWorktreeAsync(tree.Path)));
        }
        ShowMenu(menu, args, WorktreeList);
    }
    private async Task FinishWorktreeAsync(string source)
    {
        if (Model.Trees is null || Model.Repositories is null) return;
        var pending = Model.Settings.PendingCompletions.FirstOrDefault(plan => plan.Source == source);
        CompletionPlan plan;
        if (pending is not null)
        {
            plan = pending;
            var pendingState = await Model.Trees.MergeStateAsync(plan.Target);
            if (!pendingState.Merging && Directory.Exists(source))
            {
                var integrated = await Model.Repositories.Process.ExecuteAsync(plan.Target, ["merge-base", "--is-ancestor", plan.SourceCommit, "refs/heads/" + plan.TargetBranch], acceptedExitCodes: [0, 1]);
                if (integrated.ExitCode != 0)
                {
                    var refreshed = await Model.Trees.PrepareAsync(source, plan.TargetBranch);
                    if (refreshed != plan)
                    {
                        if (!await ConfirmAsync("Finish Worktree", refreshed.SourceBranch + " → " + refreshed.TargetBranch + "\n" + Model.Text.Count("%lld commits", refreshed.CommitCount), "Review")) return;
                        await Model.UpdateSettingsAsync(Model.Settings with { PendingCompletions = Model.Settings.PendingCompletions.Select(value => value == plan ? refreshed : value).ToArray() });
                        plan = refreshed;
                    }
                }
            }
        }
        else
        {
            var snapshot = await Model.Repositories.SnapshotAsync(source);
            var branches = snapshot.Branches.Where(branch => !branch.Remote && branch.Name != snapshot.Branch).Select(branch => branch.Name).ToArray();
            var target = new ComboBox { Header = L("Target Branch"), ItemsSource = branches, SelectedIndex = 0, MinWidth = 360 };
            if (!await DialogAsync("Finish Worktree", target, "Review") || target.SelectedItem is not string name) return;
            plan = await Model.Trees.PrepareAsync(source, name);
            var preview = new TextBlock { Text = plan.SourceBranch + " → " + plan.TargetBranch + "\n" + Model.Text.Count("%lld commits", plan.CommitCount) + "\n" + plan.Target, TextWrapping = TextWrapping.Wrap, MaxWidth = 480 };
            if (!await DialogAsync("Finish Worktree", preview, "Merge into Target")) return;
            await Model.UpdateSettingsAsync(Model.Settings with { PendingCompletions = [.. Model.Settings.PendingCompletions, plan] });
        }
        var state = await Model.Trees.MergeStateAsync(plan.Target);
        if (state.Merging) await ResolveMergeAsync(plan.Target);
        else
        {
            var integrated = await Model.Repositories.Process.ExecuteAsync(plan.Target, ["merge-base", "--is-ancestor", plan.SourceCommit, "refs/heads/" + plan.TargetBranch], acceptedExitCodes: [0, 1]);
            if (integrated.ExitCode != 0)
            {
                var result = await Model.Trees.MergeAsync(plan);
                if (!result.Complete) await ResolveMergeAsync(plan.Target);
            }
        }
        state = await Model.Trees.MergeStateAsync(plan.Target);
        if (state.Merging) { await Model.SelectRepositoryAsync(plan.Target); return; }
        var remove = new CheckBox { Content = L("Remove Worktree Folder"), IsChecked = false };
        var delete = new CheckBox { Content = L("Delete Local Source Branch"), IsChecked = false };
        var cleanup = new StackPanel { Spacing = 12 }; cleanup.Children.Add(new TextBlock { Text = L("Only a clean, unlocked worktree whose commits are merged can be removed. Remote branches are kept."), TextWrapping = TextWrapping.Wrap, MaxWidth = 450 }); cleanup.Children.Add(remove); cleanup.Children.Add(delete);
        if (!await DialogAsync("Cleanup Options", cleanup, "Finish Cleanup")) return;
        await Model.Trees.CleanupAsync(plan, remove.IsChecked == true, delete.IsChecked == true);
        await Model.UpdateSettingsAsync(Model.Settings with
        {
            PendingCompletions = Model.Settings.PendingCompletions.Where(value => value != plan).ToArray(),
            Workspace = remove.IsChecked == true ? Model.Settings.Workspace with { Repositories = Model.Settings.Workspace.Repositories.Where(repository => repository.Path != plan.Source).ToArray() } : Model.Settings.Workspace
        });
        await Model.SelectRepositoryAsync(plan.Target);
    }
    private async void ResolveClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        if (Model.Directory is null) return;
        if (Model.Snapshot?.Merging == true) await ResolveMergeAsync(Model.Directory);
        else if (Model.Settings.PendingCompletions.FirstOrDefault(plan => plan.Target == Model.Directory) is { } plan) await FinishWorktreeAsync(plan.Source);
    });
    private async Task ResolveMergeAsync(string directory)
    {
        if (Model.Trees is null) return;
        var state = await Model.Trees.MergeStateAsync(directory);
        var panel = new StackPanel { Spacing = 12, MinWidth = 520, MaxWidth = 800 };
        panel.Children.Add(new TextBlock { Text = L("Choose a file to compare both versions. Edit it externally or keep one version, then continue the merge."), TextWrapping = TextWrapping.Wrap });
        var files = new ComboBox { ItemsSource = state.Conflicts.Select(conflict => conflict.Path).ToArray(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var versions = new Grid { ColumnSpacing = 8 }; versions.ColumnDefinitions.Add(new()); versions.ColumnDefinitions.Add(new());
        var target = new TextBox { Header = L("Target Branch Version"), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, MinHeight = 180, MaxHeight = 320, FontFamily = new("Cascadia Mono, Consolas") };
        var incoming = new TextBox { Header = L("Incoming Branch Version"), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, MinHeight = 180, MaxHeight = 320, FontFamily = new("Cascadia Mono, Consolas") }; Grid.SetColumn(incoming, 1); versions.Children.Add(target); versions.Children.Add(incoming);
        var actions = new StackPanel { Spacing = 4 };
        var feedback = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog { Title = L("Resolve Merge"), XamlRoot = Root.XamlRoot, Content = new ScrollViewer { Content = panel }, PrimaryButtonText = L("Continue Merge"), SecondaryButtonText = L("Abort Merge"), CloseButtonText = L("Later"), IsPrimaryButtonEnabled = state.CanContinue, RequestedTheme = Root.ActualTheme };
        async Task Reload()
        {
            state = await Model.Trees.MergeStateAsync(directory); files.ItemsSource = state.Conflicts.Select(conflict => conflict.Path).ToArray();
            if (state.Conflicts.Length > 0) files.SelectedIndex = 0;
            else { target.Text = ""; incoming.Text = ""; feedback.Text = L("All Conflicts Resolved"); }
            dialog.IsPrimaryButtonEnabled = state.CanContinue;
        }
        files.SelectionChanged += async (_, _) => await Model.RunAsync(async () =>
        {
            if (files.SelectedItem is not string path) return;
            var before = await Model.Trees.ConflictContentAsync(directory, path, false);
            var after = await Model.Trees.ConflictContentAsync(directory, path, true);
            target.Text = before is null ? L("No Content") : before.Contains((byte)0) ? L("Binary File") : Encoding.UTF8.GetString(before);
            incoming.Text = after is null ? L("No Content") : after.Contains((byte)0) ? L("Binary File") : Encoding.UTF8.GetString(after);
        });
        foreach (var (label, resolution) in new[] { ("Use Target Version", ConflictResolution.Target), ("Use Incoming Version", ConflictResolution.Incoming), ("Mark Resolved", ConflictResolution.Edited), ("Delete File", ConflictResolution.Delete) })
        {
            var button = new Button { Content = L(label) };
            button.Click += async (_, _) => await Model.RunAsync(async () => { if (files.SelectedItem is string path) { await Model.Trees.ResolveAsync(directory, path, resolution); await Reload(); } }); actions.Children.Add(button);
        }
        var open = new Button { Content = L("Open File") }; open.Click += (_, _) => { if (files.SelectedItem is string path) ExternalApplications.OpenDefault(Path.Combine(directory, path)); }; actions.Children.Add(open);
        panel.Children.Add(files); panel.Children.Add(versions); panel.Children.Add(actions); panel.Children.Add(feedback);
        await Reload();
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary) await Model.Trees.ContinueAsync(directory);
        if (result == ContentDialogResult.Secondary && await ConfirmAsync("Abort Merge?", L("Git will return this worktree to its pre-merge state. Conflict-resolution edits will be discarded. Source branch commits are kept."), "Abort Merge")) await Model.Trees.AbortAsync(directory);
        await Model.RefreshAsync();
    }
    private void OpenClicked(object sender, RoutedEventArgs args)
    {
        var menu = new MenuFlyout();
        foreach (var application in Model.Settings.Applications.Concat(ExternalApplications.Discover()).DistinctBy(value => value.Executable).OrderByDescending(value => value.Pinned).ThenBy(value => Array.IndexOf(Model.Settings.RecentApplications, value.Executable) is var index && index >= 0 ? index : int.MaxValue))
        {
            var item = new MenuFlyoutItem { Text = application.Name };
            item.Click += async (_, _) => await Model.RunAsync(async () =>
            {
                if (Model.Directory is null) return;
                ExternalApplications.Open(application, Model.Directory);
                await Model.UpdateSettingsAsync(Model.Settings with { RecentApplications = new[] { application.Executable }.Concat(Model.Settings.RecentApplications).Distinct().Take(10).ToArray() });
            }); menu.Items.Add(item);
        }
        menu.ShowAt(OpenButton);
    }
    private async Task ShowSettingsAsync()
    {
        var settings = Model.Settings;
        var tabs = new Pivot { MinWidth = 560, MaxHeight = 620 };
        StackPanel Tab(string title)
        {
            var panel = new StackPanel { Spacing = 16, Margin = new(4) };
            tabs.Items.Add(new PivotItem { Header = L(title), Content = new ScrollViewer { Content = panel, MaxHeight = 500 } }); return panel;
        }
        CheckBox Toggle(StackPanel panel, string key, bool value) { var control = new CheckBox { Content = L(key), IsChecked = value }; panel.Children.Add(control); return control; }
        var general = Tab("General");
        var restore = Toggle(general, "Restore Previous Repository and Window", settings.RestoreSession);
        var languageNames = new[] { L("Automatic"), "English", "简体中文", "繁體中文", "日本語", "한국어", "Русский", "Français", "Español" };
        var languages = new[] { "automatic", "en", "zh-Hans", "zh-Hant", "ja", "ko", "ru", "fr", "es" };
        var language = new ComboBox { Header = L("Interface Language"), ItemsSource = languageNames, SelectedIndex = Array.IndexOf(languages, settings.Language), HorizontalAlignment = HorizontalAlignment.Stretch }; general.Children.Add(language);
        general.Children.Add(new TextBlock { Text = L("Language changes take full effect after restarting the application."), TextWrapping = TextWrapping.Wrap });
        var startup = WindowsApplicationIdentity.IsPackaged ? await StartupTask.GetAsync("FoldGitStartup") : null;
        var launch = Toggle(general, "Launch at Login", startup?.State == StartupTaskState.Enabled);
        launch.IsEnabled = startup is not null;
        var git = new TextBox { Header = L("Git Executable"), Text = settings.GitPath ?? GitInstallation.Locate(null) ?? "" }; general.Children.Add(git);
        var chooseGit = new Button { Content = L("Choose Git") }; chooseGit.Click += async (_, _) => { var path = await FileAsync(".exe"); if (path is not null) git.Text = path; }; general.Children.Add(chooseGit);
        var appearance = Tab("Appearance");
        var theme = new ComboBox { Header = L("Color Scheme"), ItemsSource = new[] { L("Automatic"), L("Light"), L("Dark") }, SelectedIndex = Array.IndexOf(new[] { "automatic", "light", "dark" }, settings.Appearance), HorizontalAlignment = HorizontalAlignment.Stretch }; appearance.Children.Add(theme);
        var comparison = Tab("Diff Display");
        var side = Toggle(comparison, "Side by Side", settings.SideBySide); var wrap = Toggle(comparison, "Wrap Long Lines", settings.WordWrap);
        var lines = Toggle(comparison, "Line Numbers", settings.LineNumbers); var expanded = Toggle(comparison, "Expanded", settings.ExpandFiles);
        var size = new NumberBox { Header = L("Code Font Size"), Minimum = 11, Maximum = 18, Value = settings.FontSize, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline }; comparison.Children.Add(size);
        var repository = Tab("Repositories");
        var worktrees = Toggle(repository, "Enable Worktrees", settings.WorktreesEnabled);
        repository.Children.Add(new TextBlock { Text = L("After enabling worktrees globally, enable them for each repository in its context menu. Worktree information and management actions appear only for enabled repositories. Turning this off preserves repository choices."), TextWrapping = TextWrapping.Wrap });
        var templates = new TextBox { Header = L("Commit Message Snippets"), Text = string.Join("\n---\n", settings.CommitTemplates), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 120 }; repository.Children.Add(templates);
        var applications = Tab("Applications");
        var appList = new ListView { ItemsSource = settings.Applications.Concat(ExternalApplications.Discover()).DistinctBy(value => value.Executable).ToArray(), DisplayMemberPath = "Name", SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 240 };
        foreach (var application in appList.Items.OfType<ExternalApplication>().Where(value => value.Pinned)) appList.SelectedItems.Add(application);
        applications.Children.Add(new TextBlock { Text = L("Pin Applications") }); applications.Children.Add(appList);
        var addApp = new Button { Content = L("Choose Application") }; addApp.Click += async (_, _) =>
        {
            var executable = await FileAsync(".exe");
            if (executable is not null) appList.ItemsSource = appList.Items.OfType<ExternalApplication>().Append(new(Path.GetFileNameWithoutExtension(executable), executable, ["{path}"])).ToArray();
        }; applications.Children.Add(addApp);
        var removeApp = new Button { Content = L("Remove Custom Application") }; removeApp.Click += (_, _) => appList.ItemsSource = appList.Items.OfType<ExternalApplication>().Except(appList.SelectedItems.OfType<ExternalApplication>()).ToArray(); applications.Children.Add(removeApp);
        var about = Tab("About"); about.Children.Add(new TextBlock { Text = "FoldGit 0.1.1", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"] });
        about.Children.Add(new TextBlock { Text = L("Git Client") });
        about.Children.Add(new TextBox { Header = L("Open Source Licenses"), Text = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "Assets", "LICENSE.txt")), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 220 });
        var reset = new CheckBox { Content = L("Restore Defaults") }; about.Children.Add(reset);
        if (!await DialogAsync("Settings", tabs, "Save")) return;
        if (reset.IsChecked == true)
        {
            if (await ConfirmAsync("Restore All Default Settings?", L("The settings below will be restored. Custom snippets and custom application entries will be replaced. Repositories, groups, names, and local files are kept."), "Restore Defaults")) { startup?.Disable(); await Model.ResetAsync(); }
            return;
        }
        if (git.Text.Length > 0) await GitInstallation.ValidateAsync(git.Text);
        if (startup is not null && launch.IsChecked == true && startup.State != StartupTaskState.Enabled)
        {
            var result = await startup.RequestEnableAsync();
            if (result != StartupTaskState.Enabled) throw new InvalidOperationException(L("Launch at Login"));
        }
        else if (launch.IsChecked != true) startup?.Disable();
        var pinned = appList.SelectedItems.OfType<ExternalApplication>().Select(value => value.Executable).ToHashSet();
        await Model.UpdateSettingsAsync(settings with
        {
            RestoreSession = restore.IsChecked == true, SelectedRepository = restore.IsChecked == true ? Model.Directory : null,
            Language = languages[language.SelectedIndex], Appearance = new[] { "automatic", "light", "dark" }[theme.SelectedIndex],
            GitPath = git.Text.Length > 0 ? git.Text : null, SideBySide = side.IsChecked == true, WordWrap = wrap.IsChecked == true,
            LineNumbers = lines.IsChecked == true, ExpandFiles = expanded.IsChecked == true, FontSize = double.IsFinite(size.Value) ? Math.Clamp(size.Value, 11, 18) : 12,
            WorktreesEnabled = worktrees.IsChecked == true,
            CommitTemplates = templates.Text.Split("\n---\n", StringSplitOptions.RemoveEmptyEntries),
            Applications = appList.Items.OfType<ExternalApplication>().Select(application => application with { Pinned = pinned.Contains(application.Executable) }).ToArray()
        });
        await Model.RefreshAsync();
    }
    private async void TemplatesClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        var list = new ListView { ItemsSource = Model.Settings.CommitTemplates, MaxHeight = 360, MinWidth = 360 };
        if (await DialogAsync("Commit Message Snippets", list, "Apply") && list.SelectedItem is string message)
            Model.CommitMessage += (Model.CommitMessage.Length > 0 ? "\n" : "") + message;
    });
}
