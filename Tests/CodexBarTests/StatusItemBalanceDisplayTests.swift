import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemBalanceDisplayTests {
    @Test
    func `button title spacing only applies when image is present`() {
        #expect(StatusItemController.buttonTitle("42%", hasImage: true) == " 42%")
        #expect(StatusItemController.buttonTitle("42%", hasImage: false) == "42%")
        #expect(StatusItemController.buttonTitle(nil, hasImage: true).isEmpty)
        #expect(StatusItemController.buttonTitle("", hasImage: true).isEmpty)
    }
}
