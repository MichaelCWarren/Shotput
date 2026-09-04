import CoreServices
import Foundation

/// Watches one folder with FSEvents and calls back on any change, coalesced
/// so a burst of writes (e.g. `screencapture` writing the file then its
/// xattr) produces one call. The callback ignores paths and flags and just
/// tells the store to rescan; the folder holds tens of files, not thousands,
/// so a full rescan-and-diff is simpler and safer than decoding per-file
/// event flags.
final class FolderWatcher {
    /// Holds everything the FSEvents callback touches, under a lock, because
    /// the callback runs on `queue` while `stop()` runs on the main thread.
    /// The stream owns a reference to it, so an event already in flight when
    /// the folder changes can't land on a torn-down watcher.
    private final class Target {
        private let latency: TimeInterval
        private let onChange: () -> Void
        private let lock = NSLock()
        private var pendingWorkItem: DispatchWorkItem?
        private var isStopped = false

        init(latency: TimeInterval, onChange: @escaping () -> Void) {
            self.latency = latency
            self.onChange = onChange
        }

        func scheduleCallback() {
            lock.lock()
            defer { lock.unlock() }
            guard !isStopped else { return }
            pendingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [onChange] in onChange() }
            pendingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + latency, execute: workItem)
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            isStopped = true
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }

    private let folder: URL
    private let latency: TimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.shotput.folderwatcher")
    private var stream: FSEventStreamRef?
    private var target: Target?

    init(folder: URL, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.folder = folder
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        let target = Target(latency: latency, onChange: onChange)
        let info = Unmanaged.passRetained(target).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Target>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Target>.fromOpaque(info).takeUnretainedValue().scheduleCallback()
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            // Nothing will ever call the release callback, so balance the
            // retain here.
            Unmanaged<Target>.fromOpaque(info).release()
            return
        }

        stream = newStream
        self.target = target
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
    }

    func stop() {
        target?.stop()
        target = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
