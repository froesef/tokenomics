import Foundation
import CoreServices

/// The FSEvents boilerplate shared by `TranscriptWatcher` (~/.claude) and `CodexSessionWatcher`
/// (~/.codex): watch one directory tree and invoke a closure on the main actor whenever anything
/// underneath it changes. Neither watcher cares about *what* changed, only that a rescan is due.
@MainActor
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let pathsToWatch = [path] as CFArray
        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
