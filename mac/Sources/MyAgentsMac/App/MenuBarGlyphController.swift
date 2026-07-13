import AppKit
import MyAgentsMacCore

/// The single usage percentage to badge next to the status glyph — Miguel swapped the two mini
/// bars ("los dos puntos") for one chosen number (feedback 2026-07-09). `percent` is `nil` for a
/// window the source hasn't reported yet (drawn as "—", never a fabricated 0 %); `isStale` greys
/// it so an old reading can't masquerade as current; `provider` picks the accent colour.
struct MenuBarUsage: Equatable {
    var percent: Double?
    var provider: Provider
    var isStale: Bool
}

/// Draws (and, only while a session is waiting on a human, animates) the status-bar glyph, plus an
/// optional usage badge (two mini bars).
///
/// The animation is a frame-swap `Timer` that re-renders the `NSImage` each tick — Core Animation
/// on a status-item button is unreliable, so we redraw the image ourselves (per HITO1_DESIGN).
/// ENERGY LAW: the timer exists ONLY while `MenuBarStatus.shouldAnimate` (i.e. `.attention`), and
/// even then only for `MenuBarStatus.attentionPulseWindow` — see `startAnimating`. Every other
/// state sets a single static image and tears the timer down. Working sessions do NOT animate: a
/// pulse that runs as long as an agent works is the single most expensive thing this app can do.
@MainActor
final class MenuBarGlyphController {
    private weak var button: NSStatusBarButton?
    private var status: MenuBarStatus = MenuBarStatus(kind: .idle, busyProvider: nil)
    /// Claude 5 h/7 d usage to badge, or `nil` to hide the badge (usage disabled / all-unknown).
    private var usage: MenuBarUsage?

    private var animationTimer: Timer?
    private var phase: CGFloat = 0
    private var hasRendered = false

    /// Frames the pulse may still draw. Counts down to zero, after which the next peak of the
    /// breath settles the glyph into its solid image and kills the timer.
    private var pulseFramesRemaining = 0

    /// A calm breath; also the unit `pulseFrameBudget` is denominated in.
    private static let fps: Double = 12

    /// Gap between the glyph and the usage-percent badge to its right (points).
    private static let badgeLeading: CGFloat = 4

    // Custom robot-head mark (points), drawn by `robotImage`. This is the app's own identity glyph
    // — Miguel wanted "algo único, un robot" instead of a generic SF Symbol (feedback 2026-07-09).
    // Tuned to sit against the ~15pt SF Symbol used for the attention triangle so switching states
    // doesn't jump the baseline. Drawn as a silhouette with the eyes/mouth punched out (so it tints
    // as a clean template in light/dark, exactly like a real SF Symbol).
    private enum Robot {
        static let canvas = NSSize(width: 15, height: 15)
    }

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    /// New data arrived. Re-evaluates the static/animated decision and redraws. A no-op update
    /// (same status and usage, not animating) skips the redraw so we don't reallocate an identical
    /// `NSImage` — while the pulse runs, its timer owns the redraws.
    ///
    /// The pulse rings on the *transition* into `.attention`, so it is armed only when the kind
    /// actually changes. A second session raising its hand while the glyph is already amber does
    /// not re-ring it: the glyph is already saying "you are needed", and re-arming on every update
    /// would let a chatty stream of sessions keep the timer alive indefinitely.
    func update(status: MenuBarStatus, usage: MenuBarUsage?) {
        // `usage == nil` means "don't show a badge" (usage disabled); a non-nil value with a `nil`
        // percent still draws — as "—" — so the chosen metric is visibly "on but no data yet".
        let unchanged = hasRendered && status == self.status && usage == self.usage
        let enteredNewKind = !hasRendered || status.kind != self.status.kind
        self.status = status
        self.usage = usage
        defer { hasRendered = true }

        if status.shouldAnimate, enteredNewKind {
            startAnimating()
        } else if !status.shouldAnimate {
            stopAnimating()
        }
        // While the pulse is running its timer redraws every frame; a changed badge still needs a
        // redraw of its own for the non-animating case (and costs nothing during one).
        if !unchanged { redraw() }
    }

