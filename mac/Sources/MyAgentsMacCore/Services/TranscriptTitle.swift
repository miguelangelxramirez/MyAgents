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

    private let lock = NSLock()
    private var cache: [String: String] = [:] // sessionId -> resolved aiTitle (only positive hits)
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "TranscriptTitle")

    public init() {}

    /// Returns the cached/parsed `aiTitle` for `sessionId`, reading `transcriptPath` if not cached
    /// yet. `nil` when `sessionId` is empty, `transcriptPath` is empty, the file is missing or
    /// unreadable, or no ai-title line is found within the head.
    public func title(sessionId: String, transcriptPath: String) -> String? {
        guard !sessionId.isEmpty else { return nil }

        lock.lock()
        let cached = cache[sessionId]
        lock.unlock()
        if let cached { return cached }

        guard let found = Self.readTitle(atPath: transcriptPath, logger: logger) else { return nil }

        lock.lock()
        cache[sessionId] = found
        lock.unlock()
        return found
    }

    // MARK: - File reading (never throws)

    /// Reads `path` line-by-line in small chunks (never the whole file at once) up to `maxLines`,
    /// looking for a JSON line of the form `{"type":"ai-title","aiTitle":"…"}`. Returns the LAST
    /// such line found within the head (mirrors the C# reference, in case more than one appears),
    /// or `nil` if none did / the file couldn't be opened.
    private static func readTitle(atPath path: String, logger: Logger) -> String? {
        guard !path.isEmpty else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        var found: String?
        var linesRead = 0
        var buffer = Data()
        var hitEOF = false
        let newline = UInt8(ascii: "\n")

        func consider(_ lineData: Data) {
            guard let line = String(data: lineData, encoding: .utf8), line.contains("ai-title"),
                  let title = extractAITitle(from: line) else { return }
            found = title
        }

        while linesRead < maxLines {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                logger.debug("Could not read transcript chunk: \(String(describing: error), privacy: .public)")
                break
            }
            if chunk.isEmpty { hitEOF = true; break } // EOF
            buffer.append(chunk)

            while linesRead < maxLines, let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                linesRead += 1
                consider(lineData)
            }
        }

        // A transcript's LAST line may have no trailing newline yet (Claude Code is still writing
        // it, or the file simply doesn't end in "\n") — `StreamReader.ReadLine()` in the C#
        // reference still returns that final partial line, so this must too, or a title written
        // as the very last (unterminated) line would never be found.
        if hitEOF, linesRead < maxLines, !buffer.isEmpty {
            consider(buffer)
        }

        return found
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
