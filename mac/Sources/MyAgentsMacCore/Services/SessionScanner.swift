import Foundation
import os

/// Reads the per-session JSON files the Claude Code / Codex hooks write to
/// `~/.claude/statusbar/sessions.d/*.json` (see `docs/state-schema.md` and
/// `src/MyAgents/Services/SessionScanner.cs` in the Windows reference).
///
/// Defensive by construction, because a hostile filesystem state is the *primary* case here
/// (METODOLOGIA §4): a missing directory returns an empty list, not a crash or a throw; a
/// corrupt or truncated file is skipped and logged, and every other file in the batch still
/// comes back. `scanSessions()` never throws.
public struct SessionScanner: Sendable {
    private let directoryURL: URL
    // `FileManager` isn't `Sendable` in the SDK, but Apple documents instances as safe to use
    // from multiple threads for the read-only operations this scanner performs.
    nonisolated(unsafe) private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "SessionScanner")

    /// Production location of Claude Code's hook output. Tests inject a temp directory instead —
    /// never hit the real `~/.claude` from a unit test.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("statusbar", isDirectory: true)
            .appendingPathComponent("sessions.d", isDirectory: true)
    }

    public init(directoryURL: URL = SessionScanner.defaultDirectory, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// Scans the directory and returns every session that decoded successfully, in no
    /// particular order (ordering by attention/business is a `SessionStore`/UI concern).
    public func scanSessions() -> [Session] {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            // Missing dir is the expected steady state on a machine that has never run Claude
            // Code hooks yet — not an error, not logged as a warning.
            return []
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "json" }
        } catch {
            logger.warning("Could not list \(directoryURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }

        return files.compactMap { decodeSession(at: $0) }
    }

    private func decodeSession(at file: URL) -> Session? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            logger.warning("Could not read \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        guard !data.isEmpty else {
            logger.warning("Skipping empty session file \(file.lastPathComponent, privacy: .public)")
            return nil
        }

        let wire: SessionWireFormat
        do {
            wire = try JSONDecoder().decode(SessionWireFormat.self, from: data)
        } catch {
            logger.warning("Skipping corrupt session file \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        let fileStem = file.deletingPathExtension().lastPathComponent
        let folder: String
        if !wire.project.isEmpty {
            folder = wire.project
        } else if !wire.cwd.isEmpty {
            folder = URL(fileURLWithPath: wire.cwd).lastPathComponent
        } else {
            folder = ""
        }

        return Session(
            id: wire.sessionId.isEmpty ? fileStem : wire.sessionId,
            name: wire.name,
            folder: folder,
            cwd: wire.cwd,
            provider: wire.provider,
            state: wire.state,
            toolLabel: wire.label.isEmpty ? wire.tool : wire.label,
            startedAt: wire.startedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(wire.startedAt)) : nil,
            updatedAt: wire.ts > 0 ? Date(timeIntervalSince1970: TimeInterval(wire.ts)) : nil,
            ownerPid: wire.pid > 0 ? Int32(clamping: wire.pid) : nil,
            pending: false,
            transcript: wire.transcript,
            terminalHost: wire.terminalHost,
            titleTag: wire.titleTag,
            host: wire.host
        )
    }
}

/// Wire-format mirror of the JSON the hooks write (see `docs/state-schema.md`). Every field
/// decodes leniently: a missing or wrong-typed key falls back to a safe default instead of
/// failing the whole file — only genuinely malformed JSON (not valid JSON at all) causes
/// `SessionScanner` to skip the file.
private struct SessionWireFormat: Decodable {
    var state: SessionActivityState
    var provider: Provider
    var name: String
    var label: String
    var tool: String
    var project: String
    var cwd: String
    var sessionId: String
    var pid: Int64
    var startedAt: Int64
    var ts: Int64
    /// Path to the transcript JSONL — read by `TranscriptTitle` for the AI-authored session title.
    var transcript: String
    /// Reserved for Hito 2 (click-to-focus / D11); tolerantly decoded now so the wire format is
    /// already forward-compatible.
    var terminalHost: String
    var titleTag: String
    var host: String

    enum CodingKeys: String, CodingKey {
        case state, provider, name, label, tool, project, cwd, sessionId, pid, startedAt, ts
        case transcript, terminalHost, titleTag, host
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? container.decode(SessionActivityState.self, forKey: .state)) ?? .idle
        provider = (try? container.decode(Provider.self, forKey: .provider)) ?? .claude
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        tool = (try? container.decode(String.self, forKey: .tool)) ?? ""
        project = (try? container.decode(String.self, forKey: .project)) ?? ""
        cwd = (try? container.decode(String.self, forKey: .cwd)) ?? ""
        sessionId = (try? container.decode(String.self, forKey: .sessionId)) ?? ""
        pid = (try? container.decode(Int64.self, forKey: .pid)) ?? 0
        startedAt = (try? container.decode(Int64.self, forKey: .startedAt)) ?? 0
        ts = (try? container.decode(Int64.self, forKey: .ts)) ?? 0
        transcript = (try? container.decode(String.self, forKey: .transcript)) ?? ""
        terminalHost = (try? container.decode(String.self, forKey: .terminalHost)) ?? ""
        titleTag = (try? container.decode(String.self, forKey: .titleTag)) ?? ""
        host = (try? container.decode(String.self, forKey: .host)) ?? ""
    }
}
