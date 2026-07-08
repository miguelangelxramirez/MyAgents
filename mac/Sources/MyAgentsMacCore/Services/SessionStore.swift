import Foundation
import Combine

/// Thin `ObservableObject` wrapper around `SessionScanner` for SwiftUI consumption.
///
/// Hito 0 keeps this deliberately dumb: a manual `refresh()`, no polling timer, no ordering
/// policy. The live-refresh loop, attention-first ordering and process-liveness join are Hito 1
/// work once the real popover UI needs them (CONTEXT.md §4).
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [Session] = []

    private let scanner: SessionScanner

    public init(scanner: SessionScanner = SessionScanner()) {
        self.scanner = scanner
    }

    public func refresh() {
        sessions = scanner.scanSessions()
    }
}
