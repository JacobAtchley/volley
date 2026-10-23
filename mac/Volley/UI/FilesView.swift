import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FsEntry: Identifiable {
    var id: String { name }
}

/// The phone's shared storage: list or icons, breadcrumbs, drag and drop both ways.
struct FilesView: View {
    let files: FileSession
    let connected: Bool

    var body: some View {
        Group {
            if !connected {
                Placeholder(text: "Phone offline")
            } else if files.allFilesAccess == nil {
                Placeholder(text: "Update Volley on your phone to browse its files")
            } else if files.allFilesAccess == false {
                Placeholder(text: "On your phone, open Volley and turn on All files access")
            } else {
                FileBrowser(files: files)
            }
        }
        .task(id: connected && files.allFilesAccess == true) {
            if connected, files.allFilesAccess == true, files.entries.isEmpty, !files.loading {
                files.open(path: files.path)
            }
        }
    }
}

private struct FileBrowser: View {
    let files: FileSession
    @State private var selection = Set<FsEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\FsEntry.name, comparator: .localizedStandard)]
    @State private var confirmingDelete: [FsEntry] = []
    @State private var deleteErrors: [FsDeleteFailure] = []
    @State private var dropTargeted = false

    private var mode: FilesViewMode { files.viewMode(for: files.path) }

    private var sorted: [FsEntry] {
        let dirs = files.entries.filter(\.isDir).sorted(using: sortOrder)
        let rest = files.entries.filter { !$0.isDir }.sorted(using: sortOrder)
        return dirs + rest
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let error = files.error {
                    Placeholder(text: error)
                } else if files.entries.isEmpty {
                    Placeholder(text: files.loading ? "Loading…" : "Empty folder")
                } else if mode == .icons {
                    iconGrid
                } else {
                    table
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.coral, style: StrokeStyle(lineWidth: 3, dash: [6]))
                        .padding(6)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                files.upload(urls, into: files.path)
                return true
            } isTargeted: { dropTargeted = $0 }
            TransferBar(files: files)
        }
        .toolbar { toolbar }
        .onDeleteCommand { askToDelete(selection) }
        .confirmationDialog(deleteTitle, isPresented: .constant(!confirmingDelete.isEmpty), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(confirmingDelete) }
            Button("Cancel", role: .cancel) { confirmingDelete = [] }
        } message: {
            Text(confirmingDelete.map(\.name).prefix(8).joined(separator: "\n")
                + (confirmingDelete.count > 8 ? "\n…and \(confirmingDelete.count - 8) more" : "")
                + "\n\nThis can't be undone.")
        }
        .alert("Some items couldn't be deleted", isPresented: .constant(!deleteErrors.isEmpty)) {
            Button("OK") { deleteErrors = [] }
        } message: {
            Text(deleteErrors.map { "\($0.path): \($0.error)" }.joined(separator: "\n"))
        }
        .onChange(of: files.path) { selection = [] }
    }

    // MARK: List

    private var table: some View {
        Table(of: FsEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { e in
                Label { Text(e.name) } icon: { Image(systemName: symbol(for: e)).foregroundStyle(Color.coral) }
            }
            TableColumn("Size", value: \.size) { e in
                Text(e.isDir ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified", value: \.modified) { e in
                Text(Date(timeIntervalSince1970: TimeInterval(e.modified) / 1000), format: .dateTime)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Kind") { e in Text(kind(of: e)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
        } rows: {
            ForEach(sorted) { e in
                TableRow(e).itemProvider { e.isDir ? nil : dragProvider(for: e) }
            }
        }
        .contextMenu(forSelectionType: FsEntry.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            open(ids)
        }
    }

    // MARK: Icons

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 16) {
                ForEach(sorted) { e in
                    IconTile(entry: e, thumbnail: files.thumbnails[files.childPath(e.name)],
                             selected: selection.contains(e.id))
                        .onAppear { if isMedia(e) { files.requestThumbnail(for: files.childPath(e.name)) } }
                        .onTapGesture(count: 2) { open([e.id]) }
                        .onTapGesture { selection = [e.id] }
                        .contextMenu { menu(for: selection.contains(e.id) ? selection : [e.id]) }
                        .onDrag { e.isDir ? NSItemProvider() : dragProvider(for: e) }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard e.isDir else { return false }
                            files.upload(urls, into: files.childPath(e.name))
                            return true
                        }
                }
            }
            .padding(16)
        }
    }

    // MARK: Toolbar and menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { files.back() } label: { Image(systemName: "chevron.left") }
                .disabled(!files.canGoBack).help("Back")
            Button { files.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!files.canGoForward).help("Forward")
        }
        ToolbarItem(placement: .principal) { breadcrumbs }
        ToolbarItemGroup {
            Menu {
                ForEach(["Download", "Pictures", "DCIM", "Documents", "Music", "Movies"], id: \.self) { place in
                    Button(place) { files.open(path: place) }
                }
                Divider()
                Toggle("Show Hidden Files", isOn: Binding(get: { files.showHidden }, set: { files.showHidden = $0 }))
            } label: {
                Label("Places", systemImage: "folder")
            }
            Picker("View", selection: Binding(get: { mode }, set: { files.setViewMode($0, for: files.path) })) {
                Image(systemName: "list.bullet").tag(FilesViewMode.list).help("List")
                Image(systemName: "square.grid.2x2").tag(FilesViewMode.icons).help("Icons")
            }
            .pickerStyle(.segmented)
            Button { files.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }
    }

    private var breadcrumbs: some View {
        let parts = files.path.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            Button("Phone") { files.open(path: "") }
                .buttonStyle(.plain)
                .fontWeight(parts.isEmpty ? .semibold : .regular)
            ForEach(parts.indices, id: \.self) { i in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Button(parts[i]) { files.open(path: parts[...i].joined(separator: "/")) }
                    .buttonStyle(.plain)
                    .fontWeight(i == parts.count - 1 ? .semibold : .regular)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func menu(for ids: Set<FsEntry.ID>) -> some View {
        let chosen = files.entries.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Open") { open(ids) }
            Button("Download to…") { downloadTo(chosen) }
            Divider()
            Button("Delete…", role: .destructive) { askToDelete(ids) }
        }
    }

    // MARK: Actions

    private func open(_ ids: Set<FsEntry.ID>) {
        let chosen = files.entries.filter { ids.contains($0.id) }
        if chosen.count == 1, let folder = chosen.first, folder.isDir {
            files.open(path: files.childPath(folder.name))
            return
        }
        chosen.filter { !$0.isDir }.forEach { files.openInDefaultApp(files.childPath($0.name)) }
    }

    private func downloadTo(_ entries: [FsEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Choose where to save \(entries.count == 1 ? entries[0].name : "\(entries.count) items")"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        files.download(entries.map { files.childPath($0.name) }, to: dir)
    }

    private func askToDelete(_ ids: Set<FsEntry.ID>) {
        confirmingDelete = files.entries.filter { ids.contains($0.id) }
    }

    private var deleteTitle: String {
        confirmingDelete.count == 1 ? "Delete “\(confirmingDelete[0].name)” from your phone?"
            : "Delete \(confirmingDelete.count) items from your phone?"
    }

    private func delete(_ entries: [FsEntry]) {
        let paths = entries.map { files.childPath($0.name) }
        confirmingDelete = []
        selection = []
        Task { deleteErrors = await files.delete(paths) }
    }

    /// Finder asks for the file when it's dropped; the download starts then and Finder copies the result.
    private func dragProvider(for e: FsEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = e.name
        let type = UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data
        let remote = files.childPath(e.name)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Volley-drag/\(UUID().uuidString)")
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { [files] completion in
            let progress = Progress(totalUnitCount: max(e.size, 1))
            Task { @MainActor in
                try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                files.download([remote], to: staging) { url in
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(url, false, url == nil ? CocoaError(.fileReadUnknown) : nil)
                }
            }
            return progress
        }
        return provider
    }

    private func isMedia(_ e: FsEntry) -> Bool {
        guard !e.isDir, let type = UTType(filenameExtension: (e.name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    private func kind(of e: FsEntry) -> String {
        if e.isDir { return "Folder" }
        return UTType(filenameExtension: (e.name as NSString).pathExtension)?.localizedDescription ?? "Document"
    }
}

func symbol(for e: FsEntry) -> String {
    if e.isDir { return "folder.fill" }
    guard let type = UTType(filenameExtension: (e.name as NSString).pathExtension) else { return "doc" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .movie) { return "film" }
    if type.conforms(to: .audio) { return "music.note" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    return "doc"
}

private struct IconTile: View {
    let entry: FsEntry
    let thumbnail: NSImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol(for: entry)).font(.system(size: 34)).foregroundStyle(Color.coral)
                }
            }
            .frame(width: 92, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            Text(entry.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(6)
        .background(selected ? Color.coral.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// Compact progress for the transfer on the wire, with cancel.
private struct TransferBar: View {
    let files: FileSession

    var body: some View {
        let running = files.transfers.first { $0.state == .running }
        let queued = files.transfers.filter { $0.state == .queued }.count
        if let running {
            HStack(spacing: 10) {
                Image(systemName: running.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(Color.coral)
                VStack(alignment: .leading, spacing: 3) {
                    Text(running.name).font(.callout).lineLimit(1)
                    ProgressView(value: Double(running.transferred), total: Double(max(running.size, 1)))
                }
                if queued > 0 { Text("+\(queued) queued").font(.caption).foregroundStyle(.secondary) }
                Button("Cancel") { files.cancel(running.id) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// Every transfer this session, newest last.
struct TransfersView: View {
    let files: FileSession

    var body: some View {
        if files.transfers.isEmpty {
            Placeholder(text: "Drag files in or out to copy them")
        } else {
            List(files.transfers) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                        .foregroundStyle(Color.coral)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).lineLimit(1)
                        status(item).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.state == .running || item.state == .queued {
                        Button { files.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Cancel")
                    }
                }
            }
            .toolbar {
                Button("Clear") { files.clearFinished() }.help("Remove finished transfers")
            }
        }
    }

    @ViewBuilder
    private func status(_ item: TransferItem) -> some View {
        switch item.state {
        case .queued: Text("Waiting")
        case .running:
            ProgressView(value: Double(item.transferred), total: Double(max(item.size, 1)))
        case .done: Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        case let .failed(message): Text(message).foregroundStyle(.red)
        case .cancelled: Text("Cancelled")
        }
    }
}
