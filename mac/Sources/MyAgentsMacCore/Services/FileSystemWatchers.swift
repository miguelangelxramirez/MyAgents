import Foundation
import os

/// File-system watchers that let the app STOP POLLING.
///
/// Until now `SessionStore` re-scanned everything twice a second, forever — waking the CPU 2×/s even
/// when no agent existed. That is the wrong shape for a menu-bar app: the work is not periodic, it is
/// a REACTION to a hook writing a file. These two types turn the poll into an event stream:
///
/// - `DirectoryWatcher` — a kqueue/`DispatchSource` vnode watch on ONE directory. Perfect for
///   `~/.claude/statusbar/sessions.d`, which is flat: the hooks write each session's JSON via
///   temp-file + `rename`, which changes the directory's entries and therefore fires `.write`.
/// - `FileTreeWatcher` — an FSEvents stream over a whole TREE. Needed for `~/.codex/sessions`, whose
///   rollouts live in nested `YYYY/MM/DD` folders and are APPENDED to: a vnode watch on the root
///   would never see a write to a descendant, but FSEvents with `FileEvents` does.
///
/// Both are deliberately dumb: they report only THAT something changed, never what. The scan they
/// trigger is already cheap and idempotent, so per-path bookkeeping would buy nothing and could go
/// stale. Neither ever throws; a missing directory just means "nothing to watch yet" and is retried,
/// which is the normal state on a machine whose hooks aren't installed.
public final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "DirectoryWatcher")

    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var isStopped = false

    /// How long to wait before trying again when the directory doesn't exist (or vanished). The
    /// hooks may not be installed yet, or `sessions.d` may be recreated by a repair.
    private static let reopenDelay: TimeInterval = 2

    public init(
        url: URL,
        queue: DispatchQueue = DispatchQueue(label: "com.miguelangelramirez.myagents.mac.dirwatch", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        isStopped = false
        lock.unlock()
        open()
    }

    public func stop() {
        lock.lock()
        isStopped = true
        let current = source
        source = nil
        lock.unlock()
        current?.cancel() // the cancel handler closes the descriptor
    }

    private func open() {
        lock.lock()
        let stopped = isStopped
        lock.unlock()
        guard !stopped else { return }

        // O_EVTONLY: open purely to receive events — it doesn't prevent the volume from unmounting.
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleReopen()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // The directory itself was replaced or went away: this descriptor is now watching a
            // vnode nobody can reach. Re-open by PATH, or we'd silently watch a ghost forever.
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                self.reopen()
            }
            self.onChange()
        }
        source.setCancelHandler { Darwin.close(descriptor) }

        lock.lock()
        self.source = source
        lock.unlock()
        source.resume()
    }

    private func reopen() {
        lock.lock()
        let current = source
        source = nil
        lock.unlock()
        current?.cancel()
        scheduleReopen()
    }

    private func scheduleReopen() {
        queue.asyncAfter(deadline: .now() + Self.reopenDelay) { [weak self] in
            self?.open()
        }
    }
}

/// FSEvents watch over a directory TREE (see `DirectoryWatcher` for why both exist).
public final class FileTreeWatcher: @unchecked Sendable {
    private let root: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let latency: CFTimeInterval

    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// - Parameter latency: how long FSEvents may coalesce events before delivering them. Apple's
    ///   guide is explicit that a larger latency is more efficient; 0.2s is far inside the ~0.5s
    ///   budget for noticing a session change, and it collapses the burst of writes a busy agent
    ///   produces into one callback.
    public init(
        root: URL,
        latency: CFTimeInterval = 0.2,
        queue: DispatchQueue = DispatchQueue(label: "com.miguelangelramirez.myagents.mac.treewatch", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.root = root
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // FileEvents: report individual files, not just the containing directory — a rollout being
        // appended to lives several levels down. NoDefer: deliver the FIRST event of a burst
        // immediately (then coalesce), so the first sign of activity isn't delayed by `latency`.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            // Deliberately ignores the path/flag arrays: the watcher's only job is to say "something
            // moved". The rescan it triggers is bounded and idempotent.
            guard let info else { return }
            Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        // `FSEventStreamScheduleWithRunLoop` is deprecated since macOS 13 — a dispatch queue is the
        // supported way to service the stream, and keeps this off the main thread.
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()

        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }
}
