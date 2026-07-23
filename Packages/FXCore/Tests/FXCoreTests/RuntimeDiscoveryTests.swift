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
