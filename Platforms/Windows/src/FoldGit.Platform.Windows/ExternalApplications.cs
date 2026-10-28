using System.Diagnostics;

namespace FoldGit.Platform.Windows;

public sealed record ExternalApplication(string Name, string Executable, string[] Arguments, bool Pinned = false);

public static class ExternalApplications
{
    public static ExternalApplication[] Discover()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var program = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var candidates = new[]
        {
            new ExternalApplication("Visual Studio Code", Path.Combine(local, "Programs", "Microsoft VS Code", "Code.exe"), ["{path}"]),
            new ExternalApplication("Visual Studio Code", Path.Combine(program, "Microsoft VS Code", "Code.exe"), ["{path}"]),
            new ExternalApplication("Cursor", Path.Combine(local, "Programs", "cursor", "Cursor.exe"), ["{path}"]),
            new ExternalApplication("Windows Terminal", Path.Combine(local, "Microsoft", "WindowsApps", "wt.exe"), ["-d", "{path}"]),
            new ExternalApplication("PowerShell", Path.Combine(program, "PowerShell", "7", "pwsh.exe"), ["-NoExit", "-WorkingDirectory", "{path}"]),
            new ExternalApplication("Notepad", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "notepad.exe"), ["{path}"])
        };
        return candidates.Where(application => File.Exists(application.Executable)).DistinctBy(application => application.Name).ToArray();
    }
    public static void Open(ExternalApplication application, string path)
    {
        var start = new ProcessStartInfo(application.Executable) { UseShellExecute = false };
        foreach (var argument in application.Arguments) start.ArgumentList.Add(argument.Replace("{path}", path, StringComparison.Ordinal));
        Process.Start(start)?.Dispose();
    }
    public static void Reveal(string path)
    {
        var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        start.ArgumentList.Add("/select," + Path.GetFullPath(path));
        Process.Start(start)?.Dispose();
    }
    public static void OpenDefault(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();
}
