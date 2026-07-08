import Foundation

/// Persistent NAME-by-cwd memory for Codex rollout scans, mirroring the C# reference's
/// `CodexScanner._namesByCwd`/`_cwdIds` (`src/MyAgents/Services/CodexScanner.cs`): names
/// accumulate across scans and are remembered even after a session's rollout file ages out of
/// the current scan window, so a still-alive Codex PROCESS whose rollout has gone quiet can keep
/// showing a real name instead of just its folder.
///
/// Safety invariant (the whole reason this type exists instead of a plain `[String: String]`):
/// a name is only ever returned for a cwd when EXACTLY ONE distinct session id has ever been
/// recorded there. Two Codex sessions sharing a working directory (e.g. two terminals opened in
/// the same project) means we cannot tell which nameless/discovered row a cached name actually
/// belongs to — returning it anyway risks mislabeling one session with another's name, which is
/// worse than the honest fallback (show the folder). `name(forCwd:)` returns `nil` in that case,
/// never a guess.
public final class CodexNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var namesByCwd: [String: String] = [:]
    private var idsByCwd: [String: Set<String>] = [:]

    public init() {}

    /// Records one freshly-scanned rollout session's (cwd, sessionId, name). Recording the same
    /// `sessionId` again (e.g. the same session seen on a later poll) is a no-op for the
    /// ambiguity count — a `Set` de-duplicates — so polling repeatedly never manufactures a false
    /// "two sessions share this cwd" positive.
    ///
    /// `name` may be empty (no real user prompt found yet in that session's rollout) — the id is
    /// still recorded so the ambiguity count stays correct, but an empty name never overwrites a
    /// previously-recorded real name for the same cwd.
    public func record(cwd: String, sessionId: String, name: String) {
        guard !sessionId.isEmpty else { return }
        let key = Self.normalize(cwd)
        guard !key.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        var ids = idsByCwd[key] ?? []
        ids.insert(sessionId)
        idsByCwd[key] = ids

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            namesByCwd[key] = trimmedName
        }
    }

    /// The cached name for `cwd` — but ONLY if exactly one session has ever been recorded there.
    /// `nil` when the cwd was never seen, when no session recorded there has produced a name yet,
    /// or when two or more distinct session ids share it (ambiguous — see the type doc).
    public func name(forCwd cwd: String) -> String? {
        let key = Self.normalize(cwd)
        guard !key.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard (idsByCwd[key]?.count ?? 0) == 1 else { return nil }
        return namesByCwd[key]
    }

    /// Normalizes a cwd for use as a dictionary key: trims surrounding whitespace and a trailing
    /// slash (matching `SessionLivenessJoin`'s cwd normalization), WITHOUT lowercasing — macOS
    /// paths are case-preserving even though the default filesystem is case-insensitive, and
    /// staying case-preserving keeps this key consistent with the cwd strings used elsewhere in
    /// the app (hook JSON, `ProcessLiveness`), which are never lowercased either.
    static func normalize(_ cwd: String) -> String {
        var path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
