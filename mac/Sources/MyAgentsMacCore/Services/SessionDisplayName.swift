import Foundation

/// Resolves what a session row's TITLE line should show — a pure function so the priority rule is
/// directly testable without any file I/O.
///
/// Bug this exists to fix: the Mac port used the hook's `name` field (which `lifecycle.js` sets to
/// the raw first user prompt, or leaves empty) as the title, falling back to the FOLDER when empty
/// — so a session row showed the folder name twice (title line AND folder line). The Windows
/// reference (`src/MyAgents/Services/TranscriptTitle.cs` + `SessionState.cs`) instead prefers the
/// AI-authored title Claude Code writes into the transcript.
///
/// Priority, mirroring Windows:
/// 1. `aiTitle` (from `TranscriptTitle`, reading the session's transcript) — wins whenever present.
/// 2. The hook's raw `name` — but ONLY if it's non-blank and not just a repeat of the folder.
/// 3. A localized placeholder (`session.untitled`) — NEVER the folder itself.
public enum SessionDisplayName {
    /// - Parameters:
    ///   - aiTitle: the transcript's `{"type":"ai-title","aiTitle":"…"}` value, if any.
    ///   - name: the hook's raw `name` field (`Session.name`).
    ///   - folder: the session's folder line (`Session.folder`) — used only to detect and reject a
    ///     duplicate; never returned as the resolved title itself.
    /// - Returns: a non-empty string, always — callers can treat an empty result as "not called yet".
    public static func resolve(aiTitle: String?, name: String, folder: String) -> String {
        let trimmedTitle = (aiTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, !matchesFolder(trimmedName, folder: folder) {
            return trimmedName
        }

        return String(localized: "session.untitled", defaultValue: "New session")
    }

    /// Case-insensitive comparison: hook names and folder basenames aren't guaranteed identical
    /// casing, but "myagents" vs "MyAgents" is still the same duplicate the bug report describes.
    private static func matchesFolder(_ text: String, folder: String) -> Bool {
        guard !folder.isEmpty else { return false }
        return text.compare(folder, options: [.caseInsensitive]) == .orderedSame
    }
}
