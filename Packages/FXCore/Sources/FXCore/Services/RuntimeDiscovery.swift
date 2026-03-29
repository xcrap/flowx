import Foundation

public enum BinaryHealth: Sendable, Equatable {
    case checking
    case available(path: String, version: String?)
    case notFound

    public var isUsable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var path: String? {
        if case .available(let path, _) = self {
            return path
        }
        return nil
    }

    public var version: String? {
        if case .available(_, let version) = self {
            return version
        }
        return nil
    }

    public var statusLabel: String {
        switch self {
        case .checking:
            "Checking…"
        case .available(_, let version):
            version ?? "Installed"
        case .notFound:
            "Not found"
        }
    }
}

public struct BinarySpec: Sendable {
    public let id: String
    public let displayName: String
    public let searchPaths: [String]
    public let versionArgs: [String]
    public let shellFallbackName: String?
    public let installHint: String?

    public init(
        id: String,
        displayName: String,
        searchPaths: [String],
        versionArgs: [String] = ["--version"],
        shellFallbackName: String? = nil,
        installHint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.searchPaths = searchPaths
        self.versionArgs = versionArgs
        self.shellFallbackName = shellFallbackName
        self.installHint = installHint
    }
}

public actor RuntimeDiscovery {
    private var specs: [String: BinarySpec] = [:]
    private var resolved: [String: URL] = [:]
    private var healthCache: [String: BinaryHealth] = [:]
    private var versionTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public func register(_ spec: BinarySpec) {
        specs[spec.id] = spec
        healthCache[spec.id] = .checking

        if let url = findBinary(spec) {
            resolved[spec.id] = url
            healthCache[spec.id] = .available(path: url.path, version: nil)
            launchVersionCheck(for: spec, at: url)
        } else {
            healthCache[spec.id] = .notFound
        }
    }

    public func resolvedPath(for binaryID: String) -> URL? {
        resolved[binaryID]
    }

    public func health(for binaryID: String) -> BinaryHealth {
        healthCache[binaryID] ?? .notFound
    }

    public func allHealth() -> [String: BinaryHealth] {
        healthCache
    }

    public func spec(for binaryID: String) -> BinarySpec? {
        specs[binaryID]
    }

    public func allSpecs() -> [BinarySpec] {
        Array(specs.values)
    }

    public func refreshAll() async {
        for task in versionTasks.values {
            task.cancel()
        }
        versionTasks.removeAll()

        for (id, spec) in specs {
            healthCache[id] = .checking
            if let url = findBinary(spec) {
                resolved[id] = url
                healthCache[id] = .available(path: url.path, version: nil)
                await fetchAndStoreVersion(for: spec, at: url)
            } else {
                resolved[id] = nil
                healthCache[id] = .notFound
            }
        }
    }

    private func findBinary(_ spec: BinarySpec) -> URL? {
        for pattern in spec.searchPaths {
            if pattern.contains("*") {
                for expanded in expandGlob(pattern) {
                    if FileManager.default.isExecutableFile(atPath: expanded) {
                        return URL(fileURLWithPath: expanded)
                    }
                }
            } else if FileManager.default.isExecutableFile(atPath: pattern) {
                return URL(fileURLWithPath: pattern)
            }
        }

        if let name = spec.shellFallbackName, let path = shellWhich(name) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func expandGlob(_ pattern: String) -> [String] {
        let components = (pattern as NSString).pathComponents
        guard let starIndex = components.firstIndex(where: { $0.contains("*") }) else {
            return [pattern]
        }

        let baseComponents = Array(components[..<starIndex])
        let globSegment = components[starIndex]
        let suffixComponents = Array(components[(starIndex + 1)...])

        let baseDir = NSString.path(withComponents: baseComponents)
        let suffix = suffixComponents.isEmpty ? "" : NSString.path(withComponents: suffixComponents)

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDir) else {
            return []
        }

        var results: [String] = []
        for entry in entries {
            if globSegment == "*" || matchesGlob(entry, pattern: globSegment) {
                var candidate = (baseDir as NSString).appendingPathComponent(entry)
                if !suffix.isEmpty {
                    candidate = (candidate as NSString).appendingPathComponent(suffix)
                }
                results.append(candidate)
            }
        }
        return results
    }

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        let predicate = NSPredicate(format: "SELF LIKE %@", pattern)
        return predicate.evaluate(with: string)
    }

    private func shellWhich(_ name: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which \(name)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = DispatchTime.now() + .seconds(5)
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        guard let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty
        else {
            return nil
        }

        return output
    }

    private func launchVersionCheck(for spec: BinarySpec, at url: URL) {
        versionTasks[spec.id] = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndStoreVersion(for: spec, at: url)
        }
    }

    private func fetchAndStoreVersion(for spec: BinarySpec, at url: URL) async {
        let version = await fetchVersion(at: url, args: spec.versionArgs)
        if !Task.isCancelled {
            healthCache[spec.id] = .available(path: url.path, version: version)
        }
    }

    private func fetchVersion(at url: URL, args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = url
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            DispatchQueue.global().async {
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let text = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?
                .trimmingCharacters(in: .whitespacesAndNewlines)

                continuation.resume(returning: text?.nilIfEmpty)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