    // MARK: - Animation (energy-gated)

    /// Arms the pulse with a finite frame budget. `.common` mode keeps it alive while the user
    /// tracks a menu. The timer tears *itself* down when the budget runs out, so the glyph cannot
    /// pulse for longer than `MenuBarStatus.attentionPulseWindow` no matter how long the session
    /// sits there waiting — the whole point of the policy.
    private func startAnimating() {
        stopAnimating()
        let budget = status.pulseFrameBudget(fps: Self.fps)
        guard budget > 0 else { return }
        pulseFramesRemaining = budget

        let timer = Timer(timeInterval: 1.0 / Self.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// One frame of breath. Once the budget is spent we don't cut mid-breath — that reads as a
    /// flash — we wait for the next peak, where the pulsing glyph and the solid one are the same
    /// image, and stop there. That costs at most one more cycle (~3 s).
    private func tick() {
        phase += 0.16
        if pulseFramesRemaining > 0 {
            pulseFramesRemaining -= 1
        } else if pulseAlpha >= 0.99 {
            stopAnimating()   // leaves the glyph solid: `pulseAlpha` is 1 with no timer running
        }
        redraw()
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        pulseFramesRemaining = 0
        phase = 0
    }

    /// A soft breathing alpha while the pulse runs, and full strength the moment it stops — so the
    /// glyph settles into exactly the solid image every static state draws.
    private var pulseAlpha: CGFloat {
        guard animationTimer != nil else { return 1 }
        return 0.5 + 0.5 * (0.5 + 0.5 * sin(phase))
    }

    // MARK: - Rendering

    private func redraw() {
        let symbol = symbolImage(alpha: pulseAlpha, forceColored: usage != nil)
        button?.image = compose(symbol: symbol, usage: usage)
    }

    /// The glyph for the current state. The resting/working mark is the custom robot head (the
    /// app's identity); an awaiting-permission state overrides it with the universally-legible
    /// warning triangle (SF Symbol) so "a session needs you" stays unmistakable at a glance. Idle
    /// with no badge stays a *template* image so the system tints it to match the menu bar (the
    /// crisp, native resting look); any other state — or idle carrying a badge — is drawn coloured.
    private func symbolImage(alpha: CGFloat, forceColored: Bool) -> NSImage {
        // Attention keeps the warning triangle: a robot tinted amber reads far weaker than the
        // shape everyone already parses as "stop, look here".
        if status.kind == .attention {
            return warningSymbol(alpha: alpha)
        }

        let isTemplate = status.kind == .idle && !forceColored
        return robotImage(tint: tintColor, alpha: alpha, isTemplate: isTemplate)
    }

    /// The awaiting-permission triangle (SF Symbol), coloured amber. Unchanged from the previous
    /// all-SF-Symbol renderer.
    private func warningSymbol(alpha: CGFloat) -> NSImage {
        let sizeConfig = NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Metrics.glyphPointSize,
            weight: .semibold
        )
        let tint = tintColor.withAlphaComponent(alpha)
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        let config = sizeConfig.applying(paletteConfig)
        let base = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: accessibilityDescription)
        let image = base?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }

