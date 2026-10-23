import SwiftUI

@main
struct VolleyApp: App {
    @State private var session = Composition.makeSession()

    var body: some Scene {
        MenuBarExtra {
            MenuView(session: session)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Composition root. Swap the transport here to add a relay later.
@MainActor
enum Composition {
    static func makeSession() -> PhoneSession {
        let identity = MacIdentity.load()
        let transport = LanServer(
            serviceName: identity.name,
            txt: ["id": identity.id, "name": identity.name, "v": "1"],
            port: 47_823
        )
        let trust = HashedTrustStore(legacy: KeychainLegacyTokens())
        // A Keychain read can block on a password prompt; never do it on the main thread.
        DispatchQueue.global(qos: .utility).async { trust.migrateLegacyTokens() }
        let notifier = UserNotifier()
        let session = PhoneSession(
            identity: identity,
            transport: transport,
            trust: trust,
            notifier: notifier,
            store: makeStore()
        )
        let files = FileSession(link: session)
        session.files = files
        session.onFileMessage = { files.handle(type: $0, data: $1) }
        session.onBinary = { files.handleBinary($0) }
        session.onDisconnect = { files.disconnected() }
        notifier.onOpen = { [weak session] address in
            guard let session else { return }
            MainWindow.show(session: session, threadId: session.threadId(forAddress: address))
        }
        // Unit tests host the app; don't advertise or listen while they run.
        if NSClassFromString("XCTestCase") == nil { session.start() }
        return session
    }

    private static func makeStore() -> MessageStore {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("Volley", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try GRDBMessageStore(path: dir.appendingPathComponent("volley.sqlite").path)
        } catch {
            // Keep working for this launch rather than refusing to start.
            return GRDBMessageStore.inMemory()
        }
    }
}
