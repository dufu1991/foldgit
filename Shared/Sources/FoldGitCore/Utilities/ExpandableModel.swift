import Foundation

public struct ExpandableModel<Model: Hashable>: Hashable {
    public init(isExpanded: Bool, model: Model) {
        self.isExpanded = isExpanded
        self.model = model
    }

    public var isExpanded: Bool
    public var model: Model
}

extension Array where Element: Hashable {
    public func withExpansionState(from old: [ExpandableModel<Element>], defaultIsExpanded: Bool = true) -> [ExpandableModel<Element>] {
        let states = Dictionary(old.map { ($0.model, $0.isExpanded) }, uniquingKeysWith: { first, _ in first })
        return map { ExpandableModel(isExpanded: states[$0] ?? defaultIsExpanded, model: $0) }
    }
}

extension Array where Element: Hashable & Identifiable {
    /// Identifiable models keep their state when their content changes, such as a refreshed file diff.
    public func withExpansionState(from old: [ExpandableModel<Element>], defaultIsExpanded: Bool = true) -> [ExpandableModel<Element>] {
        let states = Dictionary(old.map { ($0.model.id, $0.isExpanded) }, uniquingKeysWith: { first, _ in first })
        return map { ExpandableModel(isExpanded: states[$0.id] ?? defaultIsExpanded, model: $0) }
    }
}

extension Array {
    public func settingExpansion<Model>(_ isExpanded: Bool) -> Self where Element == ExpandableModel<Model> {
        map { ExpandableModel(isExpanded: isExpanded, model: $0.model) }
    }
}

extension ExpandableModel: Sendable where Model: Sendable {}
