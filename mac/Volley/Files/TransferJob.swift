import Foundation

/// One queued transfer in `FileSession`.
enum TransferJob {
    /// `then` gets the saved file, or nil if the download failed or was cancelled.
    case download(remote: String, into: URL, then: ((URL?) -> Void)?)
    case upload(local: URL, dir: String)
    /// An MMS part (photo, vCard…) from the phone's message store.
    case mmsPart(partId: Int64, into: URL, then: ((URL?) -> Void)?)
    /// A photo for an MMS reply, kept in the phone's cache until `mms.send`; `then` gets the transfer id.
    case mmsAttach(local: URL, then: (String?) -> Void)

    var downloadDir: URL? {
        switch self {
        case let .download(_, dir, _), let .mmsPart(_, dir, _): dir
        default: nil
        }
    }

    var downloadThen: ((URL?) -> Void)? {
        switch self {
        case let .download(_, _, then), let .mmsPart(_, _, then): then
        default: nil
        }
    }

    var uploadSource: URL? {
        switch self {
        case let .upload(local, _), let .mmsAttach(local, _): local
        default: nil
        }
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
