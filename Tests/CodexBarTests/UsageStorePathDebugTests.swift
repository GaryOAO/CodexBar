import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStorePathDebugTests {
    @Test
    func `refresh path debug info populates snapshot`() async {
        let settings = testSettingsStore(suiteName: "UsageStorePathDebugTests-path")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .full)

        let deadline = Date().addingTimeInterval(2)
        while store.pathDebugInfo == .empty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(store.pathDebugInfo != .empty)
        #expect(store.pathDebugInfo.effectivePATH.isEmpty == false)
    }
}
