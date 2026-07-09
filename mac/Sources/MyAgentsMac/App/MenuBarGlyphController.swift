import AppKit
import MyAgentsMacCore

/// Claude usage to badge next to the status glyph as two tiny vertical bars (5 h · 7 d) — the
/// compact, number-free menu-bar readout Miguel picked over a "%" string. `nil` for any bucket the
/// statusline hasn't reported yet (drawn as an empty track, never a fabricated 0 %); `isStale`
/// greys both bars so an old reading can't masquerade as current.
struct MenuBarUsage: Equatable {
    var fiveHour: Double?
    var sevenDay: Double?
    var isStale: Bool

    /// Whether there's anything to draw at all (both buckets unknown → hide the badge entirely).
    var hasAnyReading: Bool { fiveHour != nil || sevenDay != nil }
}

/// Draws (and, only while something is busy, animates) the status-bar glyph, plus an optional
/// usage badge (two mini bars).
///
/// The animation is a frame-swap `Timer` that re-renders the `NSImage` each tick — Core Animation
/// on a status-item button is unreliable, so we redraw the image ourselves (per HITO1_DESIGN).
/// ENERGY LAW: the timer exists ONLY while `MenuBarStatus.shouldAnimate` (i.e. `.busy`); every
/// other state sets a single static image and tears the timer down.
@MainActor
final class MenuBarGlyphController {
    private weak var button: NSStatusBarButton?
    private var status: MenuBarStatus = MenuBarStatus(kind: .idle, busyProvider: nil)
    /// Claude 5 h/7 d usage to badge, or `nil` to hide the badge (usage disabled / all-unknown).
    private var usage: MenuBarUsage?

    private var animationTimer: Timer?
    private var phase: CGFloat = 0
    private var hasRendered = false

    // Mini-bar geometry (points). Two thin vertical bars sit to the right of the glyph.
    private enum Bar {
        static let width: CGFloat = 2.5
        static let gap: CGFloat = 2          // between the two bars
        static let leading: CGFloat = 4      // glyph → bars
        static let height: CGFloat = 11      // capped below the ~15pt glyph so it reads as a badge
        static let cornerRadius: CGFloat = 1.25
    }

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    /// New data arrived. Re-evaluates the static/animated decision and redraws. Starting or
    /// stopping the timer is driven purely by `status.shouldAnimate`. A no-op update (same status
    /// and usage, not animating) skips the redraw so we don't reallocate an identical `NSImage`
    /// on every poll — the animation timer owns redraws while busy.
    func update(status: MenuBarStatus, usage: MenuBarUsage?) {
        let effectiveUsage = (usage?.hasAnyReading ?? false) ? usage : nil
        let unchanged = hasRendered && status == self.status && effectiveUsage == self.usage
        self.status = status
        self.usage = effectiveUsage
        if status.shouldAnimate {
            startAnimating()
        } else {
            stopAnimating()
            if !unchanged { redraw() }
            hasRendered = true
            return
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
        let symbol = symbolImage(alpha: pulseAlpha, forceColored: usage != nil)
        button?.image = compose(symbol: symbol, usage: usage)
    }

    /// The tinted SF Symbol for the current state. Idle with no badge stays a *template* image so
    /// the system tints it to match the menu bar (the crisp, native resting look); any other state
    /// — or idle carrying a badge — is drawn coloured (non-template) per HITO1_DESIGN.
    private func symbolImage(alpha: CGFloat, forceColored: Bool) -> NSImage {
        let sizeConfig = NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Metrics.glyphPointSize,
            weight: .semibold
        )
        let base = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: accessibilityDescription)

        if status.kind == .idle && !forceColored {
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

    // MARK: - Composition (symbol + optional mini bars)

    /// Composites the symbol and (optional) two usage bars into one image. With no usage the symbol
    /// is returned untouched so the idle template case keeps its system tinting.
    private func compose(symbol: NSImage, usage: MenuBarUsage?) -> NSImage {
        guard let usage else { return symbol }

        let barsWidth = Bar.width * 2 + Bar.gap
        let width = symbol.size.width + Bar.leading + barsWidth
        let height = max(symbol.size.height, Bar.height)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        symbol.draw(in: NSRect(
            x: 0,
            y: (height - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        ))

        let barsOriginX = symbol.size.width + Bar.leading
        let barBottom = (height - Bar.height) / 2
        drawBar(percent: usage.fiveHour, stale: usage.isStale,
                x: barsOriginX, bottom: barBottom)
        drawBar(percent: usage.sevenDay, stale: usage.isStale,
                x: barsOriginX + Bar.width + Bar.gap, bottom: barBottom)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// One vertical bar: a faint full-height track, plus a fill from the bottom proportional to the
    /// percent consumed, coloured by `UsageLevel` (provider accent → amber → red) or greyed when
    /// the reading is stale. An unknown percent draws the track only — never a fabricated fill.
    private func drawBar(percent: Double?, stale: Bool, x: CGFloat, bottom: CGFloat) {
        let track = NSBezierPath(
            roundedRect: NSRect(x: x, y: bottom, width: Bar.width, height: Bar.height),
            xRadius: Bar.cornerRadius, yRadius: Bar.cornerRadius
        )
        NSColor(DesignTokens.Colors.usageTrack).setFill()
        track.fill()

        guard let percent else { return }
        let fraction = max(0, min(1, percent / 100))
        guard fraction > 0 else { return }
        let fillHeight = max(Bar.width, Bar.height * fraction) // never thinner than the bar is wide
        let fill = NSBezierPath(
            roundedRect: NSRect(x: x, y: bottom, width: Bar.width, height: fillHeight),
            xRadius: Bar.cornerRadius, yRadius: Bar.cornerRadius
        )
        fillColor(percent: percent, stale: stale).setFill()
        fill.fill()
    }

    /// Provider accent normally; amber/red as the window fills; muted grey when stale — mirrors the
    /// popover's `UsageSectionView` so the menu bar and the popover agree at a glance.
    private func fillColor(percent: Double, stale: Bool) -> NSColor {
        if stale { return NSColor(DesignTokens.Colors.idle) }
        switch UsageLevel.forPercent(percent) {
        case .normal: return NSColor(DesignTokens.Colors.claudeOrange)
        case .warn: return NSColor(DesignTokens.Colors.usageWarn)
        case .high: return NSColor(DesignTokens.Colors.usageHigh)
        }
    }
}
