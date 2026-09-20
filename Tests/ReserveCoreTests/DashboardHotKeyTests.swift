import Foundation
import Testing
@testable import ReserveCore

@Suite("Dashboard hot key")
struct DashboardHotKeyTests {
  @Test func offDoesNotRegister() {
    #expect(DashboardHotKeyMapping.carbonArguments(for: .off) == nil)
    #expect(DashboardHotKeyChoice.persisted(nil) == .off)
    #expect(DashboardHotKeyChoice.persisted("nope") == .off)
  }

  @Test func eachChoiceMapsToOneCarbonPair() {
    for choice in DashboardHotKeyChoice.allCases where choice != .off {
      let arguments = DashboardHotKeyMapping.carbonArguments(for: choice)
      #expect(arguments != nil)
      #expect(arguments?.keyCode == choice.carbonKeyCode)
      #expect(arguments?.modifiers == choice.carbonModifiers)
    }
  }

  @Test func registrationStatusDistinguishesConflictFromOtherFailures() {
    #expect(DashboardHotKeyRegistration.from(status: 0) == .registered)
    #expect(DashboardHotKeyRegistration.from(status: -9878) == .conflict)
    #expect(DashboardHotKeyRegistration.from(status: -50) == .failed(-50))
    #expect(DashboardHotKeyRegistration.conflict.statusText == "Already used by another app")
    #expect(DashboardHotKeyRegistration.failed(-50).statusText == "Could not register")
  }
}
