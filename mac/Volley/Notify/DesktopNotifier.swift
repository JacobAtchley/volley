import Foundation
import UserNotifications

/// Shows mirrored SMS and notifications as native macOS notifications.
protocol DesktopNotifier: AnyObject {
    /// `threadId` is set for MMS notifications: the reply goes to the whole thread (a group gets an MMS).
    var onReply: (@MainActor (_ address: String, _ threadId: Int64?, _ text: String) -> Void)? { get set }
    var onDismiss: (@MainActor (_ key: String) -> Void)? { get set }
    /// The user clicked a message notification itself (not an action button).
    var onOpen: (@MainActor (_ address: String, _ threadId: Int64?) -> Void)? { get set }
    func requestAuthorization()
    func showSms(from address: String, body: String)
    func showMms(_ m: MmsReceived)
    func showNotification(_ n: MirroredNotification)
    func removeNotification(key: String)
}

final class UserNotifier: NSObject, DesktopNotifier, UNUserNotificationCenterDelegate {
    var onReply: (@MainActor (String, Int64?, String) -> Void)?
    var onDismiss: (@MainActor (String) -> Void)?
    var onOpen: (@MainActor (String, Int64?) -> Void)?

    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let smsCategory = "sms"
        static let mirrorCategory = "mirror"
        static let reply = "reply"
        static let dismiss = "dismiss"
        static func mirrored(_ key: String) -> String { "n:" + key }
    }

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ID.smsCategory,
                actions: [UNTextInputNotificationAction(identifier: ID.reply, title: "Reply", options: [],
                                                        textInputButtonTitle: "Send", textInputPlaceholder: "Message")],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: ID.mirrorCategory,
                actions: [UNNotificationAction(identifier: ID.dismiss, title: "Dismiss on phone", options: [])],
                intentIdentifiers: [], options: [])
        ])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func showSms(from address: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = address
        c.body = body
        c.sound = .default
        c.categoryIdentifier = ID.smsCategory
        c.threadIdentifier = "sms:" + address
        c.userInfo = ["address": address]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// "Ana in Ana, Bob +2" for a group; the photo stays on the phone until the chat asks for it.
    func showMms(_ m: MmsReceived) {
        let who = m.senderName ?? m.sender
        let c = UNMutableNotificationContent()
        c.title = m.title == who || m.title.isEmpty ? who : "\(who) in \(m.title)"
        c.body = m.text.isEmpty ? (m.hasPhoto ? "📷 Photo" : "MMS") : m.text
        c.sound = .default
        c.categoryIdentifier = ID.smsCategory
        c.threadIdentifier = "thread:\(m.threadId)"
        c.userInfo = ["address": m.sender, "threadId": m.threadId]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func showNotification(_ n: MirroredNotification) {
        let c = UNMutableNotificationContent()
        c.title = n.title.isEmpty ? n.appName : n.title
        c.subtitle = n.title.isEmpty ? "" : n.appName
        c.body = n.text
        c.categoryIdentifier = ID.mirrorCategory
        c.threadIdentifier = "app:" + n.appName
        c.userInfo = ["key": n.key]
        // Same identifier replaces an earlier version of the notification.
        center.add(UNNotificationRequest(identifier: ID.mirrored(n.key), content: c, trigger: nil))
    }

    func removeNotification(key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [ID.mirrored(key)])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let threadId = (info["threadId"] as? NSNumber)?.int64Value
        if response.actionIdentifier == ID.reply,
           let reply = response as? UNTextInputNotificationResponse,
           let address = info["address"] as? String {
            let text = reply.userText
            let handler = onReply
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(address, threadId, text) } }
        } else if response.actionIdentifier == ID.dismiss, let key = info["key"] as? String {
            let handler = onDismiss
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(key) } }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let address = info["address"] as? String {
            let handler = onOpen
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(address, threadId) } }
        }
        completionHandler()
    }
}
