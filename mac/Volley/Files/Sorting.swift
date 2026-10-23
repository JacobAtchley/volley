import Foundation

enum SortKey: String, Codable, CaseIterable {
    case name, date, size

    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date Modified"
        case .size: "Size"
        }
    }
}

struct SortChoice: Codable, Equatable {
    var key: SortKey
    var ascending: Bool

    static let byName = SortChoice(key: .name, ascending: true)
    static let newestFirst = SortChoice(key: .date, ascending: false)

    /// Stored as e.g. "date:desc".
    var raw: String { "\(key.rawValue):\(ascending ? "asc" : "desc")" }

    init(key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    init?(raw: String) {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let key = SortKey(rawValue: String(parts[0])) else { return nil }
        self.init(key: key, ascending: parts[1] == "asc")
    }
}

/// What the sorter needs from a phone or Mac entry.
protocol SortableEntry {
    var isDir: Bool { get }
    var name: String { get }
    var size: Int64 { get }
    var sortDate: Double { get }
}

extension FsEntry: SortableEntry {
    var sortDate: Double { Double(modified) }
}

extension MacEntry: SortableEntry {
    var sortDate: Double { modified.timeIntervalSince1970 }
}

/// Folders first, then files, each ordered by `choice`; ties fall back to name.
func sortEntries<T: SortableEntry>(_ items: [T], by choice: SortChoice) -> [T] {
    items.sorted { a, b in
        if a.isDir != b.isDir { return a.isDir }
        let byName = a.name.localizedStandardCompare(b.name)
        let order: ComparisonResult
        switch choice.key {
        case .name: order = byName
        case .size: order = compare(a.size, b.size) ?? byName
        case .date: order = compare(a.sortDate, b.sortDate) ?? byName
        }
        return choice.ascending ? order == .orderedAscending : order == .orderedDescending
    }
}

func sortMacEntries(_ entries: [MacEntry], by choice: SortChoice) -> [MacEntry] { sortEntries(entries, by: choice) }

private func compare<V: Comparable>(_ a: V, _ b: V) -> ComparisonResult? {
    a == b ? nil : (a < b ? .orderedAscending : .orderedDescending)
}
