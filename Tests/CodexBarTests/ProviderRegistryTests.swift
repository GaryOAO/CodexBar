import CodexBarCore
import Testing
@testable import CodexBar

struct ProviderRegistryTests {
    @Test
    func `descriptor registry is complete and deterministic`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ids = descriptors.map(\.id)

        #expect(!descriptors.isEmpty, "ProviderDescriptorRegistry must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderDescriptorRegistry contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing descriptors for providers: \(missing).")

        let secondPass = ProviderDescriptorRegistry.all.map(\.id)
        #expect(ids == secondPass, "ProviderDescriptorRegistry order changed between reads.")
    }

    @Test
    func `implementation registry is complete and deterministic`() {
        let implementations = ProviderImplementationRegistry.all
        let ids = implementations.map(\.id)

        #expect(!implementations.isEmpty, "ProviderImplementationRegistry must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderImplementationRegistry contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing implementations for providers: \(missing).")

        let secondPass = ProviderImplementationRegistry.all.map(\.id)
        #expect(ids == secondPass, "ProviderImplementationRegistry order changed between reads.")
    }
}
