import Foundation

/// Runs synchronous work away from the caller while limiting how many jobs can
/// execute at once. Cancellation removes work that is still waiting and is
/// forwarded to a job that has already started.
public actor BoundedTaskExecutor {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumConcurrentTasks: Int
    private var activeTaskCount = 0
    private var waiters: [Waiter] = []

    public init(maxConcurrentTasks: Int) {
        maximumConcurrentTasks = max(1, maxConcurrentTasks)
    }

    public func run<Output: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await acquirePermit()
        defer { releasePermit() }

        try Task.checkCancellation()
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation()
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func acquirePermit() async throws {
        try Task.checkCancellation()

        if activeTaskCount < maximumConcurrentTasks {
            activeTaskCount += 1
            return
        }

        let waiterID = UUID()
        let wasGranted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }

        guard wasGranted else {
            throw CancellationError()
        }

        // A permit can be handed off at the same instant the waiting caller is
        // cancelled. Return that permit here so it cannot be leaked.
        if Task.isCancelled {
            releasePermit()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releasePermit() {
        if waiters.isEmpty {
            activeTaskCount = max(0, activeTaskCount - 1)
            return
        }

        // Transfer the active permit directly to the oldest waiting task.
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
    }
}
