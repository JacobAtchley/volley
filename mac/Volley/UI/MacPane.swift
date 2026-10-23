import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A Mac folder: browse, open, drag files to the Phone pane, drop phone files here to download.
struct MacPane: View {
    let mac: MacFolder
    let files: FileSession
    @State private var selection = Set<MacEntry.ID>()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let error = mac.error {
                    Placeholder(text: error)
                } else if mac.entries.isEmpty {
                    Placeholder(text: "Empty folder")
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
            .onDrop(of: [.volleyPhonePath], isTargeted: $dropTargeted) { providers in
                downloadDropped(providers, into: mac.url)
            }
        }
        .onChange(of: mac.url) { selection = [] }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").foregroundStyle(Color.coral)
            Button { mac.back() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!mac.canGoBack).help("Back")
            Button { mac.forward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(!mac.canGoForward).help("Forward")
            Text(mac.url.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                .help(mac.url.path)
            Spacer(minLength: 4)
            Menu {
                ForEach(MacFolder.places, id: \.1) { name, url in Button(name) { mac.open(url) } }
                Divider()
                Button("Up One Level") { mac.open(mac.url.deletingLastPathComponent()) }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton).fixedSize().help("Places")
            SortMenu(choice: mac.sort) { mac.sort = $0 }
            Button { mac.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var table: some View {
        Table(of: MacEntry.self, selection: $selection) {
            TableColumn("Name") { e in
                Label {
                    Text(e.name)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: e.url.path))
                        .resizable().frame(width: 16, height: 16)
                }
            }
            TableColumn("Size") { e in
                Text(e.isDir ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified") { e in Text(e.modified, format: .dateTime).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 150)
        } rows: {
            ForEach(mac.entries) { e in
                TableRow(e).itemProvider { NSItemProvider(object: e.url as NSURL) }
            }
        }
        .contextMenu(forSelectionType: MacEntry.ID.self) { ids in
            if !ids.isEmpty {
                Button("Open") { open(ids) }
                Button("Copy to “\(phoneFolderName)” on Phone") {
                    files.upload(Array(ids), into: files.path)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(ids)) }
            }
        } primaryAction: { ids in
            open(ids)
        }
    }

    private var phoneFolderName: String {
        files.path.isEmpty ? "Phone" : (files.path as NSString).lastPathComponent
    }

    private func open(_ ids: Set<URL>) {
        let chosen = mac.entries.filter { ids.contains($0.url) }
        if chosen.count == 1, let folder = chosen.first, folder.isDir { return mac.open(folder.url) }
        chosen.filter { !$0.isDir }.forEach { NSWorkspace.shared.open($0.url) }
    }

    /// Phone rows dropped here download straight into this folder.
    private func downloadDropped(_ providers: [NSItemProvider], into dir: URL) -> Bool {
        let phone = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.volleyPhonePath.identifier) }
        guard !phone.isEmpty else { return false }
        for provider in phone {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.volleyPhonePath.identifier) { data, _ in
                guard let data, let path = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in files.download([path], to: dir) }
            }
        }
        return true
    }
}

/// Sort by Name / Date Modified / Size, ascending or descending.
struct SortMenu: View {
    let choice: SortChoice
    let onChange: (SortChoice) -> Void

    var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { choice.key },
                                                 set: { onChange(SortChoice(key: $0, ascending: choice.ascending)) })) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding(get: { choice.ascending },
                                               set: { onChange(SortChoice(key: choice.key, ascending: $0)) })) {
                Text(choice.key == .date ? "Oldest First" : "Ascending").tag(true)
                Text(choice.key == .date ? "Newest First" : "Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Sort")
    }
}
