import Foundation
import CoreServices

/// Recursive file system watcher backed by FSEvents. Calls `onChange` (debounced) when
/// anything under the watched roots changes. Re-indexes only the changed paths thanks to
/// the Indexer's mtime/size dedup, so the cost of frequent notifications is low.
///
/// The class bridges `self` through FSEvents' `info` pointer using Unmanaged, so the
/// C callback can dispatch back into Swift.
final class FileSystemWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void

    /// Debounce: many FSEvents arrive in bursts. We coalesce into a single `onChange`
    /// call this many seconds after the last event.
    private var pendingWorkItem: DispatchWorkItem?

    init(latency: TimeInterval = 1.0, debounce: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.queue = DispatchQueue(label: "com.smukherjee.findersearch.fsevents", qos: .utility)
        self.latency = latency
        self.onChange = onChange
        self.debounce = debounce
    }

    private let debounce: TimeInterval

    func start(roots: [URL]) {
        stop()
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, eventIds in
                guard let info else { return }
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handleEvents(count: numEvents, paths: eventPaths, flags: eventFlags)
            },
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            print("[FileSystemWatcher] FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            print("[FileSystemWatcher] FSEventStreamStart failed")
            return
        }
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    deinit {
        // `stream` is a CFType; FSEventStreamInvalidate/Release must be called before deinit
        // releases `self`. We do that in stop(); if it wasn't called, do it here.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func handleEvents(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        let cfArray = unsafeBitCast(paths, to: CFArray.self)
        let nsArray = cfArray as NSArray
        let affected = nsArray as? [String] ?? []
        if affected.isEmpty { return }

        // Debounce: schedule a single `onChange` call `debounce` seconds from now.
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingWorkItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
