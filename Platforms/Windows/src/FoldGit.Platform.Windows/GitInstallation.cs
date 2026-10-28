using FoldGit.Core.Git;
using Microsoft.Win32;

namespace FoldGit.Platform.Windows;

public static class GitInstallation
{
    public static string? Locate(string? configured)
    {
        if (!string.IsNullOrEmpty(configured)) return File.Exists(configured) ? configured : null;
        var candidates = new List<string>();
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var key = hive.OpenSubKey(@"SOFTWARE\GitForWindows");
            if (key?.GetValue("InstallPath") is string install) candidates.Add(Path.Combine(install, "cmd", "git.exe"));
        }
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (directory.Length > 0) candidates.Add(Path.Combine(directory.Trim('"'), "git.exe"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "cmd", "git.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }
    public static async Task<string> ValidateAsync(string path)
    {
        var output = await new GitProcess(path).ExecuteAsync(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ["--version"]);
        return output.Text.Trim();
    }
}
