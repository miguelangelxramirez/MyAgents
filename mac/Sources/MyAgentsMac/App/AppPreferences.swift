import Foundation
import Combine
import MyAgentsMacCore

/// UI preferences persisted in `UserDefaults`: whether usage is shown, and (when it is) which
/// single percentage the menu-bar glyph carries. The popover corner is N/A on macOS (menu-bar
/// app, no free-floating widget).
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let showUsage = "showUsage"
        static let menuBarUsageMetric = "menuBarUsageMetric"
    }

    /// Whether the usage section (Claude/Codex 5h/7d bars) and the menu-bar % badge are shown.
    /// Defaults to `false` — `UserDefaults.bool(forKey:)` returns `false` for an unset key, which
    /// is exactly the desired default, so no explicit registration is needed.
    @Published var showUsage: Bool {
        didSet { defaults.set(showUsage, forKey: Keys.showUsage) }
    }

    /// Which usage percentage the menu-bar glyph shows next to it (Claude/Codex × 5h/7d). Only has
    /// an effect while `showUsage` is on. Persisted as the enum's raw value; an unset/garbage key
    /// falls back to `.default` (Claude 5h).
    @Published var menuBarUsageMetric: MenuBarUsageMetric {
        didSet { defaults.set(menuBarUsageMetric.rawValue, forKey: Keys.menuBarUsageMetric) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showUsage = defaults.bool(forKey: Keys.showUsage)
        self.menuBarUsageMetric = defaults.string(forKey: Keys.menuBarUsageMetric)
            .flatMap(MenuBarUsageMetric.init(rawValue:)) ?? .default
    }
}
