import SwiftUI

/// Entry point. MyAgents is a menu-bar-only ("agent") app: `LSUIElement = YES` in
/// `Resources/Info.plist` keeps it out of the Dock and ⌘-Tab, so there's no `WindowGroup` scene —
/// `Settings` just gives SwiftUI a scene to own the app lifecycle without creating a visible
/// window. All real UI (the status item + popover) is built by `AppDelegate` in AppKit, because a
/// future animated/colored glyph + usage badge (Hito 1, CONTEXT.md D9) needs more control than
/// SwiftUI's `MenuBarExtra` exposes.
@main
struct MyAgentsMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
