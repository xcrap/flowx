import Darwin
import Foundation
import os
import Security
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

    try #require(setQuarantine(on: quarantinedTarget))

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
    #expect(hasQuarantine(quarantinedTarget))

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

    try #require(setQuarantine(on: executable))

    // Providers consume the cached URL through resolvedPath rather than
    // RuntimeDiscovery.run, so that access must independently revalidate a
    // runtime that became quarantined after discovery. The unsigned script
    // cannot pass the notarization check, so it is reported as quarantined.
    let quarantinedPath = executable.resolvingSymlinksInPath().standardizedFileURL.path
    #expect(await discovery.resolvedPath(for: "quarantine-recheck-test") == nil)
    #expect(await discovery.resolvedLaunch(for: "quarantine-recheck-test") == nil)
    #expect(await discovery.health(for: "quarantine-recheck-test") == .quarantined(path: quarantinedPath))

    var rejectedAsUnavailable = false
    do {
        _ = try await discovery.run(
            binaryID: "quarantine-recheck-test",
            arguments: ["--run"]
        )
    } catch RuntimeDiscoveryError.binaryQuarantined(_, let path) {
        rejectedAsUnavailable = path == quarantinedPath
    } catch {
        Issue.record("Expected quarantined runtime to be unavailable, received \(error)")
    }

    #expect(rejectedAsUnavailable)
    #expect(!manager.fileExists(atPath: launchMarker.path))
}

