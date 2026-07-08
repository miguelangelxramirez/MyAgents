import Foundation

/// Build-visible info for a future "About" screen (METODOLOGIA §4, "regla de la build visible"):
/// exposes the marketing version and the *actual* build date/time, read from the running
/// executable's modification time — never a hand-maintained string, never a `pbxproj` edit.
public enum BuildInfo {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// The executable's last-modified time — a reliable proxy for "when this exact build was
    /// produced" without touching the Xcode project to stamp a date at build time.
    public static var buildDate: Date? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path)
        return attributes?[.modificationDate] as? Date
    }

    public static var buildDateDescription: String {
        guard let buildDate else {
            return String(localized: "buildinfo.unknown-date", defaultValue: "unknown build date")
        }
        return buildDate.formatted(date: .abbreviated, time: .shortened)
    }
}
