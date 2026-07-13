import Foundation

/// The aggregate menu-bar glyph state, derived from ALL sessions at once — the single decision
/// that drives what the status-bar icon looks like and, crucially, whether its animation timer is
/// allowed to run (the "energy law": no unconditional menu-bar animation).
///
/// Pure and `Equatable` so the whole glyph policy is unit-testable without any AppKit/timer
/// machinery: `evaluate` maps a session list to a status, `shouldAnimate` gates the Timer, and
/// `symbolName` picks the SF Symbol. The AppKit glyph controller is a thin renderer over this.
public struct MenuBarStatus: Equatable, Sendable {
    /// Priority order matches `SessionOrdering`: a session needing a human outranks a busy one,
    /// which outranks the resting state.
    public enum Kind: Equatable, Sendable, CaseIterable {
        /// At least one session is awaiting permission — the menu bar must shout.
        case attention
        /// Something is actively working (thinking / running a tool), nothing needs a human.
        case busy
        /// Nothing working, nothing waiting — the resting glyph.
        case idle
    }

    public let kind: Kind

    /// The provider whose accent tints a *busy* glyph — the highest-priority busy session's
    /// provider (sessions arrive attention-first ordered, so `first(where:isBusy)` is the one the
    /// user is most likely watching). `nil` for `.attention`/`.idle`, whose tints are semantic
    /// (amber / muted), not provider-derived.
    public let busyProvider: Provider?

    public init(kind: Kind, busyProvider: Provider?) {
        self.kind = kind
        self.busyProvider = busyProvider
    }

    /// The one place the glyph state is decided.
    public static func evaluate(_ sessions: [Session]) -> MenuBarStatus {
        if sessions.contains(where: \.needsAttention) {
            return MenuBarStatus(kind: .attention, busyProvider: nil)
        }
        if let firstBusy = sessions.first(where: \.isBusy) {
            return MenuBarStatus(kind: .busy, busyProvider: firstBusy.provider)
        }
        return MenuBarStatus(kind: .idle, busyProvider: nil)
    }

    /// ENERGY LAW, in data form: the frame-swap Timer may run ONLY while a session is waiting on a
    /// human. Motion is spent where it buys something — a permission prompt the user must answer —
    /// and nowhere else. `.busy` is deliberately static: it can last hours, and a pulse that runs
    /// for hours costs a measured ~6.7 % of a core while telling the user nothing they can act on
    /// (the popover already shows what each session is doing). `.idle` never moves.
    public var shouldAnimate: Bool { kind == .attention }

    /// How long the attention pulse is allowed to run before the glyph settles into its solid amber
    /// triangle. The pulse is a *doorbell*, not a siren: it earns its cost by catching the eye on
    /// the transition into `.attention`. Once it has been ringing this long, either the user saw it
    /// or they are away from the Mac — and a glyph that pulses all night is exactly the cost this
    /// policy exists to avoid. The static triangle keeps saying "a session needs you" for free.
    public static let attentionPulseWindow: TimeInterval = 30

    /// The frame budget for the pulse at a given frame rate — the energy law expressed in the only
    /// unit the renderer's `Timer` understands. Zero for every state that must not move, so the
    /// renderer cannot animate a state the law forbids even if it forgets to ask `shouldAnimate`.
    public func pulseFrameBudget(fps: Double) -> Int {
        guard shouldAnimate, fps > 0 else { return 0 }
        return Int((Self.attentionPulseWindow * fps).rounded())
    }

    /// SF Symbol name for the current state. Today only `.attention` actually reaches an SF Symbol
    /// in the renderer (the warning triangle) — `MenuBarGlyphController` draws its own robot-head
    /// mark for `.idle`/`.busy` (app identity, Miguel's ask 2026-07-09). The idle/busy names are
    /// kept as a documented fallback so the glyph still has a sensible symbol if the custom
    /// renderer is ever bypassed.
    public var symbolName: String {
        switch kind {
        case .attention: return "exclamationmark.triangle.fill"
        case .busy: return "ellipsis"
        case .idle: return "terminal"
        }
    }
}
