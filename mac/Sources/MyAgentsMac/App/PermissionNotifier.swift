import AppKit
import UserNotifications
import os
import MyAgentsMacCore

/// Bridges the pure `PermissionNotificationDetector` to `UNUserNotificationCenter`: on the rising
/// edge of a session entering `permission`, it posts a banner + sound, and it presents banners
/// while the app is frontmost (`willPresent`).
///
/// Not `@MainActor`: `UNUserNotificationCenterDelegate` is a nonisolated protocol and the center is
/// thread-safe. The mutable detector is only ever touched through `handle(sessions:)`, which the
/// owner (`AppDelegate`) calls serially on the main thread.
final class PermissionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var detector = PermissionNotificationDetector()
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "PermissionNotifier")

    /// Set the delegate BEFORE requesting authorization / before launch completes (per
    /// HITO1_DESIGN and Apple's guidance), then ask for alert + sound.
    func configure() {
        center.delegate = self
        // Capture the Sendable `Logger` (not `self`) so the `@Sendable` completion handler stays
        // free of the non-Sendable `PermissionNotifier`.
        let logger = self.logger
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Notification authorization granted=\(granted, privacy: .public)")
            }
        }
    }

    /// Called on every poll with the latest sessions; fires a banner only for genuinely new
    /// permission requests (edge-detected, so no repeats while a request stays open).
    func handle(sessions: [Session]) {
        for session in detector.newlyAwaitingPermission(sessions) {
            post(for: session)
        }
    }

    private func post(for session: Session) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.permission.title", defaultValue: "Permission requested")
        let label = session.name.isEmpty ? session.folder : session.name
        content.body = label.isEmpty
            ? String(localized: "notification.permission.body-generic", defaultValue: "A session is waiting for your approval.")
            : String(localized: "notification.permission.body", defaultValue: "\(label) is waiting for your approval.")
        content.sound = .default

        // Unique id per edge so a re-request after an answer isn't coalesced with the old one.
        let request = UNNotificationRequest(
            identifier: "permission-\(session.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        let logger = self.logger
        center.add(request) { error in
            if let error {
                logger.error("Failed to post permission notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the banner + sound even when MyAgents is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