    /// Draws the custom robot head: a rounded head with a stubby antenna, two eyes and a mouth
    /// punched out. Two passes — fill the silhouette (non-zero union of head + antenna), then erase
    /// the eyes/mouth with `.destinationOut` so they become true holes. A template image (idle,
    /// no badge) is filled black and left to the system tint; every other state is filled with the
    /// state's colour at `alpha` (so the provider accent still applies). The robot never pulses:
    /// `alpha` is 1 for every state that reaches it — only the attention triangle animates.
    private func robotImage(tint: NSColor, alpha: CGFloat, isTemplate: Bool) -> NSImage {
        let image = NSImage(size: Robot.canvas)
        image.lockFocus()
        defer {
            image.unlockFocus()
            image.isTemplate = isTemplate
        }
        guard let context = NSGraphicsContext.current else { return image }

        let fill = isTemplate ? NSColor.black : tint.withAlphaComponent(alpha)

        // Pass 1 — solid silhouette (head + antenna stem + antenna tip), non-zero union.
        let body = NSBezierPath()
        body.append(NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 12, height: 9.5), xRadius: 3, yRadius: 3))
        body.append(NSBezierPath(rect: NSRect(x: 7, y: 10.6, width: 1, height: 1.9)))
        body.append(NSBezierPath(ovalIn: NSRect(x: 6.1, y: 12, width: 2.8, height: 2.8)))
        fill.setFill()
        body.fill()

        // Pass 2 — punch the eyes and mouth out of the silhouette.
        context.compositingOperation = .destinationOut
        let holes = NSBezierPath()
        holes.append(NSBezierPath(ovalIn: NSRect(x: 3.9, y: 5.1, width: 2.6, height: 2.6)))   // left eye
        holes.append(NSBezierPath(ovalIn: NSRect(x: 8.5, y: 5.1, width: 2.6, height: 2.6)))   // right eye
        holes.append(NSBezierPath(roundedRect: NSRect(x: 5, y: 3, width: 5, height: 1.1), xRadius: 0.55, yRadius: 0.55)) // mouth
        NSColor.black.setFill()
        holes.fill()
        context.compositingOperation = .sourceOver

        return image
    }

    private var tintColor: NSColor {
        switch status.kind {
        case .attention:
            return NSColor(DesignTokens.Colors.permission)
        case .busy:
            let color = status.busyProvider == .codex
                ? DesignTokens.Colors.codexBlue
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

    // MARK: - Composition (symbol + optional usage percent)

    /// Composites the symbol and (optional) usage-percent text into one image. With no usage the
    /// symbol is returned untouched so the idle template case keeps its system tinting.
    private func compose(symbol: NSImage, usage: MenuBarUsage?) -> NSImage {
        guard let usage else { return symbol }

        let attributed = NSAttributedString(string: badgeText(usage), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: DesignTokens.Metrics.glyphBadgeFontSize, weight: .semibold),
            .foregroundColor: badgeColor(usage),
        ])
        let textSize = attributed.size()

        let width = symbol.size.width + Self.badgeLeading + ceil(textSize.width)
        let height = max(symbol.size.height, ceil(textSize.height))

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        symbol.draw(in: NSRect(
            x: 0,
            y: (height - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        ))
        attributed.draw(at: NSPoint(
            x: symbol.size.width + Self.badgeLeading,
            y: (height - textSize.height) / 2
        ))

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// "51%" for a known reading, "—" for an unknown one (the chosen metric is visibly on, just
    /// without data yet) — never a fabricated "0%".
    private func badgeText(_ usage: MenuBarUsage) -> String {
        guard let percent = usage.percent else {
            return String(localized: "usage.unknown", defaultValue: "—")
        }
        return "\(Int(percent.rounded()))%"
    }

    /// Provider accent normally; amber/red as the window fills; muted grey when stale or unknown —
    /// mirrors the popover's `UsageSectionView` so the menu bar and the popover agree at a glance.
    private func badgeColor(_ usage: MenuBarUsage) -> NSColor {
        if usage.isStale { return NSColor(DesignTokens.Colors.idle) }
        guard let percent = usage.percent else { return NSColor(DesignTokens.Colors.idle) }
        switch UsageLevel.forPercent(percent) {
        case .normal:
            return NSColor(usage.provider == .codex ? DesignTokens.Colors.codexBlue : DesignTokens.Colors.claudeOrange)
        case .warn:
            return NSColor(DesignTokens.Colors.usageWarn)
        case .high:
            return NSColor(DesignTokens.Colors.usageHigh)
        }
    }
}
