using System.Globalization;
using System.Text.Json.Serialization;
using FoldGit.Core.Resources;

namespace FoldGit.Core.History;

[JsonConverter(typeof(JsonStringEnumConverter<CommitTimeDisplayMode>))]
public enum CommitTimeDisplayMode
{
    [JsonStringEnumMemberName("relative")] Relative,
    [JsonStringEnumMemberName("absolute")] Absolute,
    [JsonStringEnumMemberName("hybrid")] Hybrid
}

public sealed record CommitTimeDisplay(string Text, string Tooltip, bool IsAbsolute);

public static class CommitTimeFormatter
{
    public static CommitTimeDisplay Format(DateTimeOffset date, CommitTimeDisplayMode mode,
        DateTimeOffset now, TextCatalog language, TimeZoneInfo timeZone)
    {
        var local = TimeZoneInfo.ConvertTime(date, timeZone);
        var absolute = local.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        var tooltip = absolute + " UTC" + local.ToString("zzz", CultureInfo.InvariantCulture);
        var age = now - date;
        var isAbsolute = mode == CommitTimeDisplayMode.Absolute
            || mode == CommitTimeDisplayMode.Hybrid && (age < TimeSpan.Zero || age >= TimeSpan.FromDays(7));
        if (isAbsolute) return new(absolute, tooltip, true);
        var seconds = Math.Abs(age.TotalSeconds);
        if (seconds < 5) return new(language.Get("Just now"), tooltip, false);
        var (past, future, unit) = seconds switch
        {
            < 60 => ("%lld seconds ago", "in %lld seconds", 1d),
            < 3600 => ("%lld minutes ago", "in %lld minutes", 60d),
            < 86400 => ("%lld hours ago", "in %lld hours", 3600d),
            < 2592000 => ("%lld days ago", "in %lld days", 86400d),
            < 31536000 => ("%lld months ago", "in %lld months", 2592000d),
            _ => ("%lld years ago", "in %lld years", 31536000d)
        };
        return new(language.Count(age < TimeSpan.Zero ? future : past, (long)(seconds / unit)), tooltip, false);
    }
}
