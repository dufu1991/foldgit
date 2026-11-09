using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FoldGit.App.Controls;

public sealed class ToolbarOperationIcon : UserControl
{
    private readonly FontIcon icon = new() { FontSize = 16 };
    private readonly ProgressRing progress = new()
    {
        Width = 16, Height = 16, MinWidth = 0, MinHeight = 0,
        IsActive = false, Visibility = Visibility.Collapsed
    };

    public string Glyph { get => icon.Glyph; set => icon.Glyph = value; }
    public bool IsLoading
    {
        get => progress.IsActive;
        set
        {
            icon.Opacity = value ? 0 : 1;
            progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            progress.IsActive = value;
        }
    }

    public ToolbarOperationIcon()
    {
        Width = 16; Height = 16; IsHitTestVisible = false;
        var content = new Grid();
        content.Children.Add(icon);
        content.Children.Add(progress);
        Content = content;
    }
}
