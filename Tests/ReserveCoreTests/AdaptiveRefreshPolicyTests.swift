import Foundation
import Testing
@testable import ReserveCore

@Suite("Adaptive refresh policy")
struct AdaptiveRefreshPolicyTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func constrainedAlwaysWaitsThirtyMinutes() {
    let decision = AdaptiveRefreshPolicy.decision(
      now: now, lastDashboardOpenAt: now, constrained: true)
    #expect(decision == AdaptiveRefreshDecision(minutes: 30, reason: .constrained))
    #expect(AdaptiveRefreshPolicy.minutes(now: now, lastDashboardOpenAt: nil, constrained: true) == 30)
  }

  @Test func constrainedBeatsAJustOpenedDashboard() {
    let opened = now.addingTimeInterval(-60)
    let decision = AdaptiveRefreshPolicy.decision(
      now: now, lastDashboardOpenAt: opened, constrained: true)
    #expect(decision.minutes == 30)
    #expect(decision.reason == .constrained)
  }

  @Test func nilDashboardOpenWaitsThirtyMinutes() {
    let decision = AdaptiveRefreshPolicy.decision(
      now: now, lastDashboardOpenAt: nil, constrained: false)
    #expect(decision == AdaptiveRefreshDecision(minutes: 30, reason: .dashboardDormant))
  }

  @Test func futureDashboardOpenCountsAsRecent() {
    let opened = now.addingTimeInterval(120)
    let decision = AdaptiveRefreshPolicy.decision(
      now: now, lastDashboardOpenAt: opened, constrained: false)
    #expect(decision == AdaptiveRefreshDecision(minutes: 2, reason: .dashboardRecent))
  }

  @Test func boundariesSelectTheDocumentedCadence() {
    let cases: [(TimeInterval, AdaptiveRefreshDecision)] = [
      (0, AdaptiveRefreshDecision(minutes: 2, reason: .dashboardRecent)),
      (5 * 60, AdaptiveRefreshDecision(minutes: 2, reason: .dashboardRecent)),
      (5 * 60 + 1, AdaptiveRefreshDecision(minutes: 5, reason: .dashboardWithinHour)),
      (60 * 60, AdaptiveRefreshDecision(minutes: 5, reason: .dashboardWithinHour)),
      (60 * 60 + 1, AdaptiveRefreshDecision(minutes: 15, reason: .dashboardWithinFourHours)),
      (4 * 60 * 60 - 1, AdaptiveRefreshDecision(minutes: 15, reason: .dashboardWithinFourHours)),
      (4 * 60 * 60, AdaptiveRefreshDecision(minutes: 30, reason: .dashboardDormant)),
      (4 * 60 * 60 + 1, AdaptiveRefreshDecision(minutes: 30, reason: .dashboardDormant)),
    ]
    for (age, expected) in cases {
      let opened = now.addingTimeInterval(-age)
      let decision = AdaptiveRefreshPolicy.decision(
        now: now, lastDashboardOpenAt: opened, constrained: false)
      #expect(decision == expected)
      #expect(decision.minutes >= AdaptiveRefreshPolicy.minimumMinutes)
      #expect(decision.minutes <= AdaptiveRefreshPolicy.maximumMinutes)
    }
  }

  @Test func everyResultStaysInsideTwoToThirtyMinutes() {
    let ages: [TimeInterval?] = [nil, -10_000, 0, 1, 299, 300, 301, 3_600, 3_601, 14_399, 14_400, 86_400]
    for constrained in [false, true] {
      for age in ages {
        let opened = age.map { now.addingTimeInterval(-$0) }
        let minutes = AdaptiveRefreshPolicy.minutes(
          now: now, lastDashboardOpenAt: opened, constrained: constrained)
        #expect(minutes >= 2)
        #expect(minutes <= 30)
      }
    }
  }
}
