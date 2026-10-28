using System.Text.Json;

namespace FoldGit.Core.Resources;

public sealed record FileIconTheme(string DefaultIcon, HashSet<string> LightIcons,
    Dictionary<string, string> FileNames, Dictionary<string, string> FileExtensions)
{
    public static FileIconTheme Load(string path) => JsonSerializer.Deserialize<FileIconTheme>(File.ReadAllText(path),
        new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("The file icon manifest is invalid.");
    public string Icon(string path, bool dark)
    {
        var components = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries).Select(part => part.ToLowerInvariant()).ToArray();
        string? icon = null;
        for (var index = 0; index < components.Length; index++)
            if (FileNames.TryGetValue(string.Join('/', components[index..]), out icon)) break;
        if (icon is null && components.Length > 0)
        {
            var filename = components[^1];
            for (var index = 0; index < filename.Length; index++)
                if (filename[index] == '.' && FileExtensions.TryGetValue(filename[(index + 1)..], out icon)) break;
        }
        icon ??= DefaultIcon;
        return !dark && LightIcons.Contains(icon) ? icon + ".light" : icon;
    }
}
