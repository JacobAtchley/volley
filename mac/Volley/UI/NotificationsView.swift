import SwiftUI

/// Notification history for the current phone: New since you last looked, then Earlier; fuzzy search.
struct NotificationList: View {
    let session: PhoneSession
    @Binding var selection: StoredNotification.ID?
    @State private var query = ""
    @State private var showingExcluded = false
    @State private var confirmingDismissAll = false

    var body: some View {
        let results = FuzzySearch.search(query, in: session.notificationHistory)
        Group {
            if session.notificationHistory.isEmpty {
                Placeholder(text: "No notifications yet")
            } else if results.isEmpty {
                Placeholder(text: "No matches")
            } else {
                List(selection: $selection) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty, let since = session.newSince {
                        let new = results.filter { $0.receivedAt > since }
                        let earlier = results.filter { $0.receivedAt <= since }
                        if !new.isEmpty { Section("New") { rows(new) } }
                        if !earlier.isEmpty { Section("Earlier") { rows(earlier) } }
                    } else {
                        rows(results)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search notifications")
        .toolbar {
            Button {
                confirmingDismissAll = true
            } label: {
                Label("Dismiss All", systemImage: "bell.slash")
            }
            .disabled(!session.isConnected || session.undismissedCount == 0)
            .help(session.isConnected ? "Dismiss every notification still showing on your phone" : "Phone offline")
            Button {
                showingExcluded = true
            } label: {
                Label("Mirrored Apps…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Choose apps whose notifications aren't mirrored")
        }
        .sheet(isPresented: $showingExcluded) { ExcludedAppsSheet(session: session) }
        .confirmationDialog(dismissAllTitle, isPresented: $confirmingDismissAll, titleVisibility: .visible) {
            Button("Dismiss All", role: .destructive) { session.dismissAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be cleared from your phone and from Notification Center on this Mac. History is kept.")
        }
    }

    private var dismissAllTitle: String {
        let n = session.undismissedCount
        return "Dismiss \(n) notification\(n == 1 ? "" : "s") on your phone?"
    }

    private func rows(_ items: [StoredNotification]) -> some View {
        ForEach(items) { n in
            NotificationRow(notification: n)
                .tag(n.id)
                .contextMenu {
                    Button("Don't Mirror \(n.appName)") {
                        session.setExcluded(AppRef(pkg: n.pkg, name: n.appName), true)
                    }
                }
        }
    }
}

private struct NotificationRow: View {
    let notification: StoredNotification

    var body: some View {
        let n = notification
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "app.badge").font(.caption)
                Text(n.appName).font(.caption.weight(.semibold))
                Spacer()
                Text(shortTime(n.postedAt)).font(.caption)
            }
            .foregroundStyle(.secondary)
            if !n.title.isEmpty { Text(n.title).font(.headline).lineLimit(1) }
            if !n.text.isEmpty { Text(n.text).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.vertical, 3)
        .opacity(n.cleared ? 0.55 : 1)
    }
}

struct NotificationDetail: View {
    let session: PhoneSession
    let notification: StoredNotification

    var body: some View {
        let n = notification
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "app.badge").foregroundStyle(Color.muted)
                    Text(n.appName).font(.headline)
                    Spacer()
                    Text(n.postedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !n.title.isEmpty {
                    Text(n.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                }
                if !n.text.isEmpty {
                    Text(n.text).font(.body).textSelection(.enabled)
                }
                Divider()
                if n.cleared {
                    Label("Cleared on phone", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else if session.isConnected {
                    Button("Dismiss on Phone") { session.dismiss(key: n.key) }
                } else {
                    Label("Phone offline", systemImage: "iphone.slash").foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.shell)
        .foregroundStyle(Color.cocoa)
    }
}

/// Apps whose notifications Volley mirrors. Turning one off stops the phone forwarding it and hides its history.
struct ExcludedAppsSheet: View {
    let session: PhoneSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let apps = session.seenApps().filter { query.isEmpty || FuzzySearch.score(query, in: $0.name) != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Mirrored Apps").font(.title3.weight(.semibold))
            Text("Turn off apps that already notify you on this Mac, like Slack or Telegram.")
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
            if apps.isEmpty {
                Placeholder(text: query.isEmpty ? "Apps appear here after they send a notification" : "No matches")
            } else {
                List(apps) { app in
                    Toggle(isOn: Binding(get: { !session.excludedApps.contains(app) },
                                         set: { session.setExcluded(app, !$0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.pkg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 460)
    }
}
