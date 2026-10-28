using FoldGit.Core.Git;

namespace FoldGit.Core.History;

public enum GraphPosition { Top, Node, Bottom, Boundary }
public sealed record GraphSegment(int From, int To, GraphPosition Start, GraphPosition End, int Color, bool Boundary = false);
public sealed record GraphCommit(Commit Commit, int Column, int Row, int Color, GraphSegment[] Segments)
{
    public int Columns => Segments.Select(segment => Math.Max(segment.From, segment.To)).Append(Column).Max() + 1;
}

public static class CommitGraph
{
    private sealed record Lane(string Target, int Color);
    public static GraphCommit[] Layout(IReadOnlyList<Commit> commits)
    {
        var visible = commits.Select(commit => commit.Hash).ToHashSet(StringComparer.Ordinal);
        var lanes = new List<Lane?>();
        var nextColor = 0;
        var result = new List<GraphCommit>();
        int Allocate(int? reserved = null)
        {
            var used = lanes.Where(lane => lane is not null).Select(lane => lane!.Color % 8).ToHashSet();
            if (reserved.HasValue) used.Add(reserved.Value % 8);
            for (var i = 0; i < 8; i++) { var color = nextColor++; if (!used.Contains(color % 8)) return color; }
            return nextColor++;
        }
        foreach (var commit in commits)
        {
            var incoming = lanes.FindIndex(lane => lane?.Target == commit.Hash);
            var column = incoming >= 0 ? incoming : lanes.FindIndex(lane => lane is null);
            if (column < 0) column = lanes.Count;
            var color = incoming >= 0 ? lanes[incoming]!.Color : Allocate();
            if (column == lanes.Count) lanes.Add(null);
            var segments = lanes.Select((lane, index) => (lane, index)).Where(pair => pair.lane is not null)
                .Select(pair => new GraphSegment(pair.index, pair.lane!.Target == commit.Hash ? column : pair.index,
                    GraphPosition.Top, pair.lane.Target == commit.Hash ? GraphPosition.Node : GraphPosition.Bottom, pair.lane.Color)).ToList();
            for (var i = 0; i < lanes.Count; i++) if (lanes[i]?.Target == commit.Hash) lanes[i] = null;
            lanes[column] = null;
            var missing = false;
            for (var i = 0; i < commit.Parents.Length; i++)
            {
                var parent = commit.Parents[i];
                if (!visible.Contains(parent)) { missing = true; continue; }
                var parentColumn = column;
                var parentColor = color;
                if (i > 0)
                {
                    parentColumn = lanes.FindIndex(column + 1, lane => lane is null);
                    if (parentColumn < 0) parentColumn = lanes.Count;
                    parentColor = Allocate(color);
                }
                var lane = new Lane(parent, parentColor);
                if (parentColumn == lanes.Count) lanes.Add(lane); else lanes[parentColumn] = lane;
                segments.Add(new(column, parentColumn, GraphPosition.Node, GraphPosition.Bottom, parentColor));
            }
            if (missing) segments.Add(new(column, column, GraphPosition.Node, GraphPosition.Boundary, color, true));
            result.Add(new(commit, column, result.Count, color, segments.ToArray()));
            while (lanes.Count > 0 && lanes[^1] is null) lanes.RemoveAt(lanes.Count - 1);
        }
        return result.ToArray();
    }
}
