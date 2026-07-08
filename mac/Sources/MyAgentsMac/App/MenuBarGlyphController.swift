import AppKit
import MyAgentsMacCore

/// Draws (and, only while something is busy, animates) the status-bar glyph.
///
/// The animation is a frame-swap `Timer` that re-renders the `NSImage` each tick — Core Animation
/// on a status-item button is unreliable, so we redraw the image ourselves (per HITO1_DESIGN).
/// ENERGY LAW: the timer exists ONLY while `MenuBarStatus.shouldAnimate` (i.e. `.busy`); every
/// other state sets a single static image and tears the timer down.
///
/// Fix 4 (live user feedback, 2026-07-09): the glyph no longer composes a "% badge" — usage now
/// lives only in the popover's small top summary line (`PopoverRootView`), so this controller is
/// just the state glyph again.
@MainActor
final class MenuBarGlyphController {
    private weak var button: NSStatusBarButton?
    private var status: MenuBarStatus = MenuBarStatus(kind: .idle, busyProvider: nil)

    private var animationTimer: Timer?
    private var phase: CGFloat = 0
    private var hasRendered = false

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    /// New data arrived. Re-evaluates the static/animated decision and redraws. Starting or
    /// stopping the timer is driven purely by `status.shouldAnimate`. A no-op update (same status,
    /// not animating) skips the redraw so we don't reallocate an identical `NSImage` on every poll
    /// — the animation timer owns redraws while busy.
    func update(status: MenuBarStatus) {
        let unchanged = hasRendered && status == self.status
        self.status = status
        if status.shouldAnimate {
            startAnimating()
        } else {
            stopAnimating()
        }
        if !unchanged { redraw() }
        hasRendered = true
    }

    // MARK: - Animation (energy-gated)

    private func startAnimating() {
        guard animationTimer == nil else { return }
        // ~12 fps is a calm pulse; `.common` mode keeps it alive while the user tracks a menu.
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.phase += 0.16
                self?.redraw()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        phase = 0
    }

    /// A soft breathing alpha for the busy pulse.
    private var pulseAlpha: CGFloat {
        guard status.shouldAnimate else { return 1 }
        return 0.5 + 0.5 * (0.5 + 0.5 * sin(phase))
    }

    // MARK: - Rendering

    private func redraw() {
        button?.image = symbolImage(alpha: pulseAlpha)
    }

    /// The tinted SF Symbol for the current state. Idle stays a *template* image so the system
    /// tints it to match the menu bar (the crisp, native resting look); any other state is drawn
    /// coloured (non-template) per HITO1_DESIGN.
    private func symbolImage(alpha: CGFloat) -> NSImage {
        let sizeConfig = NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Metrics.glyphPointSize,
            weight: .semibold
        )
        let base = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: accessibilityDescription)

        if status.kind == .idle {
            let image = base?.withSymbolConfiguration(sizeConfig) ?? NSImage()
            image.isTemplate = true
            return image
        }

        let tint = tintColor.withAlphaComponent(alpha)
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        let config = sizeConfig.applying(paletteConfig)
        let image = base?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }

    private var tintColor: NSColor {
        switch status.kind {
        case .attention:
            return NSColor(DesignTokens.Colors.permission)
        case .busy:
            let color = status.busyProvider == .codex
                ? DesignTokens.Colors.codexTeal
                : DesignTokens.Colors.claudeOrange
            return NSColor(color)
        case .idle:
            return NSColor(DesignTokens.Colors.idle)
        }
    }

    private var accessibilityDescription: String {
        switch status.kind {
        case .attention:
            return String(localized: "glyph.a11y.attention", defaultValue: "MyAgents — a session is awaiting permission")
        case .busy:
            return String(localized: "glyph.a11y.busy", defaultValue: "MyAgents — a session is working")
        case .idle:
            return String(localized: "glyph.a11y.idle", defaultValue: "MyAgents")
        }
    }

}
