import Foundation
import CoreServices

/// Watches the notes folder tree via FSEvents and fires a debounced
/// callback. Events are only a "something changed" signal — the store's
/// `reload()` does the actual reconciliation (and reports false when the
/// change was our own write, so self-triggered events are harmless).
public final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    public init(url: URL, debounce: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleCallback()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // FSEvents' own coalescing latency; we debounce on top
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            NSLog("Seanboy: failed to create FSEvent stream for \(url.path)")
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
