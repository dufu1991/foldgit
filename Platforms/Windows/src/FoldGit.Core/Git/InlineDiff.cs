using System.Globalization;

namespace FoldGit.Core.Git;

public sealed record TextSpan(int Start, int Length);
public sealed record InlineChanges(TextSpan[] Old, TextSpan[] New);

public static class InlineDiff
{
    public static InlineChanges Compare(string oldText, string newText)
    {
        var oldOffsets = StringInfo.ParseCombiningCharacters(oldText).Append(oldText.Length).ToArray();
        var newOffsets = StringInfo.ParseCombiningCharacters(newText).Append(newText.Length).ToArray();
        var old = oldOffsets.Zip(oldOffsets.Skip(1), (start, end) => oldText[start..end]).ToArray();
        var next = newOffsets.Zip(newOffsets.Skip(1), (start, end) => newText[start..end]).ToArray();
        var prefix = 0;
        while (prefix < Math.Min(old.Length, next.Length) && old[prefix] == next[prefix]) prefix++;
        var oldEnd = old.Length; var newEnd = next.Length;
        while (oldEnd > prefix && newEnd > prefix && old[oldEnd - 1] == next[newEnd - 1]) { oldEnd--; newEnd--; }
        if (oldEnd == prefix && newEnd == prefix) return new([], []);
        var oldSpans = new List<TextSpan>(); var newSpans = new List<TextSpan>();
        void Add(int fromOld, int toOld, int fromNew, int toNew)
        {
            if (toOld > fromOld) oldSpans.Add(new(oldOffsets[fromOld], oldOffsets[toOld] - oldOffsets[fromOld]));
            if (toNew > fromNew) newSpans.Add(new(newOffsets[fromNew], newOffsets[toNew] - newOffsets[fromNew]));
        }
        var height = oldEnd - prefix + 1; var width = newEnd - prefix + 1;
        if ((long)height * width > 262_144 || height == 1 || width == 1)
        { Add(prefix, oldEnd, prefix, newEnd); return new(oldSpans.ToArray(), newSpans.ToArray()); }
        var lcs = new int[height * width];
        for (var i = height - 2; i >= 0; i--)
            for (var j = width - 2; j >= 0; j--)
                lcs[i * width + j] = old[prefix + i] == next[prefix + j] ? 1 + lcs[(i + 1) * width + j + 1] : Math.Max(lcs[(i + 1) * width + j], lcs[i * width + j + 1]);
        var x = 0; var y = 0; var oldStart = 0; var newStart = 0;
        while (x < height - 1 || y < width - 1)
        {
            if (x < height - 1 && y < width - 1 && old[prefix + x] == next[prefix + y])
            { Add(prefix + oldStart, prefix + x, prefix + newStart, prefix + y); x++; y++; oldStart = x; newStart = y; }
            else if (x < height - 1 && (y == width - 1 || lcs[(x + 1) * width + y] >= lcs[x * width + y + 1])) x++;
            else y++;
        }
        Add(prefix + oldStart, prefix + x, prefix + newStart, prefix + y);
        return new(oldSpans.ToArray(), newSpans.ToArray());
    }
}
