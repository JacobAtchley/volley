import AppKit
import Foundation
import Observation

/// What `FileSession` needs from the phone connection.
@MainActor
protocol FileLink: AnyObject {
    var isConnected: Bool { get }
    @discardableResult func sendMessage<B: Encodable>(_ type: String, _ body: B) -> Bool
    @discardableResult func sendBinary(_ data: Data) -> Bool
}

struct TransferItem: Identifiable, Equatable {
    enum Direction { case download, upload }
    enum State: Equatable { case queued, running, done, failed(String), cancelled }

    let id: UUID
    let direction: Direction
    var name: String
    var size: Int64
    var transferred: Int64 = 0
    var state: State = .queued
}

enum FilesViewMode: String { case list, icons }

/// Browses the phone's shared storage and runs file transfers, one at a time.
@MainActor
@Observable
final class FileSession {
    private(set) var path = ""
    private(set) var entries: [FsEntry] = []
    private(set) var loading = false
    private(set) var error: String?
    /// nil until the phone reports it (an older phone build never does).
    private(set) var allFilesAccess: Bool?
    var showHidden = false {
        didSet { refresh() }
    }
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var transfers: [TransferItem] = []
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private let link: FileLink
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tempDir: URL
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var forwardStack: [String] = []
    @ObservationIgnored private var listRequest: String?
    @ObservationIgnored private var listWaiters: [String: CheckedContinuation<[FsEntry]?, Never>] = [:]
    @ObservationIgnored private var thumbRequests: [String: String] = [:]
    private typealias DeleteWaiter = (paths: [String], cont: CheckedContinuation<[FsDeleteFailure], Never>)
    @ObservationIgnored private var deleteWaiters: [String: DeleteWaiter] = [:]
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private var active: Active?

    private enum Job {
        /// `then` gets the saved file, or nil if the download failed or was cancelled.
        case download(remote: String, into: URL, then: ((URL?) -> Void)?)
        case upload(local: URL, dir: String)
    }

    /// The transfer currently on the wire.
    private struct Active {
        let id: UUID
        var receiver: ChunkReceiver?
        var sender: ChunkSender?
        var localURL: URL?
        var endSent = false
    }

    private static let viewModesKey = "filesViewModes"
    private static let thumbPx = 256

    init(link: FileLink, defaults: UserDefaults = .standard, tempDir: URL? = nil,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.link = link
        self.defaults = defaults
        self.tempDir = tempDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Volley/\(UUID().uuidString)", isDirectory: true)
        self.openURL = open
    }

    // MARK: - Browsing

    func open(path newPath: String) {
        if newPath != path {
            backStack.append(path)
            forwardStack.removeAll()
        }
        navigate(to: newPath)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        navigate(to: previous)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        navigate(to: next)
    }

    func refresh() {
        let id = UUID().uuidString
        listRequest = id
        loading = true
        error = nil
        if !link.sendMessage(MsgType.fsList, FsList(requestId: id, path: path, showHidden: showHidden)) {
            loading = false
            error = "Phone offline"
        }
    }

    func requestThumbnail(for entryPath: String) {
        guard thumbnails[entryPath] == nil, !thumbRequests.values.contains(entryPath) else { return }
        let id = UUID().uuidString
        thumbRequests[id] = entryPath
        link.sendMessage(MsgType.fsThumb, FsThumb(requestId: id, path: entryPath, maxPx: Self.thumbPx))
    }

    func viewMode(for folder: String) -> FilesViewMode {
        let modes = defaults.dictionary(forKey: Self.viewModesKey) as? [String: String] ?? [:]
        return modes[folder].flatMap(FilesViewMode.init(rawValue:)) ?? .list
    }

    func setViewMode(_ mode: FilesViewMode, for folder: String) {
        var modes = defaults.dictionary(forKey: Self.viewModesKey) as? [String: String] ?? [:]
        modes[folder] = mode.rawValue
        defaults.set(modes, forKey: Self.viewModesKey)
    }

    /// Joins the current folder and a child name into a phone path.
    func childPath(_ name: String) -> String { path.isEmpty ? name : "\(path)/\(name)" }

    // MARK: - Actions

