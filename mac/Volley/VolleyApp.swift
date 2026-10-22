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
            txt: ["id": identity.id, "name": identity.name, "v": "1"]
        )
        let session = PhoneSession(
            identity: identity,
            transport: transport,
            trust: KeychainTrustStore(),
            notifier: UserNotifier()
        )
        session.start()
        return session
    }
}
