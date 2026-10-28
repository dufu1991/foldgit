using System.Text;
using System.Text.RegularExpressions;

namespace FoldGit.Core.Git;

public enum DiffLineKind { Context, Added, Removed, Marker }
public sealed record DiffLine(DiffLineKind Kind, string Text, int? OldNumber, int? NewNumber);
public sealed record DiffHunk(string Header, string Raw, DiffLine[] Lines);
public sealed record FileDiff(string Path, string? OldPath, string Header, string Raw, DiffHunk[] Hunks, bool Binary,
    string? OldBlob, string? NewBlob)
{
    public int Additions => Hunks.Sum(hunk => hunk.Lines.Count(line => line.Kind == DiffLineKind.Added));
    public int Deletions => Hunks.Sum(hunk => hunk.Lines.Count(line => line.Kind == DiffLineKind.Removed));
    public string Patch(DiffHunk hunk) => Header + hunk.Raw;
}

public sealed partial record Diff(FileDiff[] Files)
{
    [GeneratedRegex(@"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")]
    private static partial Regex HunkStart();

    public static Diff Parse(string raw)
    {
        var files = new List<FileDiff>();
        var starts = Regex.Matches(raw, "^diff --git ", RegexOptions.Multiline).Select(match => match.Index).Append(raw.Length).ToArray();
        for (var i = 0; i < starts.Length - 1; i++)
        {
            var file = raw[starts[i]..starts[i + 1]];
            var lines = Lines(file).ToArray();
            var hunks = new List<DiffHunk>();
            var header = new StringBuilder();
            var hunkRaw = new StringBuilder();
            var hunkLines = new List<DiffLine>();
            string? hunkHeader = null, path = null, oldPath = null, oldBlob = null, newBlob = null;
            var oldNumber = 0;
            var newNumber = 0;
            void CompleteHunk()
            {
                if (hunkHeader is not null) hunks.Add(new(hunkHeader, hunkRaw.ToString(), hunkLines.ToArray()));
                hunkRaw.Clear(); hunkLines.Clear();
            }
            foreach (var lineRaw in lines)
            {
                var line = lineRaw.TrimEnd('\n');
                var match = HunkStart().Match(line);
                if (match.Success)
                {
                    CompleteHunk();
                    hunkHeader = line;
                    oldNumber = int.Parse(match.Groups[1].Value);
                    newNumber = int.Parse(match.Groups[2].Value);
                    hunkRaw.Append(lineRaw);
                }
                else if (hunkHeader is null)
                {
                    header.Append(lineRaw);
                    if (line.StartsWith("+++ ", StringComparison.Ordinal)) path = HeaderPath(line[4..]);
                    if (line.StartsWith("--- ", StringComparison.Ordinal)) oldPath = HeaderPath(line[4..]);
                    if (line.StartsWith("rename to ", StringComparison.Ordinal)) path = DecodePath(line[10..]);
                    if (line.StartsWith("rename from ", StringComparison.Ordinal)) oldPath = DecodePath(line[12..]);
                    if (line.StartsWith("index ", StringComparison.Ordinal))
                    {
                        var pair = line.Split(' ')[1].Split("..");
                        oldBlob = pair[0]; newBlob = pair[1];
                    }
                }
                else
                {
                    hunkRaw.Append(lineRaw);
                    if (line.Length == 0) continue;
                    hunkLines.Add(line[0] switch
                    {
                        '+' => new(DiffLineKind.Added, line[1..], null, newNumber++),
                        '-' => new(DiffLineKind.Removed, line[1..], oldNumber++, null),
                        ' ' => new(DiffLineKind.Context, line[1..], oldNumber++, newNumber++),
                        _ => new(DiffLineKind.Marker, line, null, null)
                    });
                }
            }
            CompleteHunk();
            // Git always emits ---/+++ for text changes. Binary and mode-only changes use the diff header.
            if (path is null && oldPath is null)
            {
                var first = lines[0].TrimEnd('\n')[11..];
                var boundary = first.LastIndexOf(" b/", StringComparison.Ordinal);
                if (boundary >= 0) path = DecodePath(first[(boundary + 1)..])[2..];
                else
                {
                    var quoted = Regex.Matches(first, "\"(?:\\\\.|[^\"])*\"");
                    if (quoted.Count == 2) path = HeaderPath(quoted[1].Value);
                    else throw new GitException("Invalid diff path from Git.");
                }
            }
            files.Add(new(path ?? oldPath!, oldPath, header.ToString(), file, hunks.ToArray(),
                file.Contains("GIT binary patch", StringComparison.Ordinal) || file.Contains("Binary files ", StringComparison.Ordinal), oldBlob, newBlob));
        }
        return new(files.ToArray());
    }

    private static IEnumerable<string> Lines(string text)
    {
        var start = 0;
        for (var i = 0; i < text.Length; i++)
            if (text[i] == '\n') { yield return text[start..(i + 1)]; start = i + 1; }
        if (start < text.Length) yield return text[start..];
    }

    private static string? HeaderPath(string raw)
    {
        var decoded = DecodePath(raw);
        if (decoded == "/dev/null") return null;
        return decoded.StartsWith("a/", StringComparison.Ordinal) || decoded.StartsWith("b/", StringComparison.Ordinal) ? decoded[2..] : decoded;
    }

    public static string DecodePath(string raw)
    {
        if (!raw.StartsWith('"') || !raw.EndsWith('"')) return raw;
        using var bytes = new MemoryStream();
        var input = Encoding.UTF8.GetBytes(raw[1..^1]);
        for (var i = 0; i < input.Length; i++)
        {
            if (input[i] != '\\') { bytes.WriteByte(input[i]); continue; }
            if (++i >= input.Length) throw new GitException("Invalid quoted Git path.");
            var value = input[i];
            if (value is >= (byte)'0' and <= (byte)'7')
            {
                var octal = value - '0';
                var count = 1;
                while (count < 3 && i + 1 < input.Length && input[i + 1] is >= (byte)'0' and <= (byte)'7')
                { octal = octal * 8 + input[++i] - '0'; count++; }
                bytes.WriteByte((byte)octal);
            }
            else bytes.WriteByte(value switch { (byte)'t' => 9, (byte)'n' => 10, (byte)'r' => 13, (byte)'a' => 7, (byte)'b' => 8, (byte)'v' => 11, (byte)'f' => 12, _ => value });
        }
        return new UTF8Encoding(false, true).GetString(bytes.ToArray());
    }
}

public sealed record DiffRow(DiffLine? Left, DiffLine? Right)
{
    public static DiffRow[] Align(DiffHunk hunk)
    {
        var result = new List<DiffRow>();
        var removed = new List<DiffLine>();
        var added = new List<DiffLine>();
        void Flush()
        {
            for (var i = 0; i < Math.Max(removed.Count, added.Count); i++)
                result.Add(new(i < removed.Count ? removed[i] : null, i < added.Count ? added[i] : null));
            removed.Clear(); added.Clear();
        }
        foreach (var line in hunk.Lines)
        {
            if (line.Kind == DiffLineKind.Removed) { if (added.Count > 0) Flush(); removed.Add(line); }
            else if (line.Kind == DiffLineKind.Added) added.Add(line);
            else { Flush(); result.Add(new(line, line)); }
        }
        Flush();
        return result.ToArray();
    }
}
