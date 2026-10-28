namespace FoldGit.Core.Workspace;

public enum WorkspaceSort { Manual, Name, LastOpened, LastModified, Added }
public sealed record RepositoryEntry(string Id, string Path, string Name, string? GroupId,
    DateTimeOffset Added, DateTimeOffset? Opened = null, bool Infrequent = false,
    bool WorktreesEnabled = false, int AutoFetchMinutes = 0);
public sealed record WorkspaceGroup(string Id, string Name);
public sealed record WorkspaceState(RepositoryEntry[] Repositories, WorkspaceGroup[] Groups)
{
    public static WorkspaceState Empty => new([], []);
    public WorkspaceState Add(string path, string identity, string? groupId = null) =>
        Repositories.Any(repository => repository.Id == identity) ? this : this with
        {
            Repositories = [.. Repositories, new(identity, path, System.IO.Path.GetFileName(System.IO.Path.TrimEndingDirectorySeparator(path)), groupId, DateTimeOffset.UtcNow)]
        };
    public WorkspaceState Group(IEnumerable<string> ids, string name)
    {
        var members = ids.ToHashSet(StringComparer.Ordinal);
        var group = new WorkspaceGroup(Guid.NewGuid().ToString(), name);
        return this with { Groups = [.. Groups, group], Repositories = Repositories.Select(repository => members.Contains(repository.Id) ? repository with { GroupId = group.Id } : repository).ToArray() };
    }
    public WorkspaceState Dissolve(string id) => this with
    {
        Groups = Groups.Where(group => group.Id != id).ToArray(),
        Repositories = Repositories.Select(repository => repository.GroupId == id ? repository with { GroupId = null } : repository).ToArray()
    };
    public WorkspaceState Move(IEnumerable<string> ids, int destination)
    {
        var selected = ids.ToHashSet(StringComparer.Ordinal);
        var moving = Repositories.Where(repository => selected.Contains(repository.Id)).ToArray();
        var remaining = Repositories.Where(repository => !selected.Contains(repository.Id)).ToList();
        var removedBefore = Repositories.Take(destination).Count(repository => selected.Contains(repository.Id));
        remaining.InsertRange(Math.Clamp(destination - removedBefore, 0, remaining.Count), moving);
        return this with { Repositories = remaining.ToArray() };
    }
    public RepositoryEntry[] Visible(string filter, WorkspaceSort sort) =>
        Sort(Repositories.Where(repository => repository.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || System.IO.Path.GetFileName(repository.Path).Contains(filter, StringComparison.OrdinalIgnoreCase)
            || Groups.Any(group => group.Id == repository.GroupId && group.Name.Contains(filter, StringComparison.OrdinalIgnoreCase))), sort).ToArray();

    private static IEnumerable<RepositoryEntry> Sort(IEnumerable<RepositoryEntry> repositories, WorkspaceSort sort) => sort switch
    {
        WorkspaceSort.Name => repositories.OrderBy(repository => repository.Name, StringComparer.CurrentCultureIgnoreCase),
        WorkspaceSort.LastOpened => repositories.OrderByDescending(repository => repository.Opened),
        WorkspaceSort.Added => repositories.OrderByDescending(repository => repository.Added),
        WorkspaceSort.LastModified => repositories.OrderByDescending(repository => Directory.Exists(repository.Path) ? Directory.GetLastWriteTimeUtc(repository.Path) : DateTime.MinValue),
        _ => repositories
    };
}
