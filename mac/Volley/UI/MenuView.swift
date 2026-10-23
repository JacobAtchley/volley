import SwiftUI

struct MenuView: View {
    let session: PhoneSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pairing
            if session.newNotificationCount > 0 { notifications }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(Color.shell)
        .foregroundStyle(Color.ink)
    }

    // MARK: Sections

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            VolleyMark().frame(width: 28, height: 28)
            Text("volley").font(.system(size: 20, weight: .bold))
            Spacer()
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.callout).foregroundStyle(Color.muted)
        }
        Button {
            MainWindow.show(session: session)
        } label: {
            Label("Open Volley", systemImage: "bubble.left.and.bubble.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(.coral).foregroundStyle(Color.onCoral)
    }

    @ViewBuilder
    private var pairing: some View {
        if let code = session.pairingCode {
            card {
                Text("Enter this code on your phone").font(.callout).foregroundStyle(Color.muted)
                Text("\(code.prefix(3)) \(code.suffix(3))")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                Button("Cancel") { session.cancelPairing() }.buttonStyle(.link)
            }
        } else if session.pairedDevices.isEmpty {
            card {
                Text("Install Volley on your Android phone, then pair it with this Mac.")
                    .font(.callout).foregroundStyle(Color.muted)
                Button("Pair a phone") { session.startPairing() }
                    .buttonStyle(.borderedProminent).tint(.coral).foregroundStyle(Color.onCoral)
            }
        }
    }

    private var notifications: some View {
        let n = session.newNotificationCount
        return Button {
            MainWindow.show(session: session, area: .notifications)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge").foregroundStyle(Color.coral)
                Text("\(n) new notification\(n == 1 ? "" : "s")").font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.muted)
            }
            .padding(10)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.pairedDevices) { device in
                HStack {
                    Image(systemName: "iphone.gen3").foregroundStyle(Color.muted)
                    Text(device.name).font(.callout)
                    Spacer()
                    Button("Unpair") { session.unpair(device) }.buttonStyle(.link)
                }
            }
            HStack {
                if !session.pairedDevices.isEmpty && session.pairingCode == nil {
                    Button("Pair another phone") { session.startPairing() }.buttonStyle(.link)
                }
                Spacer()
                Button("Quit Volley") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.muted)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusText: String {
        switch session.status {
        case .starting: "Starting"
        case .waiting: session.pairedDevices.isEmpty ? "Not paired" : "Waiting for phone"
        case .connected(let name): name
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        if case .connected = session.status { return .green }
        if case .failed = session.status { return .red }
        return .muted
    }
}

/// The Volley mark: an arc served from one dot to another.
struct VolleyMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 64
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 15 * s), with: .color(.coral))
            var arc = Path()
            arc.move(to: CGPoint(x: 13 * s, y: 45 * s))
            arc.addQuadCurve(to: CGPoint(x: 51 * s, y: 45 * s), control: CGPoint(x: 32 * s, y: 4 * s))
            ctx.stroke(arc, with: .color(.onCoral), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))
            for x in [13.0, 51.0] {
                let r = 5 * s
                let dot = CGRect(x: x * s - r, y: 45 * s - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: dot), with: .color(.onCoral))
            }
        }
        .accessibilityHidden(true)
    }
}
