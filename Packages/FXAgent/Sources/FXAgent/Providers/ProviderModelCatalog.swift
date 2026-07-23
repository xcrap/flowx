import os

final class ProviderModelCatalog: @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<[AIModel]>

    init(_ models: [AIModel]) {
        storage = OSAllocatedUnfairLock(initialState: models)
    }

    var models: [AIModel] {
        storage.withLock { $0 }
    }

    func replace(with models: [AIModel]) {
        guard !models.isEmpty else { return }
        storage.withLock { $0 = models }
    }
}
