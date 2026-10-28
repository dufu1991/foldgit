using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace FoldGit.App;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
#if FOLDGIT_CLOUD_DEBUG
        AppDomain.CurrentDomain.UnhandledException += (_, error) => RecordError(error.ExceptionObject.ToString()!);
#endif
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var instance = AppInstance.FindOrRegisterForKey("FoldGit.Workbench");
        if (!instance.IsCurrent)
        {
            instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()).AsTask().GetAwaiter().GetResult();
            return;
        }
        Application.Start(initialization =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
    }
#if FOLDGIT_CLOUD_DEBUG
    internal static void RecordError(string error) => File.AppendAllText(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "foldgit-cloud-debug", "logs", "app-errors.log"),
        $"{DateTimeOffset.Now:O}{Environment.NewLine}{error}{Environment.NewLine}");
#endif
}
