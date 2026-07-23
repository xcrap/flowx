import Foundation

/// Pure projection rules shared by provider-native session synchronization.
/// A successful provider listing is authoritative for its visible window, even
/// when the provider reports that the window is capped. Failed providers are
/// intentionally absent from `successfullyListedProviders` and retain state.
public enum NativeProjectionPolicy {
    public static func identitiesToRemove<Identity: Hashable, ProviderID: Hashable>(
        visibleIdentities: [Identity],
        returnedIdentities: Set<Identity>,
        successfullyListedProviders: Set<ProviderID>,
        protectedIdentities: Set<Identity> = [],
        providerID: (Identity) -> ProviderID
    ) -> Set<Identity> {
        Set(visibleIdentities.filter { identity in
            successfullyListedProviders.contains(providerID(identity))
                && !returnedIdentities.contains(identity)
                && !protectedIdentities.contains(identity)
        })
    }

    /// Keeps every active identity and only a bounded number of dormant
    /// identities. `reserveIdentities` should already be ordered by recency or
    /// another deterministic priority chosen by the caller.
    public static func retainedIdentities<Identity: Hashable>(
        activeIdentities: [Identity],
        reserveIdentities: [Identity],
        reserveLimit: Int
    ) -> Set<Identity> {
        var retained = Set(activeIdentities)
        guard reserveLimit > 0 else { return retained }

        var reserved = 0
        for identity in reserveIdentities where !retained.contains(identity) {
            retained.insert(identity)
            reserved += 1
            if reserved >= reserveLimit { break }
        }
        return retained
    }
}