@Test func versionProbeFindsInterpreterBesideMatchedSymlinkUnderMinimalGUIPath() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-nvm-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    // Mirror an nvm install: bin/tool links to an npm package's cli.js whose
    // `#!/usr/bin/env node` only resolves when bin/ is on PATH.
    func makeNodeVersion(_ version: String) throws -> URL {
        let root = container.appendingPathComponent("versions/node/\(version)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let package = root.appendingPathComponent("lib/node_modules/tool", isDirectory: true)
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'node-\(version):%s:%s' "$(basename "$1")" "$2"

            """,
            to: bin.appendingPathComponent("node")
        )
        try writeExecutable(
            """
            #!/usr/bin/env node
            this is not JavaScript; only the fake node above may run it

            """,
            to: package.appendingPathComponent("cli.js")
        )
        try manager.createSymbolicLink(
            atPath: bin.appendingPathComponent("tool").path,
            withDestinationPath: "../lib/node_modules/tool/cli.js"
        )
        return bin
    }
    _ = try makeNodeVersion("v18.0.0")
    let newestBin = try makeNodeVersion("v22.1.0")

    let discovery = RuntimeDiscovery(
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FLOWX_TEST_MARKER": "kept"],
        quarantineAssessor: { _ in false }
    )
    await discovery.register(BinarySpec(
        id: "nvm-test",
        displayName: "NVM test",
        searchPaths: [container.path + "/versions/node/*/bin/tool"],
        versionArgs: ["--version"]
    ))

    let fetchedVersion = await waitUntilAsync {
        await discovery.health(for: "nvm-test").version == "node-v22.1.0:cli.js:--version"
    }
    #expect(fetchedVersion)

    let expectedScript = newestBin
        .appendingPathComponent("../lib/node_modules/tool/cli.js")
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let launch = try #require(await discovery.resolvedLaunch(for: "nvm-test"))
    #expect(launch.executableURL == expectedScript)
    #expect(await discovery.resolvedPath(for: "nvm-test") == expectedScript)
    let pathEntries = launch.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    #expect(pathEntries.first == newestBin.standardizedFileURL.path)
    #expect(launch.environment["FLOWX_TEST_MARKER"] == "kept")

    let help = try await discovery.run(binaryID: "nvm-test", arguments: ["--help"])
    #expect(help.terminationStatus == 0)
    #expect(help.standardOutputString == "node-v22.1.0:cli.js:--help")
}

@Test func launchEnvironmentPrependsMatchedDirectoryAndPreferredRootsOnce() {
    let environment = RuntimeDiscovery.launchEnvironment(
        base: ["PATH": "/usr/bin::/opt/homebrew/bin:/bin:/usr/bin", "HOME": "/Users/flowx-test"],
        searchDirectory: "/Users/flowx-test/.nvm/versions/node/v22.1.0/bin"
    )
    let expected = ["/Users/flowx-test/.nvm/versions/node/v22.1.0/bin"]
        + RuntimeDiscovery.preferredSearchDirectories
        + ["/usr/bin", "/bin"]
    #expect(environment["PATH"] == expected.joined(separator: ":"))
    #expect(environment["HOME"] == "/Users/flowx-test")

    let withoutPath = RuntimeDiscovery.launchEnvironment(base: [:], searchDirectory: nil)
    let expectedDefault = RuntimeDiscovery.preferredSearchDirectories
        + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    #expect(withoutPath["PATH"] == expectedDefault.joined(separator: ":"))
}

@Test func quarantinedExecutableAcceptedByAssessorIsUsableAndKeepsQuarantine() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-notarized-\(UUID().uuidString)", isDirectory: true)
    let executable = container.appendingPathComponent("codex")
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    try writeExecutable(
        """
        #!/bin/sh
        printf 'notarized-version'

        """,
        to: executable
    )
    try #require(setQuarantine(on: executable))

    let resolvedExecutable = executable.resolvingSymlinksInPath().standardizedFileURL
    let assessed = OSAllocatedUnfairLock<[URL]>(initialState: [])
    let discovery = RuntimeDiscovery(
        environment: ProcessInfo.processInfo.environment,
        quarantineAssessor: { url in
            assessed.withLock { $0.append(url) }
            return true
        }
    )
    await discovery.register(BinarySpec(
        id: "notarized-test",
        displayName: "Notarized test",
        searchPaths: [executable.path],
        versionArgs: ["--version"]
    ))

    let fetchedVersion = await waitUntilAsync {
        await discovery.health(for: "notarized-test").version == "notarized-version"
    }
    #expect(fetchedVersion)
    #expect(await discovery.resolvedLaunch(for: "notarized-test")?.executableURL == resolvedExecutable)
    #expect(assessed.withLock { $0 }.allSatisfy { $0 == resolvedExecutable })
    #expect(!assessed.withLock { $0.isEmpty })
    #expect(hasQuarantine(executable))
}

@Test func quarantinedExecutableFailingNotarizationReportsQuarantinedStatus() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-cask-\(UUID().uuidString)", isDirectory: true)
    let caskBin = container.appendingPathComponent("Caskroom/tool/1.0/bin", isDirectory: true)
    let linkBin = container.appendingPathComponent("bin", isDirectory: true)
    let target = caskBin.appendingPathComponent("tool")
    let link = linkBin.appendingPathComponent("tool")
    let launchMarker = container.appendingPathComponent("launched")
    try manager.createDirectory(at: caskBin, withIntermediateDirectories: true)
    try manager.createDirectory(at: linkBin, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    try writeExecutable(
        """
        #!/bin/sh
        : > "\(launchMarker.path)"
        printf 'unsigned-version'

        """,
        to: target
    )
    try manager.createSymbolicLink(at: link, withDestinationURL: target)
    try #require(setQuarantine(on: target))

    // Real assessor: an unsigned script cannot satisfy the notarization bar.
    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(
        id: "cask-test",
        displayName: "Cask test",
        searchPaths: [link.path, container.appendingPathComponent("missing/tool").path],
        versionArgs: ["--version"],
        installHint: "npm install -g cask-test"
    ))

    let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
    let health = await discovery.health(for: "cask-test")
    #expect(health == .quarantined(path: targetPath))
    #expect(!health.isUsable)
    #expect(health.path == targetPath)
    #expect(health.statusLabel == "Quarantined")
    let guidance = try #require(health.guidance)
    #expect(guidance.contains("xattr -d com.apple.quarantine '\(targetPath)'"))

    let message = await discovery.unavailableMessage(for: "cask-test")
    #expect(message.contains("Cask test was found at \(targetPath)"))
    #expect(message.contains(guidance))
    #expect(!message.contains("npm install"))

    #expect(await discovery.resolvedLaunch(for: "cask-test") == nil)
    #expect(await discovery.health(for: "cask-test") == .quarantined(path: targetPath))
    await discovery.refreshAll()
    #expect(await discovery.health(for: "cask-test") == .quarantined(path: targetPath))
    #expect(!manager.fileExists(atPath: launchMarker.path))
    #expect(hasQuarantine(target))
}

@Test func missingRuntimeKeepsInstallHintMessage() async {
    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(
        id: "missing-test",
        displayName: "Missing test",
        searchPaths: ["/nonexistent/flowx-\(UUID().uuidString)/tool"],
        installHint: "npm install -g missing-test"
    ))
    #expect(await discovery.health(for: "missing-test") == .notFound)
    #expect(await discovery.unavailableMessage(for: "missing-test")
        == "Missing test CLI not found. Install with: npm install -g missing-test")
}

@Test func notarizationRequirementCompilesAndGatesQuarantinedCodeBySignature() throws {
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(
        QuarantineAssessment.requirement as CFString,
        [],
        &requirement
    ) == errSecSuccess)

    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-runtime-signed-\(UUID().uuidString)", isDirectory: true)
    let signedCopy = container.appendingPathComponent("ls")
    let unsignedScript = container.appendingPathComponent("script")
    try manager.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    // An Apple-signed binary keeps its embedded signature when copied, so it
    // clears Gatekeeper's bar deterministically on any Mac.
    try manager.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: signedCopy)
    try #require(setQuarantine(on: signedCopy))
    #expect(QuarantineAssessment.passesGatekeeperNotarization(signedCopy))
    #expect(QuarantineAssessment.passesGatekeeperNotarization(signedCopy))

    // Any rewrite invalidates the remembered approval and the signature.
    let handle = try FileHandle(forWritingTo: signedCopy)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    #expect(!QuarantineAssessment.passesGatekeeperNotarization(signedCopy))

    try writeExecutable("#!/bin/sh\nexit 0\n", to: unsignedScript)
    try #require(setQuarantine(on: unsignedScript))
    #expect(!QuarantineAssessment.passesGatekeeperNotarization(unsignedScript))
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// Writes a well-formed quarantine value (flags;hex-time;agent;event). The
/// kernel refuses to exec files with a malformed value, which would let a
/// test pass even if FlowX wrongly tried to launch the file.
private func setQuarantine(on url: URL) -> Bool {
    let timestamp = String(Int(Date().timeIntervalSince1970), radix: 16)
    let value = Data("0081;\(timestamp);FlowXTests;".utf8)
    return value.withUnsafeBytes { bytes in
        setxattr(url.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
    } == 0
}

private func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
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
