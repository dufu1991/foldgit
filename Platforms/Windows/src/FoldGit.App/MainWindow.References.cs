using FoldGit.Core.Git;
using FoldGit.App.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace FoldGit.App;

public sealed partial class MainWindow
{
    private async void TagsClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        TagList.ItemsSource = Model.Tags;
        TagList.MinWidth = 340; TagList.MaxHeight = 480;
        TagList.IsItemClickEnabled = true;
        var create = new Button { Content = L("Create New Tag"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(TagList); panel.Children.Add(create);
        var dialog = new ContentDialog { Title = L("Tags"), Content = panel, CloseButtonText = L("Close"), XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme };
        string? revision = null;
        var creating = false;
        string? remove = null;
        string? checkout = null;
        void TagMenu(object list, RightTappedRoutedEventArgs click)
        {
            if (ItemAt<string>(click) is not { } tag) return;
            var menu = new MenuFlyout();
            var switchItem = new MenuFlyoutItem { Text = L("Checkout") };
            switchItem.Click += (_, _) => { checkout = tag; dialog.Hide(); }; menu.Items.Add(switchItem);
            var delete = new MenuFlyoutItem { Text = L("Delete") };
            delete.Click += (_, _) => { remove = tag; dialog.Hide(); }; menu.Items.Add(delete);
            ShowMenu(menu, click, TagList);
        }
        TagList.RightTapped += TagMenu;
        void SelectTag(object list, ItemClickEventArgs click) { revision = "refs/tags/" + (string)click.ClickedItem; dialog.Hide(); }
        TagList.ItemClick += SelectTag;
        create.Click += (_, _) => { creating = true; dialog.Hide(); };
        await dialogs.WaitAsync();
        try { await dialog.ShowAsync(); }
        finally { dialogs.Release(); TagList.ItemClick -= SelectTag; TagList.RightTapped -= TagMenu; panel.Children.Clear(); }
        if (remove is not null && await ConfirmAsync("Delete", remove, "Delete")) await Model.MutateAsync((service, directory) => service.TagAsync(directory, remove, null));
        else if (checkout is not null) await Model.MutateAsync((service, directory) => service.SwitchAsync(directory, "refs/tags/" + checkout, true));
        else if (creating) await CreateTagAsync("HEAD");
        else if (revision is not null && Model.Repositories is not null && Model.Directory is not null)
            await Model.ShowCommitAsync(await Model.Repositories.GetCommitAsync(Model.Directory, revision));
    });

    private async void StashesClicked(object sender, RoutedEventArgs args) => await Model.RunAsync(async () =>
    {
        if (Model.Directory is null || Model.Repositories is null) return;
        var repository = Model.Directory;
        var preview = new DiffViewer();
        var title = new TextBlock { Text = L("No Selection"), TextWrapping = TextWrapping.Wrap };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var detail = new Grid { RowSpacing = 12, Margin = new(12, 0, 0, 0) };
        detail.RowDefinitions.Add(new() { Height = GridLength.Auto });
        detail.RowDefinitions.Add(new() { Height = GridLength.Auto });
        detail.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        detail.Children.Add(title); Grid.SetRow(actions, 1); detail.Children.Add(actions); Grid.SetRow(preview, 2); detail.Children.Add(preview);
        StashList.ItemsSource = Model.Stashes; StashList.DisplayMemberPath = "Message";
        StashList.IsItemClickEnabled = true; StashList.Width = 240;
        var panel = new Grid { Width = Math.Min(1040, Math.Max(600, Root.ActualWidth - 120)), Height = Math.Min(620, Math.Max(320, Root.ActualHeight - 200)) };
        panel.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); panel.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        panel.Children.Add(StashList); Grid.SetColumn(detail, 1); panel.Children.Add(detail);
        var dialog = new ContentDialog { Title = L("Stash Changed"), Content = panel, CloseButtonText = L("Close"), XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme };
        dialog.Resources["ContentDialogMaxWidth"] = 1200.0;
        using var cancellation = new CancellationTokenSource();
        var generation = 0;
        Stash? selected = null;
        foreach (var (label, command) in new[] { ("Apply", "apply"), ("Apply and Drop", "pop"), ("Drop", "drop") })
        {
            var button = new Button { Content = L(label), IsEnabled = false };
            button.Click += async (_, _) => await Model.RunAsync(async () =>
            {
                if (selected is null) return;
                foreach (var action in actions.Children.OfType<Button>()) action.IsEnabled = false;
                try
                {
                    await Model.Repositories.StashActionAsync(repository, selected.Reference, command, cancellation.Token);
                    ++generation; selected = null; preview.Show(null); title.Text = L("No Selection");
                    await Model.RefreshAsync();
                }
                finally { foreach (var action in actions.Children.OfType<Button>()) action.IsEnabled = selected is not null; }
            });
            actions.Children.Add(button);
        }
        async void SelectStash(object list, ItemClickEventArgs click)
        {
            var request = ++generation;
            selected = (Stash)click.ClickedItem;
            var stash = selected;
            title.Text = stash.Message; preview.Show(null);
            foreach (var action in actions.Children.OfType<Button>()) action.IsEnabled = false;
            await Model.RunAsync(async () =>
            {
                var diff = await Model.Repositories.StashDiffAsync(repository, stash.Reference, cancellation.Token);
                if (request != generation || cancellation.IsCancellationRequested) return;
                ConfigureDiff(preview, stash.Hash + "^1", stash.Hash);
                preview.Show(diff);
                foreach (var action in actions.Children.OfType<Button>()) action.IsEnabled = true;
            });
        }
        StashList.ItemClick += SelectStash;
        await dialogs.WaitAsync();
        try { await dialog.ShowAsync(); }
        finally { await cancellation.CancelAsync(); dialogs.Release(); StashList.ItemClick -= SelectStash; panel.Children.Clear(); }
    });
}
