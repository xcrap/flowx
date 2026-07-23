import Darwin
import Foundation
import os

public enum ClaudeSessionConcurrencyError: LocalizedError, Sendable, Equatable {
    case alreadyRunningInFlowX(sessionID: String)
    case alreadyActiveInClaudeCode(sessionID: String)
    case invalidSessionID(sessionID: String)
    case sessionLockUnavailable(sessionID: String)
    case activityStatusUnavailable(sessionID: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunningInFlowX(let sessionID):
            "Claude session '\(sessionID)' already has a turn running in FlowX. Wait for it to finish or cancel it before sending another message."
        case .alreadyActiveInClaudeCode(let sessionID):
            "Claude session '\(sessionID)' is already active in another Claude Code process. Continue it there, or stop and exit that session before resuming it in FlowX."
        case .invalidSessionID(let sessionID):
            "Claude session '\(sessionID)' is not a valid session identifier, so FlowX will not resume it."
        case .sessionLockUnavailable(let sessionID):
            "FlowX could not safely reserve Claude session '\(sessionID)'. Check the per-user FlowX application-support directory and retry."
        case .activityStatusUnavailable(let sessionID):
            "FlowX could not verify whether Claude session '\(sessionID)' is active in another Claude Code process. Retry before resuming it."
        }
    }
}

/// Prevents two turns in any FlowX Debug or Release process owned by this user
/// from resuming the same provider transcript at once. The in-memory reservation
/// closes same-process races before filesystem work begins. The kernel advisory
/// lock closes cross-process races and is held until `release`; process death
/// closes the descriptor automatically. Lock files deliberately remain in place:
/// their existence is never treated as activity, so a crash cannot leave a stale
/// false positive.
final class ClaudeSessionLeaseRegistry: @unchecked Sendable {
    private enum LeaseDescriptor {
        case acquiring
        case held(Int32)
    }

    private enum CrossProcessLockError: Error {
        case alreadyLocked
        case unavailable
    }

    private let lockDirectoryURL: URL
    private let leases = OSAllocatedUnfairLock(initialState: [String: LeaseDescriptor]())

    init(lockDirectoryURL: URL? = nil) {
        self.lockDirectoryURL = lockDirectoryURL ?? Self.defaultLockDirectoryURL
    }

    deinit {
        let descriptors = leases.withLock { leases -> [Int32] in
            let descriptors = leases.values.compactMap { lease -> Int32? in
                guard case .held(let descriptor) = lease else { return nil }
                return descriptor
            }
            leases.removeAll(keepingCapacity: false)
            return descriptors
        }
        for descriptor in descriptors {
            Self.closeLockDescriptor(descriptor)
        }
    }

    func acquire(_ sessionID: String) throws {
        let key = try Self.normalized(sessionID)
        let acquired = leases.withLock { leases in
            guard leases[key] == nil else { return false }
            leases[key] = .acquiring
            return true
        }
        guard acquired else {
            throw ClaudeSessionConcurrencyError.alreadyRunningInFlowX(sessionID: sessionID)
        }

        do {
            let descriptor = try acquireCrossProcessLock(for: key)
            leases.withLock { leases in
                leases[key] = .held(descriptor)
            }
        } catch {
            leases.withLock { leases in
                leases[key] = nil
            }
            switch error {
            case CrossProcessLockError.alreadyLocked:
                throw ClaudeSessionConcurrencyError.alreadyRunningInFlowX(sessionID: sessionID)
            default:
                throw ClaudeSessionConcurrencyError.sessionLockUnavailable(sessionID: sessionID)
            }
        }
    }

    func release(_ sessionID: String) {
        guard let key = try? Self.normalized(sessionID) else { return }
        let descriptor = leases.withLock { leases -> Int32? in
            guard case .held(let descriptor) = leases.removeValue(forKey: key) else {
                return nil
            }
            return descriptor
        }
        if let descriptor {
            Self.closeLockDescriptor(descriptor)
        }
    }

    private func acquireCrossProcessLock(for normalizedSessionID: String) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: lockDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CrossProcessLockError.unavailable
        }

        let directoryDescriptor = open(
            lockDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw CrossProcessLockError.unavailable
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              fchmod(directoryDescriptor, 0o700) == 0 else {
            throw CrossProcessLockError.unavailable
        }

        let filename = "\(normalizedSessionID).lock"
        let descriptor = filename.withCString { filenamePointer in
            openat(
                directoryDescriptor,
                filenamePointer,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw CrossProcessLockError.unavailable
        }

        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }

        var fileMetadata = stat()
        guard fstat(descriptor, &fileMetadata) == 0,
              fileMetadata.st_mode & S_IFMT == S_IFREG,
              fileMetadata.st_uid == geteuid(),
              fileMetadata.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            throw CrossProcessLockError.unavailable
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw CrossProcessLockError.alreadyLocked
            }
            throw CrossProcessLockError.unavailable
        }

        shouldCloseDescriptor = false
        return descriptor
    }

    private static var defaultLockDirectoryURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("FlowX", isDirectory: true)
            .appendingPathComponent("ProviderSessionLocks", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
    }

    private static func normalized(_ sessionID: String) throws -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else {
            throw ClaudeSessionConcurrencyError.invalidSessionID(sessionID: sessionID)
        }
        return uuid.uuidString.lowercased()
    }

    private static func closeLockDescriptor(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

enum ClaudeSessionActivitySnapshot {
    /// `claude agents --json` omits completed background sessions unless
    /// `--all` is passed. Therefore every exact session ID returned by the
    /// unqualified command is unsafe to resume in a second process, including
    /// an idle interactive process and a blocked background session.
    static func activeSessionIDs(from data: Data) -> Set<String>? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return Set(rows.compactMap { row in
            guard let sessionID = row["sessionId"] as? String else { return nil }
            let normalized = sessionID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }

    static func contains(sessionID: String, in data: Data) -> Bool? {
        guard let sessionIDs = activeSessionIDs(from: data) else { return nil }
        let normalized = sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return sessionIDs.contains(normalized)
    }

    static func helpAdvertisesJSONListing(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("--json")
            && text.contains("active sessions")
    }

    static func versionSupportsJSONListing(_ version: String?) -> Bool {
        guard let version else { return false }
        let candidates = version.split { character in
            !character.isNumber && character != "."
        }
        guard let components = candidates.lazy.compactMap({ candidate -> [Int]? in
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            let numbers = parts.prefix(3).compactMap { Int($0) }
            return numbers.count == 3 ? numbers : nil
        }).first else {
            return false
        }

        let minimum = [2, 1, 145]
        for index in minimum.indices {
            if components[index] != minimum[index] {
                return components[index] > minimum[index]
            }
        }
        return true
    }
}
