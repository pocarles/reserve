import Foundation
import Security
import Testing
@testable import ReserveCore

@Suite("Refresh reliability policy")
struct RefreshReliabilityPolicyTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func keychainClassificationNeverTurnsAReadFailureIntoMissing() {
    #expect(KeychainAccessClassification.availability(for: errSecSuccess) == .present)
    #expect(KeychainAccessClassification.availability(for: errSecItemNotFound) == .missing)
    #expect(KeychainAccessClassification.availability(for: errSecInteractionNotAllowed) == .unavailable)
    #expect(KeychainAccessClassification.availability(for: errSecNotAvailable) == .unavailable)
  }

  @Test func manualRefreshCannotBypassExplicitRetryAfter() {
    var schedule = ProviderRefreshSchedule()
    let deadline = Self.now.addingTimeInterval(900)
    RefreshSchedulePolicy.recordFailure(
      &schedule, now: Self.now, failure: .rateLimited(until: deadline))

    let manual = RefreshSchedulePolicy.admit(
      state: schedule, trigger: .manual, now: Self.now.addingTimeInterval(60),
      interval: 600, discretionarySuppressed: false)
    let recovery = RefreshSchedulePolicy.admit(
      state: schedule, trigger: .connectionRecovery, now: Self.now.addingTimeInterval(60),
      interval: 600, discretionarySuppressed: false)
    #expect(manual == RefreshAdmission(allowed: false, reason: .retryAfter, nextEligibleAt: deadline))
    #expect(recovery.allowed == false)
  }

  @Test func missingRetryAfterUsesCappedExponentialBackoff() {
    var schedule = ProviderRefreshSchedule()
    var instant = Self.now
    var delays: [TimeInterval] = []
    for _ in 0..<8 {
      RefreshSchedulePolicy.recordFailure(
        &schedule, now: instant, failure: .rateLimited(until: nil))
      let deadline = schedule.retryAfterUntil ?? instant
      delays.append(deadline.timeIntervalSince(instant))
      instant = deadline
    }
    #expect(delays.prefix(5).elementsEqual([60, 120, 240, 480, 900]))
    #expect(delays.dropFirst(5).allSatisfy { $0 == RefreshSchedulePolicy.rateLimitFallbackCap })
  }

  @Test func healthyProviderRemainsFreshWhileFailedProviderBecomesDue() {
    var healthy = ProviderRefreshSchedule()
    var failed = ProviderRefreshSchedule()
    RefreshSchedulePolicy.recordSuccess(&healthy, now: Self.now, interval: 600)
    RefreshSchedulePolicy.recordFailure(&failed, now: Self.now, failure: .transient)
    let checkAt = Self.now.addingTimeInterval(31)

    #expect(RefreshSchedulePolicy.admit(
      state: healthy, trigger: .activation, now: checkAt, interval: 600,
      discretionarySuppressed: false).allowed == false)
    #expect(RefreshSchedulePolicy.admit(
      state: failed, trigger: .activation, now: checkAt, interval: 600,
      discretionarySuppressed: false).allowed)
  }

  @Test func discretionarySuppressionDoesNotBlockAnExplicitRequest() {
    let schedule = ProviderRefreshSchedule()
    #expect(RefreshSchedulePolicy.admit(
      state: schedule, trigger: .automatic, now: Self.now, interval: 600,
      discretionarySuppressed: true).reason == .suppressed)
    #expect(RefreshSchedulePolicy.admit(
      state: schedule, trigger: .manual, now: Self.now, interval: 600,
      discretionarySuppressed: true).allowed)
  }

  @Test func retryAfterParsesSecondsAndHTTPDateWithoutShorteningLongDeadlines() {
    #expect(HTTPRetryAfter.deadline(from: "90", now: Self.now)
      == Self.now.addingTimeInterval(90))
    let threeDays = Self.now.addingTimeInterval(3 * 86_400)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    #expect(HTTPRetryAfter.deadline(from: formatter.string(from: threeDays), now: Self.now)
      == threeDays)
    #expect(HTTPRetryAfter.deadline(from: "0", now: Self.now) == nil)
    #expect(HTTPRetryAfter.deadline(from: "not-a-date", now: Self.now) == nil)
  }

  @Test func consumptionClientCarriesRetryAfterIntoTheProviderError() async throws {
    let client = APIConsumptionClient(
      requestHandler: { request in
        (
          Data(),
          HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "180"])!
        )
      },
      now: { Self.now })
    do {
      _ = try await client.fetch(.deepSeek, apiKey: "fixture-key-never-sent")
      Issue.record("429 unexpectedly succeeded")
    } catch let UsageProviderError.rateLimited(retryAt) {
      #expect(retryAt == Self.now.addingTimeInterval(180))
    }
  }
}
