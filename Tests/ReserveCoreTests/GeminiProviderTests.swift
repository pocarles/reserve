import Foundation
import Testing
@testable import ReserveCore

/// Gemini plan limits read through `agy -p /usage --output-format json`.
///
/// `nativeReport` is what agy 1.2.6 printed on 2026-09-17, as recorded by
/// HarnessDesk (PR #769, `packages/server/test/usage/agy-meter.test.ts`),
/// with CodexBar's five-hour buckets (`AntigravityCLIUsageReportTests.swift`)
/// added so both windows are covered. No test here launches agy.
@Suite struct GeminiProviderTests {
  static let now = ISO8601DateFormatter().date(from: "2026-09-18T05:22:58Z")!

  static let nativeReport = #"""
    {
      "conversation_id": "",
      "status": "SUCCESS",
      "response": "Gemini Models\tWeekly Limit Remaining\t0%\t2026-09-24T00:02:21Z\n",
      "duration_seconds": 0,
      "num_turns": 0,
      "usage": {"input_tokens": 0, "output_tokens": 0, "thinking_tokens": 0,
        "cache_read_tokens": 0, "total_tokens": 0},
      "command": {
        "name": "usage",
        "data": {
          "description": "Within each group, models share a weekly limit.",
          "groups": [
            {
              "name": "Claude and GPT models",
              "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
              "buckets": [
                {"id": "3p-weekly", "name": "Weekly Limit Remaining", "window": "weekly",
                  "remaining_fraction": 1, "reset_time": "2026-09-25T05:22:58Z"},
                {"id": "3p-5h", "name": "Five Hour Limit Remaining", "window": "5h",
                  "remaining_fraction": 0.95, "reset_time": "2026-09-18T08:48:04Z"}
              ]
            },
            {
              "name": "Gemini Models",
              "description": "Models within this group: Gemini Flash, Gemini Pro",
              "buckets": [
                {"id": "gemini-weekly", "name": "Weekly Limit Remaining",
                  "description": "You have used some of your weekly limit.",
                  "window": "weekly", "remaining_fraction": 0.86,
                  "reset_time": "2026-09-24T00:02:21Z"},
                {"id": "gemini-5h", "name": "Five Hour Limit Remaining", "window": "5h",
                  "remaining_fraction": 0.25, "reset_time": "2026-09-18T07:30:00Z"}
              ]
            }
          ]
        }
      }
    }
    """#

  static func result(
    _ stdout: String, stderr: String = "", status: Int32 = 0, exceeded: Bool = false
  ) -> ProcessRunner.Result {
    ProcessRunner.Result(
      status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), stdoutExceeded: exceeded)
  }

  static func report(bucket: [String: Any], group: String = "Gemini Models") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "status": "SUCCESS",
      "command": ["name": "usage", "data": ["groups": [["name": group, "buckets": [bucket]]]]],
    ])
  }

  static func bucket(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = [
      "id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.5,
      "reset_time": "2026-09-24T00:02:21Z",
    ]
    value.merge(overrides) { _, replacement in replacement }
    return value
  }

  // MARK: Decoding

  @Test func nativeReportGivesWeeklyAndFiveHourMetersPerGroup() throws {
    let snapshot = try GeminiProvider.decode(Data(Self.nativeReport.utf8), now: Self.now)
    #expect(snapshot.provider == .gemini)
    // The Gemini group leads with the plan's own labels; the other group is
    // labelled as a model-scoped limit, like Claude's per-model limits.
    #expect(snapshot.windows.map(\.id) == ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
    #expect(snapshot.windows.map(\.label)
      == ["Weekly", "5 hours", "Claude and GPT weekly", "Claude and GPT · 5 hours"])
    #expect(snapshot.windows.map(\.windowMinutes) == [10_080, 300, 10_080, 300])
    let used = snapshot.windows.map { ($0.usedPercent * 1_000).rounded() / 1_000 }
    #expect(used == [14, 75, 0, 5])
    #expect(!snapshot.windows[0].isModelScoped && !snapshot.windows[1].isModelScoped)
    #expect(snapshot.windows[2].isModelScoped && snapshot.windows[3].isModelScoped)
    #expect(snapshot.windows[0].resetsAt == UsageDateParser.iso8601("2026-09-24T00:02:21Z"))
    #expect(snapshot.windows[1].resetsAt == UsageDateParser.iso8601("2026-09-18T07:30:00Z"))
    // An untouched bucket's reset is "now plus a week" and moves on every read.
    #expect(snapshot.windows[2].resetsAt == nil)
    #expect(snapshot.planName == nil)
    #expect(snapshot.detailedUsageUnavailable)
    #expect(snapshot.source == "Antigravity CLI usage report")
    #expect(snapshot.details.map(\.label) == ["Claude and GPT models", "Gemini Models"])
    #expect(snapshot.details.last?.value == "Gemini Flash, Gemini Pro")
    #expect(!snapshot.details.contains { $0.isPersonal })
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot)).windows
      == snapshot.windows)
  }

  @Test func camelCaseQuotaSummaryAndCommunitySnapshotAreRead() throws {
    // Google's retrieveUserQuotaSummary spelling (agy-cli-usage test/fixtures.ts).
    let summary = #"""
      {"groups": [{"displayName": "Gemini Models", "buckets": [
        {"bucketId": "gemini-weekly", "displayName": "Weekly Limit", "window": "weekly",
          "resetTime": "2026-09-24T03:53:09Z", "remainingFraction": 0.9164178},
        {"bucketId": "gemini-5h", "displayName": "Five Hour Limit", "window": "5h",
          "resetTime": "2026-09-18T07:32:07Z", "remainingFraction": 0.9436444}]}]}
      """#
    let fromSummary = try GeminiProvider.decode(Data(summary.utf8), now: Self.now)
    #expect(fromSummary.windows.map(\.label) == ["Weekly", "5 hours"])
    #expect(abs(fromSummary.windows[0].usedPercent - 8.35822) < 0.001)
    #expect(fromSummary.windows[1].resetsAt == UsageDateParser.iso8601("2026-09-18T07:32:07Z"))

    // The agy-cli-usage `--json` Snapshot: kind, resetAt, resetsInSeconds,
    // account and tier (README "JSON output — schema", src/types.ts).
    let community = #"""
      {"account": "person@example.com", "tier": "Google AI Pro", "source": "pty",
        "groups": [{"name": "Gemini Models", "models": "Gemini Flash, Gemini Pro", "buckets": [
          {"kind": "weekly", "label": "Weekly Limit", "remainingFraction": 0.9155,
            "resetAt": null, "resetsInSeconds": 263880, "available": false},
          {"kind": "5h", "label": "Five Hour Limit", "remainingFraction": 0.9383,
            "resetAt": "2026-09-18T07:19:58Z", "resetsInSeconds": 7020, "available": false}]}]}
      """#
    let fromCommunity = try GeminiProvider.decode(Data(community.utf8), now: Self.now)
    #expect(fromCommunity.planName == "Google AI Pro")
    #expect(fromCommunity.windows.map(\.windowMinutes) == [10_080, 300])
    #expect(fromCommunity.windows[0].resetsAt == Self.now.addingTimeInterval(263_880))
    #expect(fromCommunity.windows[1].resetsAt == UsageDateParser.iso8601("2026-09-18T07:19:58Z"))
    // The account is shown but never written to Reserve's cache.
    #expect(fromCommunity.details.first == UsageDetail("Account", "person@example.com", isPersonal: true))
    #expect(fromCommunity.details.first?.isPersonal == true)
    let cached = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(fromCommunity))
    #expect(!cached.details.contains { $0.label == "Account" })
  }

  @Test func remainingFractionEdgesAreClampedOrRefusedNeverGuessed() throws {
    func used(_ fraction: Any) throws -> Double? {
      try GeminiProvider.decode(
        Self.report(bucket: Self.bucket(["remaining_fraction": fraction])), now: Self.now
      ).windows.first?.usedPercent
    }
    #expect(try used(0) == 100)
    #expect(try used(1) == 0)
    #expect(try used(1.000_000_1) == 0)
    #expect(try used(-0.000_000_1) == 100)
    for invalid: Any in [1.5, -0.2, 42, "0.5", true] {
      #expect(throws: UsageProviderError.self) { try used(invalid) }
    }
    // Missing: nothing to draw, so no meter and no invented 0% or 100%.
    var missing = Self.bucket()
    missing.removeValue(forKey: "remaining_fraction")
    #expect(throws: UsageProviderError.unavailable(
      "Antigravity CLI reported no Gemini plan limits for this sign-in.")) {
      try GeminiProvider.decode(Self.report(bucket: missing), now: Self.now)
    }
    // A count with no total (`remaining_amount`) is not a fraction either.
    missing["remaining_amount"] = 40
    #expect(throws: UsageProviderError.self) {
      try GeminiProvider.decode(Self.report(bucket: missing), now: Self.now)
    }
    // Disabled buckets are not limits this account runs into.
    #expect(throws: UsageProviderError.self) {
      try GeminiProvider.decode(Self.report(bucket: Self.bucket(["disabled": true])), now: Self.now)
    }
    // Google's proto JSON wrapper around the fraction.
    let wrapped = try GeminiProvider.decode(Self.report(bucket: [
      "id": "w", "window": "weekly", "remaining": ["remainingFraction": 0.4],
    ]), now: Self.now)
    #expect(abs(wrapped.windows[0].usedPercent - 60) < 0.000_1)
  }

  @Test func resetsAreParsedAndPastOrFullWindowsHaveNone() throws {
    func reset(_ overrides: [String: Any]) throws -> Date? {
      try GeminiProvider.decode(Self.report(bucket: Self.bucket(overrides)), now: Self.now)
        .windows.first?.resetsAt
    }
    #expect(try reset(["reset_time": "2026-09-20T01:02:03.456Z"])
      == UsageDateParser.iso8601("2026-09-20T01:02:03.456Z"))
    #expect(try reset(["reset_time": "2026-09-01T00:00:00Z"]) == nil)
    #expect(try reset(["reset_time": "not a date"]) == nil)
    #expect(try reset(["reset_time": NSNull()]) == nil)
    #expect(try reset(["reset_time": NSNull(), "resets_in_seconds": 3_600])
      == Self.now.addingTimeInterval(3_600))
    #expect(try reset(["reset_time": NSNull(), "resets_in_seconds": -5]) == nil)
    #expect(try reset(["remaining_fraction": 1]) == nil)
    #expect(throws: UsageProviderError.self) { try reset(["reset_time": 12]) }
  }

  @Test func unknownWindowsKeepTheirNameWithoutInventingALength() throws {
    let snapshot = try GeminiProvider.decode(Self.report(
      bucket: ["id": "x", "window": "fortnightly", "remaining_fraction": 0.75],
      group: "Claude and GPT models"), now: Self.now)
    #expect(snapshot.windows[0].label == "Claude and GPT · Fortnightly")
    #expect(snapshot.windows[0].windowMinutes == nil)
    // Without a window or a name the bucket means nothing.
    #expect(throws: UsageProviderError.self) {
      try GeminiProvider.decode(Self.report(bucket: ["remaining_fraction": 0.5]), now: Self.now)
    }
  }

  @Test func unknownShapesAreInvalidResponses() {
    let unrecognized = UsageProviderError.invalidResponse("Antigravity CLI usage report was not recognized.")
    for json in [
      #"{}"#, #"[]"#, #"{"quota": 1}"#, #"{"groups": {}}"#, #"{"groups": [1]}"#,
      #"{"status": "SUCCESS", "command": {"name": "skills", "data": {"groups": []}}}"#,
      #"{"status": "SUCCESS", "command": {"name": "usage"}}"#,
      #"{"status": 1, "command": {"name": "usage", "data": {"groups": []}}}"#,
      #"{"groups": [{"name": "Gemini Models", "buckets": "none"}]}"#,
    ] {
      #expect(throws: unrecognized) { try GeminiProvider.decode(Data(json.utf8), now: Self.now) }
    }
    #expect(throws: UsageProviderError.self) {
      try GeminiProvider.decode(Data("not json".utf8), now: Self.now)
    }
  }

  @Test func anUnsuccessfulReportIsNotAReading() {
    let failed = #"{"status": "ERROR", "error": "internal", "command": {"name": "usage", "data": {"groups": []}}}"#
    #expect(throws: UsageProviderError.unavailable(
      "Antigravity CLI could not read your Gemini usage. Try again shortly.")) {
      try GeminiProvider.decode(Data(failed.utf8), now: Self.now)
    }
    #expect(throws: UsageProviderError.unavailable(
      "Antigravity CLI reported no Gemini plan limits for this sign-in.")) {
      try GeminiProvider.decode(
        Data(#"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[]}}}"#.utf8), now: Self.now)
    }
  }

  // MARK: Interpreting a run

  @Test func signedOutAndExpiredOutputOffersConnect() throws {
    // Google's headless docs and HarnessDesk's measurement on agy 1.2.6.
    let signedOut = Self.result(
      #"{"status": "ERROR", "error": "authentication failed or timed out"}"#,
      stderr: "Error: authentication required. Run 'agy' to log in.\n", status: 1)
    #expect(throws: UsageProviderError.credentialsNotFound(GeminiProvider.signInMessage)) {
      try GeminiProvider.interpret(signedOut, now: Self.now)
    }
    let notLoggedIn = Self.result("You are not logged into Antigravity.\n", status: 1)
    let error = #expect(throws: UsageProviderError.self) {
      try GeminiProvider.interpret(notLoggedIn, now: Self.now)
    }
    #expect(error?.requiresConnection == true)
    let expired = Self.result("", stderr: "stored credentials are expired or revoked", status: 1)
    #expect(throws: UsageProviderError.unauthorized(GeminiProvider.signInMessage)) {
      try GeminiProvider.interpret(expired, now: Self.now)
    }
    // A failure that only mentions authentication is not a sign-out.
    let ambiguous = Self.result(#"{"status": "ERROR", "error": "authentication failed or timed out"}"#, status: 1)
    let ambiguousError = #expect(throws: UsageProviderError.self) {
      try GeminiProvider.interpret(ambiguous, now: Self.now)
    }
    #expect(ambiguousError?.requiresConnection == false)
  }

  @Test func interpretToleratesANoticeBeforeTheJSONAndRejectsOversizeOrGarbage() throws {
    let snapshot = try GeminiProvider.interpret(
      Self.result("Update available: 1.2.7\n" + Self.nativeReport), now: Self.now)
    #expect(snapshot.windows.count == 4)
    #expect(throws: UsageProviderError.self) {
      try GeminiProvider.interpret(Self.result(Self.nativeReport, exceeded: true), now: Self.now)
    }
    #expect(throws: UsageProviderError.processFailed("Antigravity CLI exited with status 2.")) {
      try GeminiProvider.interpret(Self.result("crashed", status: 2), now: Self.now)
    }
    #expect(throws: UsageProviderError.invalidResponse("Antigravity CLI usage report was not recognized.")) {
      try GeminiProvider.interpret(Self.result("Gemini Models\tWeekly\t0%"), now: Self.now)
    }
  }

  // MARK: Running agy

  actor Calls {
    var arguments: [[String]] = []
    var environments: [[String: String]] = []
    func record(_ arguments: [String], _ environment: [String: String]) {
      self.arguments.append(arguments)
      self.environments.append(environment)
    }
  }

  static func provider(
    version: String,
    usage: @escaping @Sendable () throws -> ProcessRunner.Result = {
      GeminiProviderTests.result(GeminiProviderTests.nativeReport)
    },
    calls: Calls, environment: [String: String] = ["HOME": "/Users/test", "PATH": "/usr/bin"]
  ) -> GeminiProvider {
    GeminiProvider(
      environment: environment, locator: { _ in "/Users/test/.local/bin/agy" },
      runner: { executable, arguments, environment, _ in
        #expect(executable == "/Users/test/.local/bin/agy")
        await calls.record(arguments, environment)
        if arguments == ["--version"] { return result(version) }
        return try usage()
      },
      now: { now })
  }

  @Test func runsOnlyTheVersionAndUsageCommandsWithAnAllowlistedEnvironment() async throws {
    let calls = Calls()
    let snapshot = try await Self.provider(
      version: "1.1.11\n", calls: calls,
      environment: ["HOME": "/Users/test", "PATH": "/usr/bin", "GEMINI_API_KEY": "secret",
        "OPENAI_API_KEY": "secret", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
    ).fetch()
    #expect(snapshot.windows.count == 4)
    #expect(await calls.arguments == [["--version"], ["-p", "/usage", "--output-format", "json"]])
    for environment in await calls.environments {
      #expect(environment["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
      #expect(environment["GEMINI_API_KEY"] == nil && environment["OPENAI_API_KEY"] == nil)
      #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
      #expect(environment["HOME"] == "/Users/test")
    }
  }

  @Test func logFileIsSentToTheNullDeviceOnlyWhereItIsConfirmed() async throws {
    let calls = Calls()
    _ = try await Self.provider(version: "agy 1.2.6", calls: calls).fetch()
    #expect(await calls.arguments.last
      == ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null"])
  }

  @Test func anOldOrUnidentifiedAgyIsNeverAskedForUsage() async throws {
    // Before 1.1.11, `-p /usage` could be sent to the model and spend quota.
    let old = Calls()
    await #expect(throws: UsageProviderError.updateRequired(
      "Update Antigravity CLI to 1.1.11 or later to show Gemini usage.")) {
      try await Self.provider(version: "1.1.10", calls: old).fetch()
    }
    #expect(await old.arguments == [["--version"]])
    let unknown = Calls()
    await #expect(throws: UsageProviderError.self) {
      try await Self.provider(version: "development build", calls: unknown).fetch()
    }
    #expect(await unknown.arguments == [["--version"]])
  }

  @Test func missingHelperAndTimeoutAreReportedPlainly() async throws {
    let missing = GeminiProvider(
      environment: [:], locator: { _ in nil },
      runner: { _, _, _, _ in Issue.record("agy was run"); return Self.result("") })
    await #expect(throws: UsageProviderError.executableNotFound("Antigravity CLI")) {
      try await missing.fetch()
    }
    let calls = Calls()
    await #expect(throws: UsageProviderError.timedOut("Antigravity CLI usage check")) {
      try await Self.provider(version: "1.2.6", usage: { throw UsageProviderError.timedOut("agy") },
        calls: calls).fetch()
    }
  }

  @Test func descriptorRunsAgyAndNeverStartsItToSignInOrUpdate() {
    let descriptor = ProviderDescriptor.forProvider(.gemini)
    #expect(ProviderID.gemini.displayName == "Gemini")
    #expect(descriptor.helper?.executable == "agy")
    #expect(descriptor.helper?.installerURL.absoluteString == "https://antigravity.google/cli/install.sh")
    #expect(descriptor.supportsAutomaticHelperInstallation)
    #expect(!descriptor.supportsAutomaticHelperUpdate)
    #expect(descriptor.helper?.updateArguments.isEmpty == true)
    #expect(descriptor.signsInFromTerminal)
    #expect(descriptor.loginArguments.isEmpty && descriptor.trustedLoginHosts.isEmpty)
    #expect(descriptor.statusURL == nil && descriptor.statusFeedURL == nil)
    #expect(descriptor.capabilities == [.liveAllowance, .limitMeters])
    #expect(!descriptor.usesAPIKey)
    // Every other helper keeps its own sign-in command.
    for provider in ProviderID.allCases where provider != .gemini {
      #expect(!ProviderDescriptor.forProvider(provider).signsInFromTerminal)
    }
  }

  @Test func realRunnerCapturesStatusAndBoundedStderrWithoutAShell() async throws {
    let result = try await ProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; pwd; exit 3"],
      environment: ["PATH": "/usr/bin:/bin"], standardInput: FileHandle.nullDevice,
      currentDirectory: URL(fileURLWithPath: "/tmp"), timeout: .seconds(5),
      maximumStdoutBytes: 1_024, maximumStderrBytes: 1_024)
    #expect(result.status == 3)
    #expect(String(decoding: result.stdout, as: UTF8.self).contains("out"))
    #expect(String(decoding: result.stdout, as: UTF8.self).contains("/tmp"))
    #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    #expect(!result.stdoutExceeded)
  }
}
