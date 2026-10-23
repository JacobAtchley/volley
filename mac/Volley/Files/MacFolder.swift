import AppKit
import Foundation
import Observation

struct MacEntry: Identifiable, Hashable {
    let name: String
    let url: URL
    let isDir: Bool
    let size: Int64
    let modified: Date
    var id: URL { url }
}

/// The Mac side of the Files pane: one folder at a time, with history. Hidden files are skipped.
@MainActor
@Observable
final class MacFolder {
    private(set) var url: URL
    private(set) var entries: [MacEntry] = []
    private(set) var error: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// One setting for the whole pane, remembered.
    var sort: SortChoice {
        didSet {
            defaults.set(sort.raw, forKey: Self.sortKey)
            entries = sortMacEntries(entries, by: sort)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backStack: [URL] = []
    @ObservationIgnored private var forwardStack: [URL] = []

    private static let lastFolderKey = "macPaneFolder"
    private static let sortKey = "macPaneSort"

    static var places: [(String, URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs: [(String, FileManager.SearchPathDirectory)] = [
            ("Desktop", .desktopDirectory), ("Documents", .documentDirectory), ("Downloads", .downloadsDirectory),
            ("Pictures", .picturesDirectory), ("Movies", .moviesDirectory)
        ]
        let found = dirs.compactMap { name, dir in fm.urls(for: dir, in: .userDomainMask).first.map { (name, $0) } }
        return [("Home", home)] + found
    }

    /// Starts at `start`, else the last folder used, else Downloads.
    init(defaults: UserDefaults = .standard, start: URL? = nil) {
        self.defaults = defaults
        let remembered = defaults.url(forKey: Self.lastFolderKey).flatMap { url -> URL? in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
        }
        url = start ?? remembered ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        sort = defaults.string(forKey: Self.sortKey).flatMap(SortChoice.init(raw:)) ?? .byName
        refresh()
    }

    func open(_ folder: URL) {
        guard folder != url else { return refresh() }
        backStack.append(url)
        forwardStack.removeAll()
        go(to: folder)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        go(to: previous)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        go(to: next)
    }

    func refresh() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])
            let unsorted = urls.map { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return MacEntry(name: item.lastPathComponent, url: item, isDir: values?.isDirectory ?? false,
                                size: Int64(values?.fileSize ?? 0),
                                modified: values?.contentModificationDate ?? .distantPast)
            }
            entries = sortMacEntries(unsorted, by: sort)
            error = nil
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    private func go(to folder: URL) {
        url = folder
        defaults.set(folder, forKey: Self.lastFolderKey)
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        refresh()
    }
}
