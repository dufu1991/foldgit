using FoldGit.Core.History;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FoldGit.App.Controls;

public sealed class GraphCell : UserControl
{
    private CanvasControl? canvas;
    private static readonly Color[] Colors = [Color.FromArgb(255, 76, 145, 245), Color.FromArgb(255, 223, 116, 176), Color.FromArgb(255, 110, 175, 99), Color.FromArgb(255, 221, 161, 63), Color.FromArgb(255, 163, 131, 224), Color.FromArgb(255, 69, 174, 172), Color.FromArgb(255, 224, 112, 93), Color.FromArgb(255, 145, 156, 175)];
    public static readonly DependencyProperty RowProperty = DependencyProperty.Register(nameof(Row), typeof(GraphCommit), typeof(GraphCell), new PropertyMetadata(null, (sender, _) => ((GraphCell)sender).Update()));
    public GraphCommit? Row { get => (GraphCommit?)GetValue(RowProperty); set => SetValue(RowProperty, value); }
    public GraphCell()
    {
        Loaded += (_, _) =>
        {
            if (canvas is not null) return;
            canvas = new() { MinHeight = 56, VerticalAlignment = VerticalAlignment.Stretch };
            canvas.Draw += Draw; Content = canvas; Update();
        };
        Unloaded += (_, _) => { canvas?.RemoveFromVisualTree(); canvas = null; Content = null; };
    }
    private void Update() { Width = Math.Max(32, (Row?.Columns ?? 1) * 16 + 16); canvas?.Invalidate(); }
    private void Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        if (Row is not { } row) return;
        var drawing = args.DrawingSession;
        var highContrast = new AccessibilitySettings().HighContrast;
        var systemColor = highContrast ? new UISettings().GetColorValue(UIColorType.Foreground) : default;
        var height = (float)sender.ActualHeight;
        float Y(GraphPosition position) => position switch { GraphPosition.Top => 0, GraphPosition.Node => height / 2, GraphPosition.Bottom => height, _ => height * 0.83f };
        foreach (var edge in row.Segments)
        {
            var color = highContrast ? systemColor : Colors[edge.Color % Colors.Length];
            drawing.DrawLine(12 + edge.From * 16, Y(edge.Start), 12 + edge.To * 16, Y(edge.End), color, 2);
            if (edge.Boundary) drawing.DrawCircle(12 + edge.To * 16, Y(edge.End), 2, color);
        }
        drawing.FillCircle(12 + row.Column * 16, height / 2, 4, highContrast ? systemColor : Colors[row.Color % Colors.Length]);
    }
}
