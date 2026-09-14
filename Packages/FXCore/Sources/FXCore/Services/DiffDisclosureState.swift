/// Bulk disclosure is a default plus per-file exceptions. Newly refreshed
/// files honor Collapse All, and opening one file never expands the others.
public struct DiffDisclosureState: Hashable, Sendable {
    private var defaultCollapsed = false
    private var exceptions: Set<String> = []

    public init() {}

    public func isCollapsed(_ id: String) -> Bool {
        defaultCollapsed != exceptions.contains(id)
    }

    public mutating func setCollapsed(_ collapsed: Bool, for id: String) {
        if collapsed == defaultCollapsed { exceptions.remove(id) }
        else { exceptions.insert(id) }
    }

    public mutating func toggle(_ id: String) {
        setCollapsed(!isCollapsed(id), for: id)
    }

    public mutating func setAllCollapsed(_ collapsed: Bool) {
        defaultCollapsed = collapsed
        exceptions.removeAll(keepingCapacity: true)
    }
}
