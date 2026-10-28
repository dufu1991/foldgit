using System.Text.RegularExpressions;
using FoldGit.Core.Git;
using FoldGit.Core.Resources;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.Graphics.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FoldGit.App.Controls;

public sealed class DiffViewer : UserControl
{
    private readonly ItemsRepeater files = new() { Layout = new StackLayout { Spacing = 8 }, VerticalAlignment = VerticalAlignment.Top };
    private readonly ScrollViewer scroll = new() { VerticalContentAlignment = VerticalAlignment.Top };
    private readonly Dictionary<string, bool> expansion = new(StringComparer.Ordinal);
    private FileIconTheme? icons;
    public TextCatalog Text { get; set; } = new("automatic");
    public bool SideBySide { get; set; }
    public bool WordWrap { get; set; }
    public bool LineNumbers { get; set; } = true;
    public bool DefaultExpanded { get; set; } = true;
    public double FontSizeSetting { get; set; } = 12;
    public Func<FileDiff, DiffHunk, Task>? StageHunk { get; set; }
    public Func<FileDiff, Task>? StageFile { get; set; }
    public Func<FileDiff, bool, Task<byte[]?>>? ReadImage { get; set; }
    public Action<string>? OpenFile { get; set; }
    public Action<Exception>? Failed { get; set; }
    public string? StagingLabel { get; set; }
    private Diff? current;
    public DiffViewer()
    {
        scroll.Content = files; Content = scroll;
        files.ItemTemplate = new DiffElementFactory(item => FileCard((FileDiff)item));
    }
    public void UseParentScrollViewer()
    {
        scroll.Content = null;
        Content = files;
    }
    public void Show(Diff? diff)
    {
        current = diff;
        scroll.HorizontalScrollBarVisibility = WordWrap ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
        scroll.HorizontalScrollMode = WordWrap ? ScrollMode.Disabled : ScrollMode.Enabled;
        icons ??= FileIconTheme.Load(Path.Combine(AppContext.BaseDirectory, "Assets", "MaterialFileIcons.json"));
        // Recreate native elements when presentation settings change without a new diff snapshot.
        files.ItemsSource = null;
        files.ItemsSource = diff?.Files;
    }
    public void ExpandAll(bool expanded)
    {
        if (current is null) return;
        foreach (var file in current.Files) expansion[file.Path] = expanded;
        files.ItemsSource = null; files.ItemsSource = current.Files;
    }
    private Expander FileCard(FileDiff file)
    {
        var heading = new Grid { ColumnSpacing = 8, HorizontalAlignment = HorizontalAlignment.Stretch };
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var iconName = icons!.Icon(file.Path, ActualTheme == ElementTheme.Dark);
        var icon = new Image { Source = new SvgImageSource(new Uri("ms-appx:///Assets/FileIcons/" + iconName + ".svg")), Width = 20, Height = 20 };
        heading.Children.Add(icon);
        var name = new TextBlock { Text = file.Path, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(name, file.Path); Grid.SetColumn(name, 1); heading.Children.Add(name);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        actions.Children.Add(new TextBlock { Text = $"+{file.Additions} −{file.Deletions}", VerticalAlignment = VerticalAlignment.Center });
        if (StagingLabel is not null && StageFile is not null)
        {
            var stage = new Button { Content = StagingLabel };
            stage.Click += async (_, _) => await ExecuteAsync(() => StageFile(file)); actions.Children.Add(stage);
        }
        var open = new Button { Content = new FontIcon { Glyph = "\uE8E5", FontSize = 14 } };
        AutomationProperties.SetName(open, Text.Get("Open File"));
        open.Click += (_, _) => OpenFile?.Invoke(file.Path); actions.Children.Add(open);
        Grid.SetColumn(actions, 2); heading.Children.Add(actions);
        var expander = new Expander { Header = heading, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top, VerticalContentAlignment = VerticalAlignment.Top,
            Margin = new(0, 0, 0, 8), IsExpanded = expansion.GetValueOrDefault(file.Path, DefaultExpanded) };
        void Populate()
        {
            if (expander.Content is not null) return;
            if (file.Binary || IsImage(file.Path))
            {
                var panel = new StackPanel { Spacing = 8 };
                panel.Children.Add(new TextBlock { Text = Text.Get(file.Binary ? "Binary File" : "Image Comparison") });
                expander.Content = panel;
                if (IsImage(file.Path) && ReadImage is not null) _ = ExecuteAsync(() => LoadImagesAsync(file, panel));
                return;
            }
            if (file.Hunks.Length == 0)
            {
                expander.Content = new TextBlock { Text = file.Raw, FontFamily = new("Cascadia Mono, Consolas"), IsTextSelectionEnabled = true };
                return;
            }
            var hunks = new ItemsRepeater { Layout = new StackLayout { Spacing = 8 }, ItemsSource = file.Hunks, VerticalAlignment = VerticalAlignment.Top };
            hunks.ItemTemplate = new DiffElementFactory(value =>
            {
                var hunk = (DiffHunk)value;
                var item = new StackPanel { Spacing = 4 };
                var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                bar.Children.Add(new TextBlock { Text = hunk.Header, FontFamily = new("Cascadia Mono, Consolas"), FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
                var copy = new Button { Content = new FontIcon { Glyph = "\uE8C8", FontSize = 12 } };
                AutomationProperties.SetName(copy, Text.Get("Copy %@", hunk.Header));
                copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(string.Join('\n', hunk.Lines.Where(line => line.Kind != DiffLineKind.Removed).Select(line => line.Text))); Clipboard.SetContent(data); };
                bar.Children.Add(copy);
                if (StageHunk is not null && StagingLabel is not null && file.Header.Length > 0
                    && !file.Header.Contains("rename from ", StringComparison.Ordinal) && !file.Header.Contains("new file mode ", StringComparison.Ordinal) && !file.Header.Contains("deleted file mode ", StringComparison.Ordinal))
                {
                    var button = new Button { Content = Text.Get(StagingLabel == Text.Get("Stage This File") ? "Stage This Hunk" : "Unstage This Hunk") };
                    button.Click += async (_, _) => await ExecuteAsync(() => StageHunk(file, hunk)); bar.Children.Add(button);
                }
                item.Children.Add(bar);
                item.Children.Add(RenderHunk(file, hunk));
                return item;
            });
            expander.Content = hunks;
        }
        expander.Expanding += (_, _) => { expansion[file.Path] = true; Populate(); };
        expander.Collapsed += (_, _) => { expansion[file.Path] = false; expander.Content = null; };
        if (expander.IsExpanded) Populate();
        return expander;
    }
    private UIElement RenderHunk(FileDiff file, DiffHunk hunk)
    {
        var grid = new Grid { ColumnSpacing = 1 };
        var rows = DiffRow.Align(hunk);
        var changes = new Dictionary<DiffLine, TextSpan[]>();
        foreach (var row in rows)
            if (row.Left is { Kind: DiffLineKind.Removed } old && row.Right is { Kind: DiffLineKind.Added } next)
            {
                var ranges = InlineDiff.Compare(old.Text, next.Text); changes[old] = ranges.Old; changes[next] = ranges.New;
            }
        grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        if (SideBySide)
        {
            grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            for (var index = 0; index < rows.Length; index++)
            {
                grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
                var left = Editor(file.Path, [rows[index].Left], true, changes);
                var right = Editor(file.Path, [rows[index].Right], false, changes);
                Grid.SetRow(left, index); Grid.SetRow(right, index); Grid.SetColumn(right, 1);
                grid.Children.Add(left); grid.Children.Add(right);
            }
        }
        else grid.Children.Add(Editor(file.Path, hunk.Lines.Cast<DiffLine?>().ToArray(), false, changes));
        return grid;
    }
    private RichTextBlock Editor(string path, DiffLine?[] lines, bool oldSide, Dictionary<DiffLine, TextSpan[]> changes)
    {
        var editor = new RichTextBlock
        {
            IsTextSelectionEnabled = true,
            FontFamily = new("Cascadia Mono, Consolas"), FontSize = FontSizeSetting, Padding = new(8, 2, 8, 2),
            TextWrapping = WordWrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = FontSizeSetting * 1.5 + 4
        };
        AutomationProperties.SetName(editor, path + " " + Text.Get(oldSide ? "Before" : "After"));
        var width = lines.Where(line => line is not null).Select(line => Math.Max(line!.OldNumber ?? 0, line.NewNumber ?? 0).ToString().Length).DefaultIfEmpty(1).Max();
        var texts = lines.Select(line => line is null ? "" : (LineNumbers ? ((oldSide ? line.OldNumber : line.NewNumber ?? line.OldNumber)?.ToString() ?? "").PadLeft(width) + "  " : "")
            + (line.Kind switch { DiffLineKind.Added => "+ ", DiffLineKind.Removed => "− ", _ => "  " }) + line.Text).ToArray();
        var paragraph = new Paragraph(); paragraph.Inlines.Add(new Run { Text = string.Join('\n', texts) }); editor.Blocks.Add(paragraph);
        void Highlight(int start, int length, Color? background = null, Color? foreground = null)
        {
            if (length == 0) return;
            var highlight = new TextHighlighter
            {
                Background = new SolidColorBrush(background ?? Colors.Transparent),
                Foreground = foreground.HasValue ? new SolidColorBrush(foreground.Value) : editor.Foreground
            };
            highlight.Ranges.Add(new TextRange { StartIndex = start, Length = length }); editor.TextHighlighters.Add(highlight);
        }
        var offset = 0;
        var highContrast = new AccessibilitySettings().HighContrast;
        for (var i = 0; i < lines.Length; i++)
        {
            var length = texts[i].Length;
            if (lines[i] is { } line)
            {
                if (!highContrast && line.Kind is DiffLineKind.Added or DiffLineKind.Removed)
                    Highlight(offset, length, ActualTheme == ElementTheme.Dark
                        ? line.Kind == DiffLineKind.Added ? Color.FromArgb(255, 28, 68, 42) : Color.FromArgb(255, 81, 38, 43)
                        : line.Kind == DiffLineKind.Added ? Color.FromArgb(255, 222, 247, 226) : Color.FromArgb(255, 255, 228, 230));
                foreach (Match token in highContrast ? Regex.Matches("", "(?!)") : SyntaxTokens(line.Text, path))
                {
                    var prefix = length - line.Text.Length;
                    Highlight(offset + prefix + token.Index, token.Length, foreground: Color.FromArgb(255, 118, 119, 203));
                }
                if (!highContrast && changes.TryGetValue(line, out var spans))
                    foreach (var span in spans)
                    {
                        var start = offset + length - line.Text.Length + span.Start;
                        Highlight(start, span.Length, line.Kind == DiffLineKind.Added
                            ? ActualTheme == ElementTheme.Dark ? Color.FromArgb(255, 38, 110, 60) : Color.FromArgb(255, 170, 228, 182)
                            : ActualTheme == ElementTheme.Dark ? Color.FromArgb(255, 140, 50, 62) : Color.FromArgb(255, 255, 183, 192));
                    }
            }
            offset += length + 1;
        }
        return editor;
    }
    private static MatchCollection SyntaxTokens(string text, string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is ".txt" or ".log") return Regex.Matches(text, "(?!)");
        return Regex.Matches(text, "\\b(?:public|private|internal|class|struct|enum|interface|namespace|using|import|from|func|function|let|var|const|return|if|else|for|while|async|await|throw|try|catch|true|false|null|nil|def|fn|impl|self|this|new|static|export|default)\\b|\"(?:\\\\.|[^\"])*\"|'(?:\\\\.|[^'])*'|//.*$|#[^\\r\\n]*$", RegexOptions.CultureInvariant);
    }
    private static bool IsImage(string path) => new[] { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".ico" }.Contains(Path.GetExtension(path).ToLowerInvariant());
    private async Task LoadImagesAsync(FileDiff file, StackPanel panel)
    {
        foreach (var oldSide in new[] { true, false })
        {
            panel.Children.Add(new TextBlock { Text = Text.Get(oldSide ? "Before" : "After") });
            var bytes = await ReadImage!(file, oldSide);
            if (bytes is null) { panel.Children.Add(new TextBlock { Text = Text.Get("No Image in This Version") }); continue; }
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            if ((long)decoder.PixelWidth * decoder.PixelHeight > 40_000_000) throw new InvalidDataException(Text.Get("The image is too large to preview."));
            stream.Seek(0);
            var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream);
            if ((long)bitmap.PixelWidth * bitmap.PixelHeight > 40_000_000) throw new InvalidDataException(Text.Get("The image is too large to preview."));
            var image = new Image { Source = bitmap, Stretch = Stretch.Uniform, MaxHeight = 500 };
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var fit = new Button { Content = Text.Get("Fit") }; fit.Click += (_, _) => { image.Stretch = Stretch.Uniform; image.Width = double.NaN; image.Height = double.NaN; };
            var actual = new Button { Content = Text.Get("Actual Size") }; actual.Click += (_, _) => { image.Stretch = Stretch.None; image.Width = bitmap.PixelWidth; image.Height = bitmap.PixelHeight; };
            var zoomIn = new Button { Content = "+" }; AutomationProperties.SetName(zoomIn, Text.Get("Zoom In"));
            var zoomOut = new Button { Content = "−" }; AutomationProperties.SetName(zoomOut, Text.Get("Zoom Out"));
            void Zoom(double factor)
            {
                var width = double.IsNaN(image.Width) ? image.ActualWidth : image.Width;
                image.Stretch = Stretch.Fill; image.Width = Math.Clamp(width * factor, 16, bitmap.PixelWidth * 8);
                image.Height = image.Width * bitmap.PixelHeight / bitmap.PixelWidth;
            }
            zoomIn.Click += (_, _) => Zoom(1.25); zoomOut.Click += (_, _) => Zoom(0.8);
            controls.Children.Add(fit); controls.Children.Add(actual); controls.Children.Add(zoomIn); controls.Children.Add(zoomOut); controls.Children.Add(new TextBlock { Text = $"{bitmap.PixelWidth} × {bitmap.PixelHeight}" });
            panel.Children.Add(controls);
            panel.Children.Add(new ScrollViewer { Content = image, MaxHeight = 520, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto });
        }
    }
    private async Task ExecuteAsync(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { Failed?.Invoke(error); }
    }
}

internal sealed class DiffElementFactory(Func<object, UIElement> create) : IElementFactory
{
    public UIElement GetElement(ElementFactoryGetArgs args) => create(args.Data);
    public void RecycleElement(ElementFactoryRecycleArgs args)
    {
        if (args.Element is Expander expander) expander.Content = null;
    }
}
