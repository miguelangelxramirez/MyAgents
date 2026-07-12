import Foundation

/// Streams the LEADING lines of a file without ever slurping it whole, in time linear in the bytes
/// actually read, and stops the moment the caller has seen enough.
///
/// This exists because the two hand-rolled chunked readers it replaces (`CodexSessionScanner`'s
/// `readLines` and `TranscriptTitle`'s `readTitle`) shared three defects that together pegged a CPU
/// core in the shipped app (measured with `sample(1)` on 2026-07-12: 2258/2259 samples inside
/// `readLines`, the process at 113% CPU and 353 minutes of CPU time):
///
/// 1. **Quadratic buffering.** They appended each 8 KiB chunk to one growing `Data` and then ran
///    `buffer.firstIndex(of: "\n")` over the WHOLE accumulated buffer again — so a single long line
///    re-scanned everything before it, once per chunk. A real rollout on this machine carried a
///    5.2 MB line inside its first 60, which turned one scan into gigabytes of byte-walking. Here
///    the newline search only ever looks at the current chunk's unscanned tail (`cursor...`), and
///    each byte is touched once.
/// 2. **Eager reads.** They materialized ALL `maxLines` lines before the caller inspected any, so a
///    caller that wanted line 6 still paid for lines 7...60. `forEachLine` hands each line over as
///    soon as it is complete and stops when the caller says `.stop`.
/// 3. **No line-size ceiling.** A pasted image or a giant tool result is a single multi-megabyte
///    line that can never be a session name or a title, yet it was buffered in full. A line longer
///    than `maxLineBytes` is now consumed and DISCARDED without ever being held in memory.
///
/// Defensive by construction (METODOLOGIA §4): an unreadable/missing file yields `.unreadable`, and
/// nothing here ever throws.
public enum BoundedLineReader {
    /// A line longer than this cannot be anything a caller here wants (a session name is capped at
    /// ~90 characters, an ai-title is a short sentence) — it's a pasted image or a huge tool result.
    /// Such a line is walked past and discarded, never accumulated.
    public static let defaultMaxLineBytes = 1 << 20 // 1 MiB

    /// Safety valve: the hard ceiling on how much of a file one scan will read, however few lines
    /// that turns out to be. `maxLines` is the primary bound; this only stops a pathological file
    /// (e.g. one 500 MB line) from being walked end to end.
    public static let defaultMaxBytes = 8 << 20 // 8 MiB

    /// Why a scan stopped. The distinction matters for caching: the head of an append-only file is
    /// IMMUTABLE, so a caller that consumed the full line window (`.lineLimit`) — or found what it
    /// wanted (`.callerStopped`) — knows that re-reading this file later can never change the
    /// answer, and may cache a negative result forever. `.endOfFile` and `.byteLimit` mean the
    /// window is not yet fully determined: a file that later grows could still change it.
    public enum Stop: Equatable, Sendable {
        /// The caller's body returned `.stop` — it found what it was looking for.
        case callerStopped
        /// `maxLines` lines were consumed. The window is complete.
        case lineLimit
        /// The file ended before `maxLines` lines. A longer file later could yield more.
        case endOfFile
        /// The `maxBytes` budget ran out first.
        case byteLimit
        /// The file could not be opened at all.
        case unreadable
    }

    /// What the caller wants after seeing a line.
    public enum Step: Equatable, Sendable {
        case `continue`
        case stop
    }

    /// Calls `body` with each line from the START of `file`, in order, until `body` returns `.stop`,
    /// `maxLines` lines have been consumed, the byte budget runs out, or the file ends.
    ///
    /// A line longer than `maxLineBytes` is COUNTED as consumed (it really is a line of the file, so
    /// it must still bound how deep we look) but is never passed to `body` and never buffered.
    /// A final line with no trailing newline is delivered too — a file being appended to right now
    /// may not have flushed its last newline.
    @discardableResult
    public static func forEachLine(
        of file: URL,
        maxLines: Int,
        maxBytes: Int = defaultMaxBytes,
        maxLineBytes: Int = defaultMaxLineBytes,
        chunkSize: Int = 8192,
        _ body: (String) -> Step
    ) -> Stop {
        guard maxLines > 0, let handle = try? FileHandle(forReadingFrom: file) else { return .unreadable }
        defer { try? handle.close() }

        var consumed = 0
        var bytesRead = 0
        var pending = Data() // the line currently being assembled
        var pendingIsOverlong = false
        let newline = UInt8(ascii: "\n")

        /// Accumulates a fragment of the current line, unless that line has already blown past
        /// `maxLineBytes` — in which case the fragment is dropped on the floor and the line is
        /// marked so its eventual newline discards it rather than delivering it.
        func accumulate(_ fragment: Data) {
            guard !pendingIsOverlong else { return }
            guard pending.count + fragment.count <= maxLineBytes else {
                pendingIsOverlong = true
                pending.removeAll(keepingCapacity: false)
                return
            }
            pending.append(fragment)
        }

        /// Delivers the assembled line (unless it was over-long or isn't valid UTF-8) and resets.
        /// Returns the caller's decision.
        func flushLine() -> Step {
            defer {
                pending.removeAll(keepingCapacity: true)
                pendingIsOverlong = false
            }
            consumed += 1
            guard !pendingIsOverlong, let line = String(data: pending, encoding: .utf8) else { return .continue }
            return body(line)
        }

        while consumed < maxLines, bytesRead < maxBytes {
            let chunk: Data
            do {
                // Never read PAST the budget: reading a full chunk when fewer bytes remain would let
                // a line beyond `maxBytes` still be delivered, making the "hard ceiling" a lie.
                chunk = try handle.read(upToCount: min(chunkSize, maxBytes - bytesRead)) ?? Data()
            } catch {
                return .unreadable
            }
            guard !chunk.isEmpty else {
                // EOF. A trailing line with no newline still counts.
                if !pending.isEmpty || pendingIsOverlong, flushLine() == .stop { return .callerStopped }
                return .endOfFile
            }
            bytesRead += chunk.count

            // Only ever search the part of THIS chunk we haven't looked at — never the accumulated
            // buffer. This is what keeps the whole scan linear.
            var cursor = chunk.startIndex
            while consumed < maxLines, let newlineIndex = chunk[cursor...].firstIndex(of: newline) {
                accumulate(chunk[cursor..<newlineIndex])
                if flushLine() == .stop { return .callerStopped }
                cursor = chunk.index(after: newlineIndex)
            }
            if consumed < maxLines, cursor < chunk.endIndex {
                accumulate(chunk[cursor...])
            }
        }

        return consumed >= maxLines ? .lineLimit : .byteLimit
    }

    /// Convenience: collects up to `maxLines` leading lines. Prefer `forEachLine` when the caller can
    /// stop early — a scan that stops at line 6 must not pay for lines 7...60.
    public static func head(
        of file: URL,
        maxLines: Int,
        maxBytes: Int = defaultMaxBytes,
        maxLineBytes: Int = defaultMaxLineBytes,
        chunkSize: Int = 8192
    ) -> [String] {
        var lines: [String] = []
        forEachLine(of: file, maxLines: maxLines, maxBytes: maxBytes, maxLineBytes: maxLineBytes, chunkSize: chunkSize) { line in
            lines.append(line)
            return .continue
        }
        return lines
    }
}
