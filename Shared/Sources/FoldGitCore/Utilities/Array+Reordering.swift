public extension Array {
    func movingElements(at offsets: Set<Int>, to destination: Int) -> Self {
        precondition((0...count).contains(destination))
        precondition(offsets.allSatisfy { indices.contains($0) })
        let selected = offsets.sorted().map { self[$0] }
        var remaining = enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: selected, at: insertion)
        return remaining
    }
}
