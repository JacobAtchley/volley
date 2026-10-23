import SwiftUI

/// Messages.app-style window: the phone, its conversations, and the open chat.
struct MessagesView: View {
    let session: PhoneSession
    @State private var selectedNotification: StoredNotification.ID?

    var body: some View {
        if let device = session.currentDevice {
            NavigationSplitView {
                List(selection: Binding(get: { session.area }, set: { if let area = $0 { session.select(area: area) } })) {
                    PhoneCard(device: device, connected: session.isConnected, status: session.deviceStatus)
                        .selectionDisabled()
                    Label("SMS", systemImage: "message").tag(PhoneArea.sms)
                    Label("Notifications", systemImage: "bell")
                        .badge(session.newNotificationCount)
                        .tag(PhoneArea.notifications)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            } content: {
                Group {
                    switch session.area {
                    case .sms: ConversationList(session: session)
                    case .notifications: NotificationList(session: session, selection: $selectedNotification)
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            } detail: {
                switch session.area {
                case .sms:
                    if let threadId = session.openThreadId {
                        // New identity per conversation so a draft never carries over to another thread.
                        ChatView(session: session).id(threadId)
                    } else {
                        Placeholder(text: "Choose a conversation")
                    }
                case .notifications:
                    if let n = session.notificationHistory.first(where: { $0.id == selectedNotification }) {
                        NotificationDetail(session: session, notification: n)
                    } else {
                        Placeholder(text: "Choose a notification")
                    }
                }
            }
            .tint(.coral)
        } else {
            PairPrompt(session: session)
        }
    }
}

// MARK: - Phone

private struct PhoneCard: View {
    let device: PairedDevice
    let connected: Bool
    let status: StoredStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3").foregroundStyle(Color.muted)
                Text(device.name).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(connected ? Color.green : Color.muted).frame(width: 8, height: 8)
                    .accessibilityLabel(connected ? "Online" : "Offline")
            }
            if let s = status?.status {
                HStack(spacing: 14) {
                    Label {
                        Text("\(s.battery)%")
                    } icon: {
                        Image(systemName: s.charging ? "battery.100percent.bolt" : batterySymbol(s.battery))
                    }
                    bars("cellularbars", level: s.cellLevel, label: "Cell signal")
                    bars("wifi", level: s.wifiConnected ? s.wifiLevel : nil, label: "Wi-Fi signal")
                }
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .opacity(connected ? 1 : 0.55)
            }
            if !connected {
                Group {
                    if let seen = status?.lastSeen {
                        Text("Offline · last seen \(seen, format: .relative(presentation: .named))")
                    } else {
                        Text("Offline")
                    }
                }
                .font(.callout).foregroundStyle(Color.muted)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func bars(_ symbol: String, level: Int?, label: String) -> some View {
        if let level {
            Image(systemName: symbol, variableValue: Double(level) / 4).accessibilityLabel("\(label) \(level) of 4")
        } else {
            HStack(spacing: 2) {
                Image(systemName: symbol).foregroundStyle(Color.muted.opacity(0.5))
                Text("—").foregroundStyle(Color.muted)
            }
            .accessibilityLabel("\(label) unknown")
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Conversations

private struct ConversationList: View {
    let session: PhoneSession

    var body: some View {
        if session.conversations.isEmpty {
            Placeholder(text: session.isConnected ? "No messages today" : "No messages yet")
        } else {
            List(selection: Binding(get: { session.openThreadId }, set: { session.open(threadId: $0) })) {
                ForEach(session.conversations) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.title).font(.headline).lineLimit(1)
                            Spacer()
                            Text(shortTime(c.lastDate)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(c.lastBody).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 4)
                    .tag(c.threadId)
                }
            }
        }
    }
}

// MARK: - Chat

private struct ChatView: View {
    let session: PhoneSession
    @State private var draft = ""
    @FocusState private var composing: Bool

    private var title: String {
        session.conversations.first { $0.threadId == session.openThreadId }?.title ?? ""
    }

    private var address: String? {
        session.conversations.first { $0.threadId == session.openThreadId }?.address
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(session.openThread.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || !Calendar.current.isDate(item.date, inSameDayAs: session.openThread[i - 1].date) {
                                Text(item.date, format: .dateTime.weekday(.wide).month().day())
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.top, 10)
                            }
                            Bubble(item: item).id(item.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: session.openThread) { scrollToEnd(proxy) }
            }
            Divider()
            composer
        }
        .background(Color.shell)
        .navigationTitle(title)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(session.isConnected ? "Text message" : "Phone offline", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composing)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.muted.opacity(0.25)))
                .onKeyPress(.return, phases: .down) { press in
                    // Return sends; Shift-Return falls through and inserts a newline.
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.coral : Color.muted.opacity(0.4))
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .disabled(!session.isConnected)
        .padding(12)
        .onAppear { composing = true }
    }

    private var canSend: Bool {
        session.isConnected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let address else { return }
        session.sendSms(to: address, threadId: session.openThreadId, body: draft)
        draft = ""
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = session.openThread.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

private struct Bubble: View {
    let item: ChatItem

    var body: some View {
        HStack {
            if item.outgoing { Spacer(minLength: 60) }
            VStack(alignment: item.outgoing ? .trailing : .leading, spacing: 2) {
                Text(item.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(item.outgoing ? Color.coral : Color.blush, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(Color.cocoa)
                    .opacity(item.state == .sending ? 0.6 : 1)
                HStack(spacing: 4) {
                    if item.state == .failed {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text("Not sent").foregroundStyle(.red)
                    } else {
                        Text(item.date, format: .dateTime.hour().minute())
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !item.outgoing { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Empty states

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text).font(.title3).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PairPrompt: View {
    let session: PhoneSession

    var body: some View {
        VStack(spacing: 14) {
            VolleyMark().frame(width: 56, height: 56)
            if let code = session.pairingCode {
                Text("Enter this code on your phone").foregroundStyle(Color.muted)
                Text("\(code.prefix(3)) \(code.suffix(3))").font(.system(size: 40, weight: .bold, design: .monospaced))
                Button("Cancel") { session.cancelPairing() }.buttonStyle(.link)
            } else {
                Text("Install Volley on your Android phone, then pair it with this Mac.").foregroundStyle(Color.muted)
                Button("Pair a phone") { session.startPairing() }
                    .buttonStyle(.borderedProminent).tint(.coral).foregroundStyle(Color.cocoa)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.shell)
        .foregroundStyle(Color.cocoa)
    }
}

/// Time for today, weekday within a week, else a short date.
func shortTime(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
}
