import Foundation
import Testing
@testable import ReserveCore

@Suite("Hide personal info")
struct PrivacyPresentationTests {
  @Test func maskingCopiesValuesAndRestoresOriginals() {
    let original = [
      UsageDetail("Account", "ada@example.com", isPersonal: true),
      UsageDetail("Organization", "Acme", isPersonal: true),
      UsageDetail("Credits", "5 left"),
    ]
    let hidden = PrivacyPresentation.details(original, hidingPersonal: true)
    #expect(hidden[0].value == "Hidden")
    #expect(hidden[1].value == "Hidden")
    #expect(hidden[2].value == "5 left")
    #expect(original[0].value == "ada@example.com")
    let shown = PrivacyPresentation.details(original, hidingPersonal: false)
    #expect(shown[0].value == "ada@example.com")
    #expect(shown[1].value == "Acme")
  }
}
