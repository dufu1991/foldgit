using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace FoldGit.App;

public partial class App : Application
{
    public MainWindow? Window { get; private set; }
    public App()
    {
#if FOLDGIT_CLOUD_DEBUG
        UnhandledException += (_, error) => Program.RecordError(error.Message + Environment.NewLine + error.Exception);
        DebugSettings.IsXamlResourceReferenceTracingEnabled = true;
        DebugSettings.XamlResourceReferenceFailed += (_, error) => Program.RecordError(error.Message);
#endif
        InitializeComponent();
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Window = new MainWindow();
        AppInstance.GetCurrent().Activated += (_, _) => Window.DispatcherQueue.TryEnqueue(() => Window.Activate());
        Window.Activate();
    }
}
