import AppKit
import Combine
import ServiceManagement
import os
import MyAgentsMacCore

/// View-facing settings/actions state: the hook-install status the popover branches on, the
/// start-at-login state, and the handlers behind the ⚙ menu. Hook operations and the login-item
/// registration are genuine I/O, so they run off the main thread and never block the popover.
@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var hookStatus: HookInstaller.Status = .notInstalled
    @Published private(set) var startAtLoginEnabled: Bool = false
    /// A short, localized result of the last hook operation, shown transiently under the header.
    /// Never a raw `error.localizedDescription` — internal detail goes to the log (METODOLOGIA §4).
    @Published var transientMessage: String?

    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "AppViewModel")
    private var messageClearWorkItem: DispatchWorkItem?

    // MARK: - Status refresh

    func refreshStatus() {
        refreshHookStatus()
        refreshStartAtLogin()
    }

    func refreshHookStatus() {
        Task {
            let status = await Task.detached { HookInstaller().status() }.value
            self.hookStatus = status
        }
    }

    private func refreshStartAtLogin() {
        startAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Hook operations (off-main)

    func installHooks() {
        runHookOperation(
            successMessage: String(localized: "hooks.result.installed", defaultValue: "Tracking enabled"),
            failureMessage: String(localized: "hooks.result.install-failed", defaultValue: "Couldn't enable tracking")
        ) { try HookInstaller().install() }
    }

    func repairHooks() {
        runHookOperation(
            successMessage: String(localized: "hooks.result.repaired", defaultValue: "Tracking repaired"),
            failureMessage: String(localized: "hooks.result.repair-failed", defaultValue: "Couldn't repair tracking")
        ) { try HookInstaller().repair() }
    }

    func removeHooks() {
        runHookOperation(
            successMessage: String(localized: "hooks.result.removed", defaultValue: "Tracking removed"),
            failureMessage: String(localized: "hooks.result.remove-failed", defaultValue: "Couldn't remove tracking")
        ) { try HookInstaller().uninstall() }
    }

    private func runHookOperation(
        successMessage: String,
        failureMessage: String,
        _ operation: @escaping @Sendable () throws -> Void
    ) {
        Task {
            do {
                try await Task.detached { try operation() }.value
                show(message: successMessage)
            } catch {
                logger.error("Hook operation failed: \(error.localizedDescription, privacy: .public)")
                show(message: failureMessage)
            }
            refreshHookStatus()
        }
    }

    // MARK: - Start at login

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Start-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
            show(message: String(localized: "login.toggle-failed", defaultValue: "Couldn't change the start-at-login setting"))
        }
        // Always read the truth back from the service, never assume the write stuck.
        refreshStartAtLogin()
    }

    // MARK: - About

    func showAbout() {
        let alert = NSAlert()
        alert.messageText = String(localized: "menu.title", defaultValue: "MyAgents")
        let versionLine = String(
            localized: "about.version",
            defaultValue: "Version \(BuildInfo.version) (\(BuildInfo.buildNumber))"
        )
        let buildLine = String(
            localized: "about.build-date",
            defaultValue: "Built \(BuildInfo.buildDateDescription)"
        )
        alert.informativeText = "\(versionLine)\n\(buildLine)"
        alert.addButton(withTitle: String(localized: "about.ok", defaultValue: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Transient message

    /// Shows a short, already-localized note under the header (e.g. a click-to-focus failure).
    /// Never pass a raw `error.localizedDescription` here — internal detail goes to the log.
    func showTransientMessage(_ message: String) {
        show(message: message)
    }

    private func show(message: String) {
        transientMessage = message
        messageClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.transientMessage = nil
        }
        messageClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }
}
