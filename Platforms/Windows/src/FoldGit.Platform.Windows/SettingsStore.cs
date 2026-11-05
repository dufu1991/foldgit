using System.Text.Json;
using FoldGit.Core.Git;
using FoldGit.Core.History;
using FoldGit.Core.Workspace;

namespace FoldGit.Platform.Windows;

public sealed record AppSettings
{
    public int Version { get; init; } = 1;
    public WorkspaceState Workspace { get; init; } = WorkspaceState.Empty;
    public string? SelectedRepository { get; init; }
    public string? GitPath { get; init; }
    public string Language { get; init; } = "automatic";
    public string Appearance { get; init; } = "automatic";
    public CommitTimeDisplayMode CommitTimeDisplayMode { get; init; } = CommitTimeDisplayMode.Hybrid;
    public bool DisableCommitOperations { get; init; }
    public bool RestoreSession { get; init; } = true;
    public bool WorktreesEnabled { get; init; } = true;
    public bool SideBySide { get; init; }
    public bool WordWrap { get; init; }
    public bool LineNumbers { get; init; } = true;
    public bool ExpandFiles { get; init; } = true;
    public double FontSize { get; init; } = 12;
    public WorkspaceSort Sort { get; init; }
    public string[] SearchHistory { get; init; } = [];
    public string[] CommitTemplates { get; init; } = [];
    public ExternalApplication[] Applications { get; init; } = [];
    public string[] RecentApplications { get; init; } = [];
    public CompletionPlan[] PendingCompletions { get; init; } = [];
    public int WindowWidth { get; init; } = 1400;
    public int WindowHeight { get; init; } = 900;
}

public sealed class SettingsStore(string? root = null)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public string Directory { get; } = root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FoldGit");
    public async Task<AppSettings> LoadAsync()
    {
        var path = Path.Combine(Directory, "settings.json");
        if (!File.Exists(path)) return new();
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(path));
        var settings = document.Deserialize<AppSettings>(Options)
            ?? throw new InvalidDataException("Settings are invalid.");
        if (settings.Version != 1) throw new InvalidDataException("This settings version is not supported.");
        var rootElement = document.RootElement;
        if (!rootElement.TryGetProperty("DisableCommitOperations", out _)
            && (rootElement.TryGetProperty("ShowCommitMessageArea", out var old) || rootElement.TryGetProperty("showCommitMessageArea", out old))
            // Ignore a malformed legacy value instead of making the whole settings file unreadable.
            && old.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            settings = settings with { DisableCommitOperations = old.ValueKind == JsonValueKind.False };
            await SaveAsync(settings);
        }
        return settings;
    }
    public async Task SaveAsync(AppSettings settings)
    {
        await gate.WaitAsync();
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            var temporary = Path.Combine(Directory, "settings.json.tmp");
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(settings, Options));
            File.Move(temporary, Path.Combine(Directory, "settings.json"), true);
        }
        finally { gate.Release(); }
    }
    public async Task ResetAsync()
    {
        await gate.WaitAsync();
        try
        {
            var path = Path.Combine(Directory, "settings.json");
            if (File.Exists(path)) File.Copy(path, Path.Combine(Directory, "settings.backup.json"), true);
            if (File.Exists(path)) File.Delete(path);
        }
        finally { gate.Release(); }
    }
}
