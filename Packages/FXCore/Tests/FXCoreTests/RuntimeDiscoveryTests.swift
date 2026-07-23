import Darwin
import Foundation
import Testing
@testable import FXCore

@Test func runtimeCancellationTerminatesChildBeforeReturning() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-cancel-\(UUID().uuidString)", isDirectory: true)
    let pidFile = container.appendingPathComponent("child.pid")
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(
        id: "test-shell",
        displayName: "Test shell",
        searchPaths: ["/bin/sh"],
        versionArgs: ["-c", "printf 'test-shell'"]
    ))

    let command = "echo $$ > \"$1\"; exec /bin/sleep 30"
    let task = Task {
        try await discovery.run(
            binaryID: "test-shell",
            arguments: ["-c", command, "flowx-runtime-test", pidFile.path],
            timeout: 60
        )
    }

    let pidPath = pidFile.path
    let wrotePID = await waitUntil { FileManager.default.fileExists(atPath: pidPath) }
    #expect(wrotePID)
    let processIdentifier = try #require(readPID(from: pidFile))

    let clock = ContinuousClock()
    let cancellationStarted = clock.now
    task.cancel()

    var receivedCancellation = false
    do {
        _ = try await task.value
    } catch is CancellationError {
        receivedCancellation = true
    } catch {
        Issue.record("Expected CancellationError, received \(error)")
    }

    #expect(receivedCancellation)
    #expect(cancellationStarted.duration(to: clock.now) < .seconds(2))
    #expect(await waitUntil { !processExists(processIdentifier) })
}

@Test func refreshWaitsForCancelledVersionProbeBeforeStartingReplacement() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-version-overlap-\(UUID().uuidString)", isDirectory: true)
    let markerFile = container.appendingPathComponent("started")
    let pidFile = container.appendingPathComponent("first.pid")
    let overlapFile = container.appendingPathComponent("overlap")
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let versionCommand = """
    if [ ! -e "$1" ]; then
      : > "$1"
      echo $$ > "$2"
      exec /bin/sleep 30
    fi
    old_pid=$(cat "$2")
    if kill -0 "$old_pid" 2>/dev/null; then
      : > "$3"
    fi
    printf 'replacement-version'
    """
    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(
        id: "version-overlap-test",
        displayName: "Version overlap test",
        searchPaths: ["/bin/sh"],
        versionArgs: [
            "-c",
            versionCommand,
            "flowx-version-test",
            markerFile.path,
            pidFile.path,
            overlapFile.path,
        ]
    ))

    let pidPath = pidFile.path
    let startedFirstProbe = await waitUntil { FileManager.default.fileExists(atPath: pidPath) }
    #expect(startedFirstProbe)
    let firstProcessIdentifier = try #require(readPID(from: pidFile))

    await discovery.refreshAll()

    #expect(!manager.fileExists(atPath: overlapFile.path))
    #expect(!processExists(firstProcessIdentifier))
    #expect(await discovery.health(for: "version-overlap-test") == .available(
        path: "/bin/sh",
        version: "replacement-version"
    ))
}

@Test func quarantinedSymlinkTargetIsSkippedWithoutLaunchingOrRemovingQuarantine() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-quarantine-\(UUID().uuidString)", isDirectory: true)
    let quarantinedTarget = container.appendingPathComponent("quarantined-codex")
    let quarantinedSymlink = container.appendingPathComponent("preferred-codex")
    let cleanFallback = container.appendingPathComponent("clean-codex")
    let launchMarker = container.appendingPathComponent("quarantined-launched")
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    try Data(
        """
        #!/bin/sh
        : > "\(launchMarker.path)"
        printf 'quarantined-version'

        """.utf8
    ).write(to: quarantinedTarget)
    try Data(
        """
        #!/bin/sh
        printf 'clean-version'

        """.utf8
    ).write(to: cleanFallback)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quarantinedTarget.path)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cleanFallback.path)
    try manager.createSymbolicLink(at: quarantinedSymlink, withDestinationURL: quarantinedTarget)

    let quarantineValue = Data("0081;flowx-runtime-test".utf8)
    let quarantineResult = quarantineValue.withUnsafeBytes { bytes in
        setxattr(
            quarantinedTarget.path,
            "com.apple.quarantine",
            bytes.baseAddress,
            bytes.count,
            0,
            0
        )
    }
    try #require(quarantineResult == 0)

    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(
        id: "quarantine-test",
        displayName: "Quarantine test",
        searchPaths: [quarantinedSymlink.path, cleanFallback.path],
        versionArgs: []
    ))

    let cleanResolvedPath = cleanFallback.resolvingSymlinksInPath().standardizedFileURL.path
    #expect(await discovery.resolvedPath(for: "quarantine-test")?.path == cleanResolvedPath)
    #expect(!manager.fileExists(atPath: launchMarker.path))
    #expect(getxattr(
        quarantinedTarget.path,
        "com.apple.quarantine",
        nil,
        0,
        0,
        0
    ) >= 0)

    let fetchedCleanVersion = await waitUntilAsync {
        await discovery.health(for: "quarantine-test").version == "clean-version"
    }
    #expect(fetchedCleanVersion)
    #expect(!manager.fileExists(atPath: launchMarker.path))
}

@Test func runtimeRechecksQuarantineBeforeLaunchingPreviouslySelectedExecutable() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-recheck-\(UUID().uuidString)", isDirectory: true)
    let executable = container.appendingPathComponent("codex")
    let launchMarker = container.appendingPathComponent("launched")
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    try Data(
        """
        #!/bin/sh
        if [ "$1" = "--run" ]; then
          : > "\(launchMarker.path)"
        fi
        printf 'runtime-version'

        """.utf8
    ).write(to: executable)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(
        id: "quarantine-recheck-test",
        displayName: "Quarantine recheck test",
        searchPaths: [executable.path],
        versionArgs: ["--version"]
    ))
    let fetchedVersion = await waitUntilAsync {
        await discovery.health(for: "quarantine-recheck-test").version == "runtime-version"
    }
    try #require(fetchedVersion)

    let quarantineValue = Data("0081;flowx-runtime-recheck".utf8)
    let quarantineResult = quarantineValue.withUnsafeBytes { bytes in
        setxattr(
            executable.path,
            "com.apple.quarantine",
            bytes.baseAddress,
            bytes.count,
            0,
            0
        )
    }
    try #require(quarantineResult == 0)

    // Providers consume the cached URL through resolvedPath rather than
    // RuntimeDiscovery.run, so that access must independently revalidate a
    // runtime that became quarantined after discovery.
    #expect(await discovery.resolvedPath(for: "quarantine-recheck-test") == nil)
    #expect(await discovery.health(for: "quarantine-recheck-test") == .notFound)

    var rejectedAsUnavailable = false
    do {
        _ = try await discovery.run(
            binaryID: "quarantine-recheck-test",
            arguments: ["--run"]
        )
    } catch RuntimeDiscoveryError.binaryNotFound {
        rejectedAsUnavailable = true
    } catch {
        Issue.record("Expected quarantined runtime to be unavailable, received \(error)")
    }

    #expect(rejectedAsUnavailable)
    #expect(!manager.fileExists(atPath: launchMarker.path))
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private func readPID(from url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          value > 0
    else {
        return nil
    }
    return value
}

private func processExists(_ processIdentifier: pid_t) -> Bool {
    if kill(processIdentifier, 0) == 0 {
        return true
    }
    return errno == EPERM
}
