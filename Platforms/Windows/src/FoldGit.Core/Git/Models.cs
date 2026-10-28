namespace FoldGit.Core.Git;

public sealed record Commit(string Hash, string[] Parents, string Author, string Email,
    DateTimeOffset Date, string Message, string Decorations)
{
    public string Subject => Message.Split('\n')[0];
    public string ShortHash => Hash[..Math.Min(8, Hash.Length)];
}

public sealed record FileStatus(string Path, string? OriginalPath, char Index, char WorkingTree, bool Conflict)
{
    public bool IsUntracked => Index == '?';
    public bool IsStaged => !IsUntracked && Index != '.';
    public bool IsUnstaged => IsUntracked || WorkingTree != '.';
}

public sealed record Branch(string Name, string Hash, bool Current, bool Remote, string Upstream);
public sealed record Stash(string Reference, string Hash, string Message);
public sealed record RepositorySnapshot(string Branch, string Head, FileStatus[] Files,
    Diff Staged, Diff Unstaged, Branch[] Branches, string[] Tags, Stash[] Stashes,
    int Ahead, int Behind, bool Merging, string MergeMessage, string[] Remotes);

public static class GitRecords
{
    public const string CommitFormat = "%H%x00%P%x00%an%x00%ae%x00%aI%x00%B%x00%D%x00";

    public static Commit[] Commits(string output)
    {
        if (output.Length == 0) return [];
        var fields = output.Split('\0');
        if (fields[^1].Trim('\r', '\n').Length != 0 || (fields.Length - 1) % 7 != 0)
            throw new GitException("Invalid commit records from Git.");
        return Enumerable.Range(0, (fields.Length - 1) / 7).Select(index =>
        {
            var i = index * 7;
            return new Commit(fields[i].TrimStart('\r', '\n'), fields[i + 1].Split(' ', StringSplitOptions.RemoveEmptyEntries),
                fields[i + 2], fields[i + 3], DateTimeOffset.Parse(fields[i + 4], System.Globalization.CultureInfo.InvariantCulture),
                fields[i + 5], fields[i + 6]);
        }).ToArray();
    }

    public static FileStatus[] Status(string output)
    {
        var fields = output.Split('\0');
        var result = new List<FileStatus>();
        for (var i = 0; i < fields.Length; i++)
        {
            var record = fields[i];
            if (record.StartsWith("? ", StringComparison.Ordinal))
                result.Add(new(record[2..], null, '?', '?', false));
            else if (record.StartsWith("1 ", StringComparison.Ordinal) || record.StartsWith("2 ", StringComparison.Ordinal) || record.StartsWith("u ", StringComparison.Ordinal))
            {
                var type = record[0];
                var parts = record.Split(' ', type == '1' ? 9 : type == '2' ? 10 : 11, StringSplitOptions.None);
                if (parts.Length != (type == '1' ? 9 : type == '2' ? 10 : 11) || parts[1].Length != 2)
                    throw new GitException("Invalid status record from Git.");
                string? original = null;
                if (type == '2')
                {
                    if (++i >= fields.Length - 1) throw new GitException("Missing rename source from Git.");
                    original = fields[i];
                }
                result.Add(new(parts[^1], original, parts[1][0], parts[1][1], type == 'u'));
            }
        }
        return result.ToArray();
    }
}
