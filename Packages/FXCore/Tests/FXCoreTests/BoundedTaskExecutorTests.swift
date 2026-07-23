import Darwin
import Foundation
import Testing
@testable import FXCore

@Test func boundedTaskExecutorLimitsConcurrentWork() async {
    let executor = BoundedTaskExecutor(maxConcurrentTasks: 2)
    let probe = ExecutorConcurrencyProbe()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                _ = try? await executor.run(priority: .utility) {
                    probe.begin()
                    usleep(20_000)
                    probe.end()
                }
            }
        }
    }

    #expect(probe.maximumActiveCount == 2)
}

@Test func boundedTaskExecutorRemovesCancelledWaitingWork() async throws {
    let executor = BoundedTaskExecutor(maxConcurrentTasks: 1)
    let probe = ExecutorCancellationProbe()
    let first = Task {
        try await executor.run {
            probe.blockFirstOperation()
            return 1
        }
    }

    let firstStarted = await waitForExecutorCondition {
        probe.firstOperationStarted
    }
    #expect(firstStarted)
    var releasedFirstOperation = false
    defer {
        if !releasedFirstOperation {
            probe.releaseFirstOperation()
        }
    }

    let waiting = Task {
        try await executor.run {
            probe.recordSecondOperation()
            return 2
        }
    }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()

    var receivedCancellation = false
    do {
        _ = try await waiting.value
    } catch is CancellationError {
        receivedCancellation = true
    } catch {
        Issue.record("Expected CancellationError, received \(error)")
    }

    #expect(receivedCancellation)
    #expect(probe.secondOperationCount == 0)

    probe.releaseFirstOperation()
    releasedFirstOperation = true
    _ = try await first.value
}

private final class ExecutorConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var storedMaximumActiveCount = 0

    var maximumActiveCount: Int {
        lock.withLock { storedMaximumActiveCount }
    }

    func begin() {
        lock.withLock {
            activeCount += 1
            storedMaximumActiveCount = max(storedMaximumActiveCount, activeCount)
        }
    }

    func end() {
        lock.withLock {
            activeCount -= 1
        }
    }
}

private final class ExecutorCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstOperationRelease = DispatchSemaphore(value: 0)
    private var storedFirstOperationStarted = false
    private var storedSecondOperationCount = 0

    var firstOperationStarted: Bool {
        lock.withLock { storedFirstOperationStarted }
    }

    var secondOperationCount: Int {
        lock.withLock { storedSecondOperationCount }
    }

    func blockFirstOperation() {
        lock.withLock {
            storedFirstOperationStarted = true
        }
        firstOperationRelease.wait()
    }

    func releaseFirstOperation() {
        firstOperationRelease.signal()
    }

    func recordSecondOperation() {
        lock.withLock {
            storedSecondOperationCount += 1
        }
    }
}

private func waitForExecutorCondition(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
