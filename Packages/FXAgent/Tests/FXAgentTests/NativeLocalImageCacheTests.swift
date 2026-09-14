import Foundation
import Testing
import os
@testable import FXAgent
@testable import FXCore

@Test func nativeImageCacheDoesNotBlockTranscriptOnSlowFileRead() async throws {
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let started = OSAllocatedUnfairLock(initialState: false)
    let cache = NativeLocalImageCache { _ in
        started.withLock { $0 = true }
        gate.wait()
        return .image(data: Data([1, 2, 3]), mimeType: "image/png")
    }
    let key = NativeLocalImageCache.Key(path: "/slow/image.png", size: 3, modifiedAt: .distantPast)
    var budget = 10
    let initial = cache.content(for: key, remainingBytes: &budget)
    #expect(initial == nil)
    #expect(budget == 7)
    let startDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !started.withLock({ $0 }), ContinuousClock.now < startDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(started.withLock { $0 })
    budget = 10
    let pending = cache.content(for: key, remainingBytes: &budget)
    #expect(pending == nil)
    #expect(cache.revision == 0)
    gate.signal()

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while cache.revision == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    budget = 10
    let loaded = cache.content(for: key, remainingBytes: &budget)
    #expect(loaded == .image(data: Data([1, 2, 3]), mimeType: "image/png"))
    #expect(cache.revision == 1)
    #expect(budget == 7)
    budget = 2
    let overBudget = cache.content(for: key, remainingBytes: &budget)
    #expect(overBudget == nil)
    #expect(budget == 2)
}

@Test func nativeImageCacheRejectsFileSizeChangesAfterLookup() async throws {
    let cache = NativeLocalImageCache { _ in
        .image(data: Data([1, 2, 3, 4]), mimeType: "image/png")
    }
    let key = NativeLocalImageCache.Key(path: "/changed/image.png", size: 3, modifiedAt: .distantPast)
    var budget = 3
    _ = cache.content(for: key, remainingBytes: &budget)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while cache.revision == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(cache.revision == 1)
    budget = 3
    let content = cache.content(for: key, remainingBytes: &budget)
    #expect(content == nil)
    #expect(budget == 3)
}

@Test func nativeImageCacheRemembersFailedReadsWithoutRepeatedWork() async throws {
    let cache = NativeLocalImageCache { _ in nil }
    let key = NativeLocalImageCache.Key(path: "/unavailable/image.png", size: 3, modifiedAt: .distantPast)
    var budget = 10
    _ = cache.content(for: key, remainingBytes: &budget)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while cache.revision == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(cache.revision == 1)
    for _ in 0..<100 {
        budget = 10
        let content = cache.content(for: key, remainingBytes: &budget)
        #expect(content == nil)
        #expect(budget == 10)
    }
    #expect(cache.revision == 1)
}
