import SwiftUI
import AppKit

/// The system menu/popover material behind the whole popover — vibrancy, not an opaque fill
/// (macOS 26 / HITO1_DESIGN: never paint our own opaque background). `.popover` material +
/// `.withinWindow` blending is exactly what AppKit menus and popovers use.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
