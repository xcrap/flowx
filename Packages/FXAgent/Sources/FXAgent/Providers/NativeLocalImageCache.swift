import Foundation
import FXCore
import os

/// File opens can wait on macOS privacy or cloud-file services. They must not
/// occupy the provider actor that delivers the rest of the transcript.
final class NativeLocalImageCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let path: String
        let size: Int
        let modifiedAt: Date
    }

    private struct Entry {
        var isLoading: Bool
        var content: MessageContent?
        var lastAccess: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var revision: UInt64 = 0
        var access: UInt64 = 0
        var bytes = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())
    private let workers: OperationQueue
    private let maximumBytes: Int
    private let loader: @Sendable (String) -> MessageContent?

    init(
        maximumBytes: Int = ProviderNativeImageImporter.maximumTranscriptImageBytes,
        loader: @escaping @Sendable (String) -> MessageContent? = { path in
            var budget = ProviderNativeImageImporter.maximumImageBytes
            return ProviderNativeImageImporter.localFile(atPath: path, remainingBytes: &budget)
        }
    ) {
        self.maximumBytes = maximumBytes
        self.loader = loader
        workers = OperationQueue()
        workers.name = "com.flowx.native-image-import"
        workers.qualityOfService = .utility
        workers.maxConcurrentOperationCount = 2
    }

    var revision: UInt64 { storage.withLock { $0.revision } }

    func content(for key: Key, remainingBytes: inout Int) -> MessageContent? {
        guard key.size > 0, key.size <= min(remainingBytes, maximumBytes) else { return nil }
        let lookup = storage.withLock { state -> (MessageContent?, Bool, Bool) in
            state.access &+= 1
            if var entry = state.entries[key] {
                entry.lastAccess = state.access
                state.entries[key] = entry
                return (entry.content, false, entry.isLoading)
            }
            // Bound both queued file reads and remembered failures.
            guard state.entries.values.filter({ $0.isLoading }).count < 16 else {
                return (nil, false, false)
            }
            state.entries[key] = Entry(isLoading: true, content: nil, lastAccess: state.access)
            return (nil, true, true)
        }
        if lookup.2 || lookup.0 != nil { remainingBytes -= key.size }
        if lookup.1 {
            workers.addOperation { [self] in
                // A file may change after the caller read its metadata. Only
                // retain bytes belonging to the requested size/budget.
                let loaded = loader(key.path)
                let content: MessageContent?
                if case .image(let data, _) = loaded, data.count == key.size {
                    content = loaded
                } else {
                    content = nil
                }
                storage.withLock { state in
                    guard var entry = state.entries[key] else { return }
                    entry.isLoading = false
                    entry.content = content
                    state.entries[key] = entry
                    if content != nil { state.bytes += key.size }
                    state.revision &+= 1
                    while state.bytes > maximumBytes || state.entries.count > 128 {
                        guard let oldest = state.entries.filter({ !$0.value.isLoading })
                            .min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
                        if oldest.value.content != nil { state.bytes -= oldest.key.size }
                        state.entries.removeValue(forKey: oldest.key)
                    }
                }
            }
        }
        return lookup.0
    }
}
