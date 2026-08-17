import Foundation
import Testing
@testable import ReserveCore

private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
  #expect(lhs == rhs)
}

private func XCTAssertTrue(_ value: Bool) { #expect(value) }
private func XCTAssertFalse(_ value: Bool) { #expect(!value) }
private func XCTAssertNil<T>(_ value: T?) { #expect(value == nil) }
private func XCTAssertGreaterThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T) {
  #expect(lhs >= rhs)
}
private func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T) {
  #expect(lhs <= rhs)
}
private func XCTAssertLessThan<T: Comparable>(_ lhs: T, _ rhs: T) {
  #expect(lhs < rhs)
}
private struct TestFailure: Error, CustomStringConvertible {
  let description: String
}
private func XCTFail(_ message: String) { Issue.record(TestFailure(description: message)) }

private func cleanTestDefaults(_ defaults: UserDefaults, suiteName: String) {
  defaults.removePersistentDomain(forName: suiteName)
  let plist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences/\(suiteName).plist")
  try? FileManager.default.removeItem(at: plist)
}

private func freshTestDefaults(suiteName: String) -> UserDefaults {
  let defaults = UserDefaults(suiteName: suiteName)!
  cleanTestDefaults(defaults, suiteName: suiteName)
  return defaults
}

private func cleanTestDefaults(suiteName: String) {
  guard let defaults = UserDefaults(suiteName: suiteName) else { return }
  cleanTestDefaults(defaults, suiteName: suiteName)
}

@Suite
struct ReserveCoreTests {
  @Test
  func testGrokUnifiedWeeklyResetIgnoresMonthlyIncludedSpend() throws {
    let data = Data(
      #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-15T22:03:41Z","end":"2026-08-22T22:03:41Z"},"monthlyLimit":{"val":99900},"used":{"val":12345},"isUnifiedBillingUser":true}}"#.utf8)
    let billing = try JSONDecoder().decode(GrokBillingEnvelope.self, from: data)

    XCTAssertEqual(billing.config?.usedPercent, 0)
    XCTAssertEqual(billing.config?.includedSpend?.usedMinorUnits, 12_345)
    XCTAssertEqual(billing.config?.includedSpend?.limitMinorUnits, 99_900)
  }

  @Test
  func testDeficitAlertRequiresAPreviousSnapshot() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let current = UsageSnapshot(
      provider: .openAI,
      windows: [
        UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 80,
          windowMinutes: 7 * 24 * 60, resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60))
      ],
      source: "test")

    XCTAssertTrue(
      SmartAlertDetector.deficitAlerts(previous: nil, current: current, now: now).isEmpty)
  }

  @Test
  func testGrokCredentialSelectionBreaksPreferenceTiesByAccountKey() {
    let future = "2033-05-18T03:33:20Z"
    let credentials = GrokCredentialLoader.select(
      entries: [
        "zeta": GrokCredentialEntry(key: "zeta-key", userID: "zeta-user", expiresAt: future),
        "alpha": GrokCredentialEntry(
          key: "alpha-key", userID: "alpha-user", expiresAt: future),
      ],
      now: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertEqual(credentials?.key, "alpha-key")
    XCTAssertEqual(credentials?.userID, "alpha-user")
  }

  @Test
  func testClaudeCredentialDecoderRejectsExpiredLegacyFile() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = Data(
      #"{"claudeAiOauth":{"accessToken":"old-token","expiresAt":1799999999000}}"#.utf8)

    do {
      _ = try ClaudeCredentialLoader.decode(data: expired, source: "legacy file", now: now)
      XCTFail("expired Claude credential was accepted")
    } catch UsageProviderError.credentialsNotFound {
      // Expected: Reserve can continue to Claude's current protected sign-in.
    }

    let current = Data(
      #"{"claudeAiOauth":{"accessToken":"current-token","expiresAt":1900000000000}}"#.utf8)
    let decoded = try ClaudeCredentialLoader.decode(
      data: current, source: "current file", now: now)
    XCTAssertEqual(decoded.source, "current file")
  }

  @Test
  func testLegacyMigrationCleanInstallStartsWithEmptyReserveState() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let newSuite = "ReserveCoreTests.Clean"
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer { cleanTestDefaults(newDefaults, suiteName: newSuite) }

    let report = LegacyStateMigrator.migrate(
      oldDefaults: nil,
      newDefaults: newDefaults,
      oldDirectory: root.url.appendingPathComponent("MissingUsageBar"),
      newDirectory: root.url.appendingPathComponent("Reserve"))

    XCTAssertEqual(report.migratedPreferenceCount, 0)
    XCTAssertTrue(report.migratedCacheFiles.isEmpty)
    XCTAssertFalse(report.cacheMigrationFailed)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.url.appendingPathComponent("Reserve").path))
    XCTAssertTrue(newDefaults.bool(forKey: LegacyStateMigrator.completionKey))
  }

  @Test
  func testLegacyMigrationRejectsUnsupportedRefreshInterval() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let oldSuite = "ReserveCoreTests.UnsupportedInterval.Old"
    let newSuite = "ReserveCoreTests.UnsupportedInterval.New"
    let oldDefaults = freshTestDefaults(suiteName: oldSuite)
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer {
      cleanTestDefaults(oldDefaults, suiteName: oldSuite)
      cleanTestDefaults(newDefaults, suiteName: newSuite)
    }
    oldDefaults.set(45, forKey: "refresh.intervalMinutes")

    let report = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: root.url.appendingPathComponent("UsageBar"),
      newDirectory: root.url.appendingPathComponent("Reserve"))

    XCTAssertEqual(report.migratedPreferenceCount, 0)
    XCTAssertNil(newDefaults.object(forKey: "refresh.intervalMinutes"))
  }

  @Test
  func testTokenAggregationSaturatesInsteadOfTrapping() {
    let summary = LocalUsageSummary(
      provider: .anthropic, periodDays: 30,
      inputTokens: .max, cachedInputTokens: .max,
      cacheWriteInputTokens: .max, outputTokens: .max,
      apiEquivalentCostUSD: 0)
    XCTAssertEqual(summary.totalTokens, .max)

    let grok = LocalUsageScanner.parseGrokSignal(
      Data(#"{"totalTokensBeforeCompaction":9223372036854775807,"contextTokensUsed":9223372036854775807}"#.utf8))
    XCTAssertEqual(grok?.input, .max)
  }

  @Test
  func testUsageWindowBoundsProviderControlledTextAndCount() {
    let window = UsageWindow(
      id: String(repeating: "x", count: 5_000),
      label: String(repeating: "y", count: 5_000), usedPercent: .infinity,
      windowMinutes: .max, resetsAt: Date().addingTimeInterval(3_600))
    XCTAssertEqual(window.id.count, UsageWindow.maximumIdentifierCharacters)
    XCTAssertEqual(window.label.count, UsageWindow.maximumLabelCharacters)
    XCTAssertEqual(window.usedPercent, 0)
    XCTAssertNil(window.windowMinutes)
    XCTAssertNil(UsagePaceProjection.calculate(for: window))
    let extremeReset = UsageWindow(
      id: "extreme", label: "Extreme", usedPercent: 99,
      windowMinutes: 60,
      resetsAt: Date(timeIntervalSince1970: TimeInterval(Int.max)))
    XCTAssertNil(extremeReset.resetsAt)
    let snapshot = UsageSnapshot(
      provider: .openAI,
      windows: Array(repeating: window, count: 100), source: "test")
    XCTAssertEqual(snapshot.windows.count, UsageSnapshot.maximumWindows)
  }

  @Test
  func testBoundedLineBufferPreservesUnconsumedRecordsForNextScan() {
    let buffer = BoundedLineBuffer(maximumBytes: 64)
    let first = buffer.append(Data("one\ntwo\nthree\n".utf8), maximumLines: 2)
    XCTAssertEqual(first.lines.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
    XCTAssertEqual(first.consumedBytes, 8)
    let second = buffer.append(Data(), maximumLines: 2)
    XCTAssertEqual(second.lines.map { String(decoding: $0, as: UTF8.self) }, ["three"])
    XCTAssertEqual(second.consumedBytes, 6)
  }

  @Test
  func testBoundedLineBufferSkipsOversizedRecordAndResumesAtNextLine() {
    let buffer = BoundedLineBuffer(maximumBytes: 8)
    let oversized = buffer.append(Data("123456789".utf8))
    let recovered = buffer.append(Data("tail\nok\n".utf8))

    XCTAssertTrue(oversized.exceeded)
    XCTAssertEqual(oversized.consumedBytes, 9)
    XCTAssertTrue(recovered.exceeded)
    XCTAssertEqual(recovered.lines.map { String(decoding: $0, as: UTF8.self) }, ["ok"])
    XCTAssertEqual(recovered.consumedBytes, 8)
  }

  @Test
  func testNotificationComponentsAreFixedLengthAndDeterministic() {
    let value = String(repeating: "provider-controlled/", count: 100_000)
    let first = StableIdentifier.notificationComponent(value)
    let second = StableIdentifier.notificationComponent(value)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, 32)
    XCTAssertTrue(first.allSatisfy(\.isHexDigit))
  }

  @Test
  func testBoundedOutputGateCoalescesAndRejectsOverflow() {
    let gate = BoundedOutputGate(maximumBytes: 8)
    XCTAssertEqual(gate.append(Data("abc".utf8)), .scheduleDrain)
    XCTAssertEqual(gate.append(Data("de".utf8)), .accepted)
    XCTAssertEqual(String(decoding: gate.drain(), as: UTF8.self), "abcde")
    XCTAssertEqual(gate.append(Data("fgh".utf8)), .scheduleDrain)
    XCTAssertEqual(gate.append(Data("i".utf8)), .overflow)
    XCTAssertEqual(gate.append(Data("j".utf8)), .closed)
  }

  @Test
  func testRetryAfterIsFiniteAndCapped() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    for value in ["nan", "inf", "1e309", "999999999999999999999"] {
      let retry = AnthropicProvider.conservativeRetryDate(retryAfter: value, now: now)
      XCTAssertGreaterThanOrEqual(retry, now.addingTimeInterval(15 * 60))
      XCTAssertLessThanOrEqual(
        retry, now.addingTimeInterval(AnthropicProvider.maximumRetryDelay))
    }
    let farDate = "Sun, 01 Jan 2090 00:00:00 GMT"
    XCTAssertEqual(
      AnthropicProvider.conservativeRetryDate(retryAfter: farDate, now: now),
      now.addingTimeInterval(AnthropicProvider.maximumRetryDelay))

    let suite = "ReserveCoreTests.RateLimit"
    let defaults = freshTestDefaults(suiteName: suite)
    defaults.set(Date.distantFuture, forKey: "anthropic.rateLimitBlockedUntil")
    let gate = ClaudeRateLimitGate(defaults: defaults)
    XCTAssertNil(await gate.activeBlock(now: now))
    cleanTestDefaults(suiteName: suite)
  }

  @Test
  func testOversizedSessionLineIsSkippedWithoutLosingProviderUsage() async throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let codex = root.url.appendingPathComponent("codex")
    let claude = root.url.appendingPathComponent("claude")
    let grok = root.url.appendingPathComponent("grok")
    for directory in [codex, claude, grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    let codexLines =
      [
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":1020}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(codexLines.utf8).write(to: codex.appendingPathComponent("session.jsonl"))
    let claudeLine =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5}}}"#
    var claudeData = Data(repeating: 0x41, count: 1_048_577)
    claudeData.append(Data(("\n" + claudeLine + "\n").utf8))
    try claudeData.write(to: claude.appendingPathComponent("session.jsonl"))
    let scanner = LocalUsageScanner(
      roots: .init(codex: codex, claude: claude, grok: grok),
      cacheURL: root.url.appendingPathComponent("index.json"))
    let usage = try await scanner.scan(now: now)
    let repeatedUsage = try await scanner.scan(now: now)

    XCTAssertEqual(usage[.openAI]?.totalTokens, 1_020)
    XCTAssertEqual(usage[.anthropic]?.totalTokens, 135)
    XCTAssertEqual(repeatedUsage, usage)
  }

  @Test
  func testOversizedUnterminatedSessionLineIsSkippedWithinBudget() async throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let codex = root.url.appendingPathComponent("codex")
    let claude = root.url.appendingPathComponent("claude")
    let grok = root.url.appendingPathComponent("grok")
    for directory in [codex, claude, grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let session = claude.appendingPathComponent("session.jsonl")
    try Data(repeating: 0x41, count: 1_048_577).write(to: session)
    let scanner = LocalUsageScanner(
      roots: .init(codex: codex, claude: claude, grok: grok),
      cacheURL: root.url.appendingPathComponent("index.json"))

    let now = Date()
    let first = try await scanner.scan(now: now)
    let timestamp = ISO8601DateFormatter().string(from: now)
    let continuedOversizedRecord =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"discard-r","message":{"id":"discard-m","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1000}}}"#
    let healthyRecord =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"keep-r","message":{"id":"keep-m","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5}}}"#
    let handle = try FileHandle(forWritingTo: session)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((continuedOversizedRecord + "\n" + healthyRecord + "\n").utf8))
    try handle.close()
    let second = try await scanner.scan(now: now)

    XCTAssertEqual(first[.anthropic]?.totalTokens, 0)
    XCTAssertEqual(second[.anthropic]?.totalTokens, 135)
  }

  @Test
  func testSessionEnumerationDoesNotDiscardFilesLargerThanReadBudget() async throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let sessions = root.url.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let large = sessions.appendingPathComponent("large.jsonl")
    FileManager.default.createFile(atPath: large.path, contents: Data())
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(65 * 1_024 * 1_024))
    try handle.close()
    let small = sessions.appendingPathComponent("small.jsonl")
    try Data("{}\n".utf8).write(to: small)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: large.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: small.path)

    let scanner = LocalUsageScanner(
      roots: .init(codex: sessions, claude: sessions, grok: sessions),
      cacheURL: root.url.appendingPathComponent("index.json"))
    let files = try await scanner.recentFiles(
      root: sessions, named: nil, extension: "jsonl",
      cutoff: Date().addingTimeInterval(-3_600), deadline: Date().addingTimeInterval(2))

    XCTAssertEqual(files.count, 2)
    XCTAssertEqual(files.first?.lastPathComponent, "small.jsonl")
    XCTAssertTrue(files.map(\.lastPathComponent).contains("large.jsonl"))
  }

  @Test
  func testJSONRPCQueueOverflowTerminatesSession() async throws {
    let script = #"read line; i=0; while [ $i -lt 80 ]; do printf '{"id":999,"result":{}}\n'; i=$((i+1)); done"#
    let rpc = try JSONRPCProcess(
      executable: "/bin/sh", arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment)
    defer { rpc.shutdown() }
    do {
      _ = try await rpc.request(method: "test", timeout: .seconds(2))
      XCTFail("overflowing response queue should terminate")
    } catch {
      XCTAssertTrue(error is UsageProviderError)
    }
  }

  @Test
  func testProcessRunnerDeadlineIncludesInheritedPipeDrain() async {
    let start = ContinuousClock.now
    do {
      _ = try await ProcessRunner.output(
        executable: "/bin/sh",
        arguments: ["-c", "(sleep 5) & exit 0"],
        environment: ProcessInfo.processInfo.environment,
        timeout: .milliseconds(200))
      XCTFail("descendant-held pipe should hit the deadline")
    } catch let error as UsageProviderError {
      guard case .timedOut = error else { return XCTFail("unexpected error: \(error)") }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }

  @Test
  func testBoundedHTTPReceptionRejectsOversizedBody() async throws {
    MockURLProtocol.body = Data(repeating: 0x41, count: 1_025)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    do {
      _ = try await ProviderHTTPSession.boundedData(
        for: URLRequest(url: URL(string: "https://example.test/body")!),
        using: session, maximumBytes: 1_024)
      XCTFail("oversized body should be rejected during reception")
    } catch let error as UsageProviderError {
      guard case .invalidResponse = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  @Test
  func testLegacyMigrationIsAllowListedValidatedAndIdempotent() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let oldSuite = "ReserveCoreTests.AllowListedMigration.Old"
    let newSuite = "ReserveCoreTests.AllowListedMigration.New"
    let oldDefaults = freshTestDefaults(suiteName: oldSuite)
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer {
      cleanTestDefaults(oldDefaults, suiteName: oldSuite)
      cleanTestDefaults(newDefaults, suiteName: newSuite)
    }
    oldDefaults.set(false, forKey: "provider.grok.enabled")
    oldDefaults.set(15, forKey: "refresh.intervalMinutes")
    oldDefaults.set("do-not-copy", forKey: "credential.secret")
    let oldDirectory = root.url.appendingPathComponent("UsageBar")
    let newDirectory = root.url.appendingPathComponent("Reserve")
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    let snapshot = UsageSnapshot(
      provider: .openAI,
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)],
      source: "test")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([snapshot]).write(
      to: oldDirectory.appendingPathComponent("snapshots.json"))
    try Data(#"{"version":1,"records":{}}"#.utf8).write(
      to: oldDirectory.appendingPathComponent("local-usage-index.json"))
    try Data("secret".utf8).write(to: oldDirectory.appendingPathComponent("credentials.json"))

    let report = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertEqual(report.migratedPreferenceCount, 2)
    XCTAssertEqual(
      report.migratedCacheFiles, ["local-usage-index.json", "snapshots.json"])
    XCTAssertFalse(report.cacheMigrationFailed)
    XCTAssertFalse(newDefaults.bool(forKey: "provider.grok.enabled"))
    XCTAssertEqual(newDefaults.integer(forKey: "refresh.intervalMinutes"), 15)
    XCTAssertNil(newDefaults.object(forKey: "credential.secret"))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: newDirectory.appendingPathComponent("credentials.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: oldDirectory.appendingPathComponent("snapshots.json").path))
    let attributes = try FileManager.default.attributesOfItem(atPath: newDirectory.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

    let second = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertTrue(second.wasAlreadyCompleted)
    XCTAssertTrue(second.migratedCacheFiles.isEmpty)
  }

  @Test
  func testLegacyMigrationDoesNotPartiallyPublishInvalidCachesOrOverwriteNewData() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let oldSuite = "ReserveCoreTests.InvalidCacheMigration.Old"
    let newSuite = "ReserveCoreTests.InvalidCacheMigration.New"
    let oldDefaults = freshTestDefaults(suiteName: oldSuite)
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer {
      cleanTestDefaults(oldDefaults, suiteName: oldSuite)
      cleanTestDefaults(newDefaults, suiteName: newSuite)
    }
    let oldDirectory = root.url.appendingPathComponent("UsageBar")
    let newDirectory = root.url.appendingPathComponent("Reserve")
    oldDefaults.set(false, forKey: "provider.grok.enabled")
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: oldDirectory.appendingPathComponent("snapshots.json"))
    try Data("invalid".utf8).write(
      to: oldDirectory.appendingPathComponent("local-usage-index.json"))
    let existing = newDirectory.appendingPathComponent("snapshots.json")
    try Data("new-state".utf8).write(to: existing)

    let report = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertTrue(report.cacheMigrationFailed)
    XCTAssertEqual(report.migratedPreferenceCount, 0)
    XCTAssertTrue(report.migratedCacheFiles.isEmpty)
    XCTAssertNil(newDefaults.object(forKey: "provider.grok.enabled"))
    XCTAssertFalse(newDefaults.bool(forKey: LegacyStateMigrator.completionKey))
    XCTAssertEqual(try Data(contentsOf: existing), Data("new-state".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: newDirectory.appendingPathComponent("local-usage-index.json").path))

    try Data(#"{"version":1,"records":{}}"#.utf8).write(
      to: oldDirectory.appendingPathComponent("local-usage-index.json"))
    let recovered = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertFalse(recovered.cacheMigrationFailed)
    XCTAssertEqual(recovered.migratedPreferenceCount, 1)
    XCTAssertTrue(newDefaults.bool(forKey: LegacyStateMigrator.completionKey))
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var body = Data()

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    self.client?.urlProtocol(self, didLoad: Self.body)
    self.client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class TemporaryRoot {
  let url: URL

  init() throws {
    self.url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReserveCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: self.url)
  }
}
