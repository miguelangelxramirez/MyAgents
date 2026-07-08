import Foundation
import Combine

/// UI preferences persisted in `UserDefaults`. Only "show usage" today (default OFF, matching the
/// Windows product); the popover corner is N/A on macOS (menu-bar app, no free-floating widget).
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let showUsage = "showUsage"
    }

    /// Whether the usage section (Claude/Codex 5h/7d bars) and the menu-bar % badge are shown.
    /// Defaults to `false` — `UserDefaults.bool(forKey:)` returns `false` for an unset key, which
    /// is exactly the desired default, so no explicit registration is needed.
    @Published var showUsage: Bool {
        didSet { defaults.set(showUsage, forKey: Keys.showUsage) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showUsage = defaults.bool(forKey: Keys.showUsage)
    }
}
