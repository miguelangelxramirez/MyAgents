import Foundation
import os

/// Reads the AI-authored title Claude Code writes into a session's transcript — the line
/// `{"type":"ai-title","aiTitle":"…"}` — mirroring `src/MyAgents/Services/TranscriptTitle.cs`.
/// This is the title that actually names a session; the hook's `name` field
/// (`Session.name`/`SessionWireFormat.name`) is frequently empty or just the raw first prompt
/// (see `SessionDisplayName`, which combines both).
///
/// Cached per session id (titles don't change once Claude Code writes them), so a transcript is
/// read at most until its title line appears, and never read again afterwards. The cache is a
/// lock-protected dictionary (mirroring the C# reference's `Dictionary` + `lock`) so one shared
/// instance can be reused across `SessionStore` polls without re-reading files it already solved.
/// A session with NO title yet (Claude Code hasn't written the line, or never will) is
/// deliberately NOT cached, so each subsequent poll retries — cheap, since a read is capped at
/// `maxLines` lines and stops at the first chunk that doesn't contain more data.
///
/// Defensive by construction (METODOLOGIA §4): a missing session id, an empty/missing/unreadable
/// transcript path, or a transcript with no ai-title line in its head all return `nil` — this type
/// NEVER throws and NEVER crashes the caller.
public final class TranscriptTitle: @unchecked Sendable {
    /// The ai-title line sits near the top of the transcript (Claude Code writes it early), so
    /// capping the scan bounds the read even for a transcript that has grown to megabytes.
    private static let maxLines = 150
    private static let chunkSize = 8192

    /// A recorded MISS. The point of remembering one is that a session with no ai-title line was
    /// otherwise re-reading its transcript on EVERY poll, twice a second, forever — and a Claude
    /// transcript on this machine reaches 100 MB.
    private enum Miss {
        /// Settled for good: the scan consumed the whole read window (all `maxLines` lines, or the
        /// byte budget). A transcript is append-only, so nothing a future append adds can change
        /// what's inside that window — this file will never yield a title. Never read it again.
        case final
        /// The scan hit EOF before filling the window: the file is simply short so far. Worth another
        /// look, but ONLY once it has actually grown past this size.
        case atSize(Int64)
    }

    private let lock = NSLock()
    private var cache: [String: String] = [:] // sessionId -> resolved aiTitle (only positive hits)
    private var misses: [String: Miss] = [:]
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "TranscriptTitle")

    public init() {}

    /// Returns the cached/parsed `aiTitle` for `sessionId`, reading `transcriptPath` if not cached
    /// yet. `nil` when `sessionId` is empty, `transcriptPath` is empty, the file is missing or
    /// unreadable, or no ai-title line is found within the head.
    public func title(sessionId: String, transcriptPath: String) -> String? {
        guard !sessionId.isEmpty, !transcriptPath.isEmpty else { return nil }

        lock.lock()
        let cached = cache[sessionId]
        let miss = misses[sessionId]
        lock.unlock()
        if let cached { return cached }

        // Nothing new to look at: the window is settled for good (no need to even stat the file), or
        // the file hasn't grown since the last fruitless scan, so it still holds exactly the bytes
        // we already rejected.
        if case .final = miss { return nil }
        let size = Self.fileSize(atPath: transcriptPath)
        if case .atSize(let lastSize) = miss, let size, lastSize == size { return nil }

        let (found, stop) = Self.readTitle(atPath: transcriptPath, logger: logger)

        lock.lock()
        if let found {
            cache[sessionId] = found
            misses[sessionId] = nil
        } else {
            misses[sessionId] = Self.miss(for: stop, size: size)
        }
        lock.unlock()
        return found
    }

    /// Drops cache/miss entries for session ids no longer present on disk, so both maps stay bounded
    /// by the live session count instead of growing for every session seen across one long-running
    /// app session (Codex audit MED #7). Called by `SessionStore` each scan with the ids it just saw.
    public func prune(keepingSessionIds ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        cache = cache.filter { ids.contains($0.key) }
        misses = misses.filter { ids.contains($0.key) }
    }

    /// How to remember a fruitless scan.
    ///
    /// CRUCIAL: an UNREADABLE file is not a miss at all — it's "not there yet". The hook can publish
    /// a session's transcript path before Claude Code has created the file, and a transcript can be
    /// briefly unreadable for any number of reasons. Caching that as final would freeze the session's
    /// title to its folder name FOREVER. (This is exactly the bug an earlier version of this cache
    /// shipped: `fileSize` returned `-1` for an unstattable file and `-1` doubled as the
    /// "settled for good" sentinel.)
    private static func miss(for stop: BoundedLineReader.Stop, size: Int64?) -> Miss? {
        switch stop {
        case .lineLimit, .byteLimit:
            // The whole read window was consumed. Append-only ⇒ that window can never change, and no
            // append will ever make a byte beyond the budget reachable either.
            return .final
        case .endOfFile:
            return size.map { .atSize($0) }
        case .unreadable, .callerStopped:
            // Not there (yet), or we stopped ourselves. Either way: remember nothing, look again.
            return nil
        }
    }

    /// `nil` when the file can't be statted (missing, unreadable) — deliberately NOT a number, so it
    /// can never be confused with a real size or with a settled miss. See `miss(for:size:)`.
    private static func fileSize(atPath path: String) -> Int64? {
        try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
    }

    // MARK: - File reading (never throws)

    /// Scans the head of `path` (at most `maxLines` lines, streamed — never the whole file) for a
    /// JSON line of the form `{"type":"ai-title","aiTitle":"…"}`. Returns the LAST such line found
    /// within the head (mirrors the C# reference, in case more than one appears) — hence no early
    /// exit — together with WHY the scan stopped, which tells the caller whether a miss is final.
    ///
    /// A transcript's last line may have no trailing newline yet (Claude Code is still writing it);
    /// `BoundedLineReader` delivers that final partial line too, so a title written there is found.
    private static func readTitle(atPath path: String, logger: Logger) -> (title: String?, stop: BoundedLineReader.Stop) {
        var found: String?
        let stop = BoundedLineReader.forEachLine(of: URL(fileURLWithPath: path), maxLines: maxLines, chunkSize: chunkSize) { line in
            guard line.contains("ai-title"), let title = extractAITitle(from: line) else { return .continue }
            found = title
            return .continue
        }
        if stop == .unreadable {
            logger.debug("Could not read transcript at \(path, privacy: .public)")
        }
        return (found, stop)
    }

    /// Parses one JSONL line and returns its `aiTitle` value if the line really is a
    /// `{"type":"ai-title", …}` record — malformed JSON or a coincidental substring match is
    /// skipped, never thrown.
    private static func extractAITitle(from line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard object["type"] as? String == "ai-title" else { return nil }
        guard let raw = object["aiTitle"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
