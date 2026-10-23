import CryptoKit
import Foundation

/// Binary frame: 16-byte transfer id, then the chunk bytes. See docs/PROTOCOL.md.
enum ChunkFrame {
    static let chunk = 262_144
    private static let header = 16

    static func encode(_ id: UUID, _ payload: Data) -> Data {
        var frame = withUnsafeBytes(of: id.uuid) { Data($0) }
        frame.append(payload)
        return frame
    }

    static func decode(_ frame: Data) -> (UUID, Data)? {
        guard frame.count >= header else { return nil }
        let bytes = [UInt8](frame.prefix(header))
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return (id, Data(frame.dropFirst(header)))
    }
}

/// Streams a file as chunk frames, keeping at most `window` chunks unacknowledged so neither side buffers
/// a whole file. `send` returning false keeps the chunk for the next `pump()`.
final class ChunkSender {
    let id: UUID
    private let input: FileHandle
    private let send: (Data) -> Bool
    private let window: Int
    private let chunk: Int
    private var hasher = SHA256()
    private var sent = 0
    private var acked = 0
    private var pending: Data?
    private var eof = false
    private var hex: String?

    init(id: UUID, input: FileHandle, send: @escaping (Data) -> Bool, window: Int = 8, chunk: Int = ChunkFrame.chunk) {
        self.id = id
        self.input = input
        self.send = send
        self.window = window
        self.chunk = chunk
    }

    /// True once every chunk has been handed to the transport.
    @discardableResult
    func pump() -> Bool {
        while sent - acked < window {
            guard let frame = pending ?? nextFrame() else { break }
            guard send(frame) else {
                pending = frame
                return false
            }
            pending = nil
            sent += 1
        }
        return eof && pending == nil
    }

    func onAck(_ received: Int) { acked = max(acked, received) }

    var done: Bool { eof && pending == nil && acked >= sent }

    /// Releases the file (cancel or disconnect).
    func close() { try? input.close() }

    /// Hex SHA-256 of everything read; valid once `pump()` has returned true.
    var sha256Hex: String {
        if let hex { return hex }
        let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        hex = value
        return value
    }

    private func nextFrame() -> Data? {
        guard !eof else { return nil }
        let data = (try? input.read(upToCount: chunk)) ?? Data()
        if data.count < chunk {
            eof = true
            try? input.close()
        }
        guard !data.isEmpty else { return nil }
        hasher.update(data: data)
        return ChunkFrame.encode(id, data)
    }
}

/// Writes incoming chunks to a file, acking the running count after each.
final class ChunkReceiver {
    let id: UUID
    private let output: FileHandle
    private let ack: (Int) -> Void
    private var hasher = SHA256()
    private var received = 0
    private var writeFailed = false

    init(id: UUID, output: FileHandle, ack: @escaping (Int) -> Void) {
        self.id = id
        self.output = output
        self.ack = ack
    }

    func onChunk(_ data: Data) {
        do {
            try output.write(contentsOf: data)
        } catch {
            writeFailed = true // e.g. disk full: the file on disk won't match, whatever the checksum says
        }
        hasher.update(data: data)
        received += 1
        ack(received)
    }

    /// Closes the file; true when its content matches `expectedSha256`.
    func finish(expectedSha256: String) -> Bool {
        try? output.close()
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return !writeFailed && actual.caseInsensitiveCompare(expectedSha256) == .orderedSame
    }

    /// Closes the file without verifying (cancel / disconnect).
    func abandon() { try? output.close() }
}
