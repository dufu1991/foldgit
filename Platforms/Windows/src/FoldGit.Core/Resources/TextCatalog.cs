using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace FoldGit.Core.Resources;

public sealed partial class TextCatalog
{
    public static readonly string[] Languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "ru", "fr", "es"];
    private readonly JsonElement catalog;
    public string Language { get; }
    public TextCatalog(string language)
    {
        var culture = CultureInfo.CurrentUICulture;
        var systemLanguage = culture.TwoLetterISOLanguageName == "zh"
            ? culture.Name.Contains("Hant", StringComparison.OrdinalIgnoreCase) || culture.Name is "zh-TW" or "zh-HK" or "zh-MO" ? "zh-Hant" : "zh-Hans"
            : culture.TwoLetterISOLanguageName;
        Language = Languages.Contains(language) ? language : Languages.Contains(systemLanguage) ? systemLanguage : "en";
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("FoldGit.Core.Localization." + Language + ".json")
            ?? throw new InvalidDataException("The localization catalog is missing.");
        using var document = JsonDocument.Parse(stream);
        catalog = document.RootElement.Clone();
    }
    public string Get(string key, params object[] values)
    {
        var text = catalog.TryGetProperty("windows", out var windows) && windows.TryGetProperty(key, out var specific)
            ? specific.GetString()! : catalog.GetProperty("strings").GetProperty(key).GetString()!;
        return Format(text, values);
    }
    public string Count(string key, long count)
    {
        var rules = catalog.GetProperty("plurals").GetProperty(key).GetProperty("count");
        var category = PluralCategory(Language, count);
        return Format(rules.GetProperty(category).GetString()!, [count]);
    }
    public static string PluralCategory(string language, long count)
    {
        var n = Math.Abs(count);
        return language switch
        {
            "zh-Hans" or "zh-Hant" or "ja" or "ko" => "other",
            "ru" when n % 10 == 1 && n % 100 != 11 => "one",
            "ru" when n % 10 is >= 2 and <= 4 && n % 100 is not (>= 12 and <= 14) => "few",
            "ru" => "many",
            "fr" when n is 0 or 1 => "one",
            _ => n == 1 ? "one" : "other"
        };
    }
    [GeneratedRegex(@"%(?:(\d+)\$)?(?:lld|ld|d|u|@)")]
    private static partial Regex Placeholder();
    private static string Format(string text, object[] values)
    {
        if (values.Length == 0) return text;
        var position = 0;
        return Placeholder().Replace(text, match => Convert.ToString(values[match.Groups[1].Success ? int.Parse(match.Groups[1].Value) - 1 : position++], CultureInfo.CurrentCulture)!);
    }
}