    func delete(_ paths: [String]) async -> [FsDeleteFailure] {
        let id = UUID().uuidString
        let failed = await withCheckedContinuation { cont in
            deleteWaiters[id] = (paths, cont)
            if !link.sendMessage(MsgType.fsDelete, FsDelete(requestId: id, paths: paths)) {
                deleteWaiters[id] = nil
                cont.resume(returning: paths.map { FsDeleteFailure(path: $0, error: "Phone offline") })
            }
        }
        refresh()
        return failed
    }

    /// Downloads phone paths (files or folders) into a Mac folder.
    func download(_ paths: [String], to dir: URL, then: ((URL?) -> Void)? = nil) {
        for remote in paths {
            let name = (remote as NSString).lastPathComponent
            if entries.first(where: { childPath($0.name) == remote })?.isDir == true {
                Task { await downloadFolder(remote, into: dir) }
            } else {
                enqueue(.download(remote: remote, into: dir, then: then), name: name, size: 0, direction: .download)
            }
        }
    }

    /// Uploads Mac files or folders into a phone folder. Dotfiles inside folders (e.g. .DS_Store) are skipped.
    func upload(_ urls: [URL], into dir: String) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                uploadFolder(url, into: dir)
            } else {
                enqueue(.upload(local: url, dir: dir), name: url.lastPathComponent, size: Self.size(of: url),
                        direction: .upload)
            }
        }
    }

    func openInDefaultApp(_ remote: String) {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        enqueue(.download(remote: remote, into: tempDir, then: { [openURL] url in url.map(openURL) }),
                name: (remote as NSString).lastPathComponent, size: 0, direction: .download)
    }

    func cancel(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch transfers[index].state {
        case .queued:
            transfers[index].state = .cancelled
            finishJob(id, url: nil)
        case .running:
            link.sendMessage(MsgType.fsCancel, FsCancel(transferId: id.uuidString))
            abandonActive(deletePartial: true)
            transfers[index].state = .cancelled
            finishJob(id, url: nil)
            startNext()
        default:
            break
        }
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .queued && $0.state != .running }
    }

    // MARK: - Incoming

    func handle(type: String, data: Data) {
        switch type {
        case MsgType.fsStatus:
            guard let s = Codec.body(FsStatus.self, from: data) else { return }
            let gained = s.allFilesAccess && allFilesAccess != true
            allFilesAccess = s.allFilesAccess
            if gained { refresh() }
        case MsgType.fsListing:
            guard let l = Codec.body(FsListing.self, from: data) else { return }
            applyListing(l)
        case MsgType.fsThumbData:
            Codec.body(FsThumbData.self, from: data).map(applyThumbnail)
        case MsgType.fsDeleted:
            guard let d = Codec.body(FsDeleted.self, from: data) else { return }
            deleteWaiters.removeValue(forKey: d.requestId)?.cont.resume(returning: d.failed ?? [])
        case MsgType.fsBegin:
            guard let b = Codec.body(FsBegin.self, from: data) else { return }
            beginDownload(b)
        case MsgType.fsUploadReady:
            guard let r = Codec.body(FsUploadReady.self, from: data) else { return }
            beginUpload(r)
        case MsgType.fileAck:
            guard let a = Codec.body(FileAck.self, from: data) else { return }
            ack(a)
        case MsgType.fsEnd:
            guard let e = Codec.body(FsEnd.self, from: data) else { return }
            endDownload(e)
        case MsgType.fsDone:
            guard let d = Codec.body(FsDone.self, from: data) else { return }
            done(d)
        case MsgType.fsCancel:
            guard let c = Codec.body(FsCancel.self, from: data), c.transferId == active?.id.uuidString else { return }
            fail("Cancelled on phone")
        default:
            break
        }
    }

    func handleBinary(_ frame: Data) {
        guard let (id, payload) = ChunkFrame.decode(frame), id == active?.id,
              let receiver = active?.receiver else { return }
        receiver.onChunk(payload)
        update(id) { $0.transferred += Int64(payload.count) }
    }

    /// The phone went away: fail everything in flight and forget its status.
    func disconnected() {
        abandonActive(deletePartial: true)
        for index in transfers.indices where transfers[index].state == .queued || transfers[index].state == .running {
            transfers[index].state = .failed("Phone disconnected")
        }
        jobs.keys.forEach { finishJob($0, url: nil) }
        listWaiters.values.forEach { $0.resume(returning: nil) }
        listWaiters.removeAll()
        deleteWaiters.values.forEach { waiter in
            waiter.cont.resume(returning: waiter.paths.map { FsDeleteFailure(path: $0, error: "Phone disconnected") })
        }
        deleteWaiters.removeAll()
        thumbRequests.removeAll()
        allFilesAccess = nil
        loading = false
    }

    // MARK: - Browsing internals

    private func applyThumbnail(_ t: FsThumbData) {
        guard let entryPath = thumbRequests.removeValue(forKey: t.requestId), let b64 = t.jpegBase64,
              let bytes = Data(base64Encoded: b64), let image = NSImage(data: bytes) else { return }
        thumbnails[entryPath] = image
    }

    private func navigate(to newPath: String) {
        path = newPath
        entries = []
        thumbnails = [:]
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        refresh()
    }

    private func applyListing(_ l: FsListing) {
        if let waiter = listWaiters.removeValue(forKey: l.requestId) {
            waiter.resume(returning: l.error == nil ? l.entries ?? [] : nil)
            return
        }
        guard l.requestId == listRequest else { return }
        listRequest = nil
        loading = false
        error = l.error
        entries = l.entries ?? []
    }

    private func listing(_ remote: String) async -> [FsEntry]? {
        let id = UUID().uuidString
        return await withCheckedContinuation { cont in
            listWaiters[id] = cont
            if !link.sendMessage(MsgType.fsList, FsList(requestId: id, path: remote, showHidden: showHidden)) {
                listWaiters[id] = nil
                cont.resume(returning: nil)
            }
        }
    }

    private func downloadFolder(_ remote: String, into dir: URL) async {
        let local = finderStyleUniqueURL(in: dir, name: (remote as NSString).lastPathComponent)
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        guard let children = await listing(remote) else { return }
        for child in children {
            let childRemote = "\(remote)/\(child.name)"
            if child.isDir {
                await downloadFolder(childRemote, into: local)
            } else {
                enqueue(.download(remote: childRemote, into: local, then: nil), name: child.name, size: child.size,
                        direction: .download)
            }
        }
    }

    private func uploadFolder(_ folder: URL, into dir: String) {
        let base = dir.isEmpty ? folder.lastPathComponent : "\(dir)/\(folder.lastPathComponent)"
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: Set(keys)).isDirectory) != true else { continue }
            let relativeDir = url.deletingLastPathComponent().path.dropFirst(folder.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = relativeDir.isEmpty ? base : "\(base)/\(relativeDir)"
            enqueue(.upload(local: url, dir: target), name: url.lastPathComponent, size: Self.size(of: url),
                    direction: .upload)
        }
    }

    // MARK: - Transfer internals

    private func enqueue(_ job: Job, name: String, size: Int64, direction: TransferItem.Direction) {
        let item = TransferItem(id: UUID(), direction: direction, name: name, size: size)
        jobs[item.id] = job
        transfers.append(item)
        startNext()
    }

    private func startNext() {
        guard active == nil, let next = transfers.first(where: { $0.state == .queued }), let job = jobs[next.id] else {
            return
        }
        active = Active(id: next.id)
        update(next.id) { $0.state = .running }
        let id = next.id.uuidString
        let sent: Bool
        switch job {
        case let .download(remote, _, _):
            sent = link.sendMessage(MsgType.fsDownload, FsDownload(transferId: id, path: remote))
        case let .upload(local, dir):
            sent = link.sendMessage(MsgType.fsUpload, FsUpload(transferId: id, dir: dir, name: local.lastPathComponent,
                                                               size: Self.size(of: local)))
        }
        if !sent { fail("Phone offline") }
    }

    private func beginDownload(_ b: FsBegin) {
        guard var current = active, current.id.uuidString == b.transferId,
              case let .download(_, dir, _) = jobs[current.id] else { return }
        let url = finderStyleUniqueURL(in: dir, name: b.name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return fail("Couldn't create \(url.lastPathComponent)")
        }
        let link = self.link
        current.localURL = url
        current.receiver = ChunkReceiver(id: current.id, output: handle) { received in
            link.sendMessage(MsgType.fileAck, FileAck(transferId: b.transferId, received: received))
        }
        active = current
        update(current.id) {
            $0.size = b.size
            $0.name = url.lastPathComponent
        }
    }

    private func endDownload(_ e: FsEnd) {
        guard let current = active, current.id.uuidString == e.transferId, let receiver = current.receiver,
              case let .download(_, _, then) = jobs[current.id] else { return }
        let ok = receiver.finish(expectedSha256: e.sha256)
        let reply = FsDone(transferId: e.transferId, ok: ok, error: ok ? nil : "Checksum mismatch")
        link.sendMessage(MsgType.fsDone, reply)
        guard ok, let url = current.localURL else { return fail("Checksum mismatch") }
        succeed()
        then?(url)
    }

    private func beginUpload(_ r: FsUploadReady) {
        guard var current = active, current.id.uuidString == r.transferId,
              case let .upload(local, _) = jobs[current.id] else { return }
        guard let handle = try? FileHandle(forReadingFrom: local) else {
            return fail("Couldn't read \(local.lastPathComponent)")
        }
        let link = self.link
        current.sender = ChunkSender(id: current.id, input: handle, send: { link.sendBinary($0) })
        active = current
        update(current.id) { $0.name = r.finalName }
        pumpUpload()
    }

    private func ack(_ a: FileAck) {
        guard let current = active, current.id.uuidString == a.transferId, let sender = current.sender else { return }
        sender.onAck(a.received)
        update(current.id) { item in
            item.transferred = min(item.size, Int64(a.received) * Int64(ChunkFrame.chunk))
        }
        pumpUpload()
    }

    private func pumpUpload() {
        guard var current = active, let sender = current.sender else { return }
        if sender.pump(), !current.endSent {
            current.endSent = true
            active = current
            link.sendMessage(MsgType.fsEnd, FsEnd(transferId: current.id.uuidString, sha256: sender.sha256Hex))
        }
    }

    private func done(_ d: FsDone) {
        guard let current = active, current.id.uuidString == d.transferId else { return }
        if d.ok {
            update(current.id) { $0.transferred = $0.size }
            let dir: String? = if case let .upload(_, dir) = jobs[current.id] { dir } else { nil }
            succeed()
            if let dir, dir == path { refresh() }
        } else {
            fail(d.error ?? "Failed on phone")
        }
    }

    private func succeed() {
        guard let current = active else { return }
        update(current.id) { $0.state = .done }
        jobs[current.id] = nil
        active = nil
        startNext()
    }

    private func fail(_ message: String) {
        guard let current = active else { return }
        // Tell the phone so it stops sending and releases the file (harmless if it already knows).
        link.sendMessage(MsgType.fsCancel, FsCancel(transferId: current.id.uuidString))
        abandonActive(deletePartial: true)
        update(current.id) { $0.state = .failed(message) }
        finishJob(current.id, url: nil)
        startNext()
    }

    /// Drops a job, telling a waiting download it won't produce a file.
    private func finishJob(_ id: UUID, url: URL?) {
        if case let .download(_, _, then) = jobs.removeValue(forKey: id), url == nil { then?(nil) }
    }

    private func abandonActive(deletePartial: Bool) {
        guard let current = active else { return }
        current.receiver?.abandon()
        current.sender?.close()
        if deletePartial, current.receiver != nil, let url = current.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        active = nil
    }

    private func update(_ id: UUID, _ change: (inout TransferItem) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

/// Finder-style free name in `dir`: `photo.jpg` → `photo 2.jpg`, `README` → `README 2`.
func finderStyleUniqueURL(in dir: URL, name: String) -> URL {
    let first = dir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: first.path) else { return first }
    let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
    let base = dot.map { String(name[..<$0]) } ?? name
    let ext = dot.map { String(name[$0...]) } ?? ""
    var n = 2
    while true {
        let candidate = dir.appendingPathComponent("\(base) \(n)\(ext)")
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}
