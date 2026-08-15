import Foundation

public enum UsageBarSelfTests {
  public static func run(
    openAIData: Data,
    anthropicData: Data,
    grokData: Data,
    helperExecutable: String? = nil
  ) async throws -> [String] {
    var passed: [String] = []

    guard UsageWindow(id: "low", label: "Low", usedPercent: -2).usedPercent == 0,
      UsageWindow(id: "high", label: "High", usedPercent: 103).usedPercent == 100
    else { throw Failure("usage percentage clamping") }
    passed.append("usage percentage clamping")

    let paceNow = Date(timeIntervalSince1970: 1_900_000_000)
    let paceReset = paceNow.addingTimeInterval(6 * 24 * 60 * 60)
    let deficitPace = UsagePaceProjection.calculate(
      for: UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: 20,
        windowMinutes: 7 * 24 * 60, resetsAt: paceReset),
      now: paceNow)
    let reservePace = UsagePaceProjection.calculate(
      for: UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: 10,
        windowMinutes: 7 * 24 * 60, resetsAt: paceReset),
      now: paceNow)
    let onPace = UsagePaceProjection.calculate(
      for: UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: 14.5,
        windowMinutes: 7 * 24 * 60, resetsAt: paceReset),
      now: paceNow)
    let elapsedPercent = 100.0 / 7.0
    let justInsideTolerance = UsagePaceProjection.calculate(
      for: UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: elapsedPercent + 1.9,
        windowMinutes: 7 * 24 * 60, resetsAt: paceReset), now: paceNow)
    let justOutsideDeficit = UsagePaceProjection.calculate(
      for: UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: elapsedPercent + 2.1,
        windowMinutes: 7 * 24 * 60, resetsAt: paceReset), now: paceNow)
    let justOutsideReserve = UsagePaceProjection.calculate(
      for: UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: elapsedPercent - 2.1,
        windowMinutes: 7 * 24 * 60, resetsAt: paceReset), now: paceNow)
    guard deficitPace?.position == .deficit,
      abs((deficitPace?.variancePercent ?? 0) - 5.714) < 0.01,
      deficitPace?.projectedExhaustionAt == paceNow.addingTimeInterval(4 * 24 * 60 * 60),
      reservePace?.position == .reserve,
      abs((reservePace?.projectedRemainingPercent ?? 0) - 30) < 0.01,
      onPace?.position == .onPace,
      justInsideTolerance?.position == .onPace,
      justOutsideDeficit?.position == .deficit,
      justOutsideReserve?.position == .reserve,
      UsagePaceProjection.onPaceTolerancePercent == 2,
      UsagePaceState.calculate(
        for: UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 20,
          windowMinutes: 7 * 24 * 60, resetsAt: paceReset),
        fetchedAt: paceNow, now: paceNow) == .deficit(percent: deficitPace!.variancePercent),
      UsagePaceState.calculate(
        for: UsageWindow(id: "weekly", label: "Weekly", usedPercent: 100),
        fetchedAt: paceNow, now: paceNow) == .exhausted,
      UsagePaceState.calculate(
        for: UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20),
        fetchedAt: paceNow.addingTimeInterval(-31 * 60), now: paceNow) == .stale,
      UsagePaceProjection.calculate(
        for: UsageWindow(
          id: "expired", label: "Weekly", usedPercent: 20,
          windowMinutes: 7 * 24 * 60, resetsAt: paceNow), now: paceNow) == nil
    else { throw Failure("usage pace projection") }
    passed.append("usage pace projection")

    // Smart alerts fire on the transition into deficit, not on every refresh.
    let riskReset = paceNow.addingTimeInterval(2 * 24 * 60 * 60)
    func weekly(_ used: Double) -> UsageSnapshot {
      UsageSnapshot(
        provider: .openAI,
        windows: [
          UsageWindow(
            id: "weekly", label: "Weekly", usedPercent: used,
            windowMinutes: 7 * 24 * 60, resetsAt: riskReset),
          UsageWindow(
            id: "build-share", label: "Build share", usedPercent: used,
            windowMinutes: 7 * 24 * 60, resetsAt: riskReset),
        ],
        source: "self-test")
    }
    let safeSnapshot = weekly(5)
    let riskySnapshot = weekly(80)
    let entering = SmartAlertDetector.deficitAlerts(
      previous: safeSnapshot, current: riskySnapshot, now: paceNow)
    let staying = SmartAlertDetector.deficitAlerts(
      previous: riskySnapshot, current: riskySnapshot, now: paceNow)
    let neverInDeficit = SmartAlertDetector.deficitAlerts(
      previous: safeSnapshot, current: safeSnapshot, now: paceNow)
    guard entering.count == 1,
      case .enteredDeficit(let alertProvider, let alertWindow, _, let deficit, _, let alertReset) =
        entering[0],
      alertProvider == .openAI,
      // Component shares never raise their own alert.
      alertWindow == "weekly",
      deficit > 0,
      alertReset == riskReset,
      staying.isEmpty,
      neverInDeficit.isEmpty,
      entering[0].preferenceKey == "deficit",
      UsagePaceState.stalenessLimit == 30 * 60,
      SmartAlertDetector.stalenessLimit == UsagePaceState.stalenessLimit,
      SmartAlertDetector.isStale(
        lastUpdated: paceNow.addingTimeInterval(-31 * 60), now: paceNow),
      !SmartAlertDetector.isStale(
        lastUpdated: paceNow.addingTimeInterval(-29 * 60), now: paceNow),
      !SmartAlertDetector.isStale(lastUpdated: nil, now: paceNow),
      SmartAlertDetector.isIncident(.degraded),
      SmartAlertDetector.isIncident(.outage),
      !SmartAlertDetector.isIncident(.operational),
      !SmartAlertDetector.isIncident(.unknown),
      !SmartAlertDetector.isIncident(nil)
    else { throw Failure("smart alert detection") }
    passed.append("smart alert detection")

    // The daily series is continuous, ordered oldest first, and quiet days are
    // present rather than missing.
    let seriesNow = Date(timeIntervalSince1970: 1_760_000_000)
    let seriesSummary = LocalUsageSummary(
      provider: .openAI, periodDays: 30, inputTokens: 10, outputTokens: 5,
      apiEquivalentCostUSD: 1,
      dailyTokens: (0..<30).reversed().compactMap { offset in
        Calendar.current.date(byAdding: .day, value: -offset, to: seriesNow).map {
          let formatter = DateFormatter()
          formatter.locale = Locale(identifier: "en_US_POSIX")
          formatter.dateFormat = "yyyy-MM-dd"
          return DailyUsage(day: formatter.string(from: $0), tokens: offset % 4 == 0 ? 0 : 100)
        }
      })
    guard seriesSummary.dailyTokens.count == 30,
      seriesSummary.dailyTokens == seriesSummary.dailyTokens.sorted(by: { $0.day < $1.day }),
      seriesSummary.dailyTokens.contains(where: { $0.tokens == 0 }),
      Set(seriesSummary.dailyTokens.map(\.day)).count == 30,
      DailyUsage(day: "2026-01-01", tokens: -5).tokens == 0
    else { throw Failure("daily usage series") }
    passed.append("daily usage series")

    let httpConfiguration = ProviderHTTPSession.shared.configuration
    guard httpConfiguration.urlCache == nil,
      httpConfiguration.httpCookieStorage == nil,
      httpConfiguration.httpShouldSetCookies == false,
      httpConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData
    else { throw Failure("ephemeral provider HTTP session") }
    passed.append("ephemeral provider HTTP session")

    let healthyStatus = try ServiceStatusClient.decodeStatuspage(
      Data(#"{"status":{"indicator":"none","description":"All Systems Operational"}}"#.utf8),
      provider: .openAI)
    let degradedStatus = try ServiceStatusClient.decodeStatuspage(
      Data(#"{"status":{"indicator":"minor","description":"Partial System Degradation"}}"#.utf8),
      provider: .anthropic)
    let xAIStatus = ServiceStatusClient.decodeXAI(
      Data(
        """
        <rss><channel><item><title>[Grok (Web)] Slow responses</title>
        <description><h3>Status: INVESTIGATING</h3><p>Severity: degraded</p></description>
        </item></channel></rss>
        """.utf8))
    guard healthyStatus.health == .operational,
      degradedStatus.health == .degraded,
      xAIStatus.health == .degraded
    else { throw Failure("official service status decoding") }
    passed.append("official service status decoding")

    let notificationReset = Date(timeIntervalSince1970: 1_900_000_000)
    let oldNotificationSnapshot = UsageSnapshot(
      provider: .openAI,
      windows: [
        UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 49, resetsAt: notificationReset)
      ], source: "test")
    let newNotificationSnapshot = UsageSnapshot(
      provider: .openAI,
      windows: [
        UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 91, resetsAt: notificationReset)
      ], source: "test")
    let crossings = UsageNotificationEventDetector.thresholdCrossings(
      previous: oldNotificationSnapshot, current: newNotificationSnapshot)
    guard crossings.map(\.threshold) == [50, 90] else {
      throw Failure("usage notification thresholds")
    }
    passed.append("usage notification thresholds")

    let openAI = try JSONDecoder().decode(OpenAIRateLimitsResponse.self, from: openAIData)
    guard openAI.rateLimits.primary?.usedPercent == 25.5,
      openAI.rateLimits.secondary?.windowDurationMins == 10080,
      openAI.rateLimits.primary?.stableID(fallback: "primary") == "five-hour",
      openAI.rateLimits.secondary?.stableID(fallback: "secondary") == "weekly",
      openAI.rateLimits.planType == "pro"
    else { throw Failure("OpenAI rate-limit decoding") }
    passed.append("OpenAI rate-limit decoding")

    let anthropic = try JSONDecoder().decode(ClaudeUsageResponse.self, from: anthropicData)
    guard anthropic.fiveHour?.utilization == 14.2,
      anthropic.limits?.first?.scope?.model?.displayName == "Fable",
      anthropic.extraUsage?.includedSpend?.usedMinorUnits == 2845,
      anthropic.extraUsage?.includedSpend?.limitMinorUnits == 10000,
      ClaudeUsageWindow(utilization: nil, resetsAt: nil).window(
        id: "missing", label: "Missing") == nil
    else { throw Failure("Anthropic usage decoding") }
    passed.append("Anthropic usage decoding")

    let retryNow = Date(timeIntervalSince1970: 1_800_000_000)
    guard
      AnthropicProvider.conservativeRetryDate(retryAfter: "60", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "1800", now: retryNow)
        == retryNow.addingTimeInterval(30 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "invalid", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60)
    else { throw Failure("Anthropic conservative backoff") }
    passed.append("Anthropic conservative backoff")

    let anthropicDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: anthropicDirectory) }
    try FileManager.default.createDirectory(
      at: anthropicDirectory, withIntermediateDirectories: true)
    let anthropicCredential = Data(
      #"{"claudeAiOauth":{"accessToken":"fixture-token","subscriptionType":"pro"}}"#.utf8)
    try anthropicCredential.write(
      to: anthropicDirectory.appendingPathComponent(".credentials.json"), options: .atomic)
    let anthropicGate = ClaudeRateLimitGate(defaults: nil)
    let anthropicProvider = AnthropicProvider(
      environment: ["CLAUDE_CONFIG_DIR": anthropicDirectory.path],
      allowKeychainRead: false,
      requestHandler: { request in
        guard request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage",
          request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
          request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20",
          request.cachePolicy == .reloadIgnoringLocalCacheData,
          request.httpShouldHandleCookies == false
        else { throw Failure("Anthropic provider request") }
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (anthropicData, response)
      },
      rateLimitGate: anthropicGate)
    let anthropicSnapshot = try await anthropicProvider.fetch()
    guard anthropicSnapshot.provider == .anthropic,
      anthropicSnapshot.planName == "Pro",
      anthropicSnapshot.source == "Claude OAuth file",
      anthropicSnapshot.windows.first?.id == "five-hour"
    else { throw Failure("Anthropic provider request") }
    passed.append("Anthropic provider request")

    let rateLimitedGate = ClaudeRateLimitGate(defaults: nil)
    let rateLimitedProvider = AnthropicProvider(
      environment: ["CLAUDE_CONFIG_DIR": anthropicDirectory.path],
      allowKeychainRead: false,
      requestHandler: { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 429,
          httpVersion: "HTTP/1.1",
          headerFields: ["Retry-After": "60"])!
        return (Data(), response)
      },
      rateLimitGate: rateLimitedGate)
    let beforeBackoff = Date()
    do {
      _ = try await rateLimitedProvider.fetch()
      throw Failure("Anthropic provider backoff")
    } catch UsageProviderError.rateLimited {
      guard let blockedUntil = await rateLimitedGate.activeBlock(now: beforeBackoff),
        blockedUntil >= beforeBackoff.addingTimeInterval(15 * 60)
      else { throw Failure("Anthropic provider backoff") }
    }
    passed.append("Anthropic provider backoff")

    let grok = try JSONDecoder().decode(GrokBillingEnvelope.self, from: grokData)
    guard grok.config?.usedPercent == 42.5,
      grok.config?.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY",
      grok.config?.includedSpend?.usedMinorUnits == 12345,
      grok.config?.includedSpend?.limitMinorUnits == 99900,
      grok.config?.productUsage?.count == 2,
      grok.config?.productUsage?.first?.product == "GrokBuild",
      grok.subscriptionTier == "SuperGrok Heavy"
    else { throw Failure("Grok billing decoding") }
    passed.append("Grok billing decoding")

    guard SemanticVersion.first(in: "grok 1.0.3") == SemanticVersion(1, 0, 3),
      SemanticVersion(1, 0, 3) > SemanticVersion(0, 1, 210)
    else { throw Failure("semantic version parsing") }
    passed.append("semantic version parsing")

    let future = "2033-05-18T03:33:20Z"
    let credentialEntries = [
      "https://auth.x.ai::broken": GrokCredentialEntry(
        key: nil, userID: "broken", expiresAt: future),
      "fallback": GrokCredentialEntry(
        key: "valid-key", userID: "valid-user", expiresAt: future),
    ]
    let selectedCredentials = GrokCredentialLoader.select(
      entries: credentialEntries,
      now: Date(timeIntervalSince1970: 1_800_000_000))
    guard selectedCredentials?.key == "valid-key", selectedCredentials?.userID == "valid-user"
    else { throw Failure("Grok credential selection") }
    passed.append("Grok credential selection")

    let usageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: usageDirectory) }
    let codexRoot = usageDirectory.appendingPathComponent("codex", isDirectory: true)
    let claudeRoot = usageDirectory.appendingPathComponent("claude", isDirectory: true)
    let grokRoot = usageDirectory.appendingPathComponent("grok", isDirectory: true)
    for root in [codexRoot, claudeRoot, grokRoot] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    let codexLines =
      [
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":1020}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(codexLines.utf8).write(to: codexRoot.appendingPathComponent("session.jsonl"))

    func claudeLine(output: Int, message: String, request: String) -> String {
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"\#(request)","message":{"id":"\#(message)","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":\#(output)}}}"#
    }
    let claudeURL = claudeRoot.appendingPathComponent("session.jsonl")
    try Data(
      ([
        claudeLine(output: 5, message: "m1", request: "r1"),
        claudeLine(output: 7, message: "m1", request: "r1"),
      ].joined(separator: "\n") + "\n").utf8
    ).write(to: claudeURL)
    let grokSession = grokRoot.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: grokSession, withIntermediateDirectories: true)
    try Data(
      #"{"contextTokensUsed":300,"totalTokensBeforeCompaction":200,"primaryModelId":"grok-4.6"}"#
        .utf8
    ).write(to: grokSession.appendingPathComponent("signals.json"))

    let usageCache = usageDirectory.appendingPathComponent("private-index.json")
    let scanner = LocalUsageScanner(
      roots: .init(codex: codexRoot, claude: claudeRoot, grok: grokRoot),
      cacheURL: usageCache)
    let firstUsage = try await scanner.scan(periodDays: 30, now: now)
    let firstCacheModification = try usageCache.resourceValues(
      forKeys: [.contentModificationDateKey]).contentModificationDate
    try await Task.sleep(for: .milliseconds(20))
    let secondUsage = try await scanner.scan(periodDays: 30, now: now)
    let secondCacheModification = try usageCache.resourceValues(
      forKeys: [.contentModificationDateKey]).contentModificationDate
    guard firstUsage[.openAI]?.totalTokens == 1020,
      firstUsage[.openAI]?.todayTokens == 1020,
      firstUsage[.openAI]?.cycleTokens == 1020,
      firstUsage[.anthropic]?.totalTokens == 137,
      firstUsage[.anthropic]?.todayTokens == 137,
      firstUsage[.anthropic]?.cycleTokens == 137,
      firstUsage[.grok]?.totalTokens == 500,
      firstUsage[.grok]?.todayTokens == 500,
      firstUsage[.grok]?.cycleTokens == 500,
      firstUsage == secondUsage,
      firstCacheModification == secondCacheModification,
      (firstUsage[.openAI]?.apiEquivalentCostUSD ?? 0) > 0,
      (firstUsage[.anthropic]?.apiEquivalentCostUSD ?? 0) > 0,
      firstUsage[.grok]?.isCostEstimate == true,
      let usageCacheData = try? Data(contentsOf: usageCache),
      !String(decoding: usageCacheData, as: UTF8.self).contains(usageDirectory.path)
    else { throw Failure("incremental local usage accounting") }
    passed.append("incremental local usage accounting")

    if let helperExecutable {
      let start = ContinuousClock.now
      var timedOut = false
      do {
        _ = try await ProcessRunner.output(
          executable: helperExecutable,
          arguments: ["--timeout-helper"],
          environment: ProcessInfo.processInfo.environment,
          timeout: .milliseconds(100))
      } catch UsageProviderError.timedOut {
        timedOut = true
      } catch {
        throw Failure("subprocess timeout escalation")
      }
      guard timedOut, start.duration(to: .now) < .seconds(2) else {
        throw Failure("subprocess timeout escalation")
      }
      passed.append("subprocess timeout escalation")

      let oversizedStart = ContinuousClock.now
      var rejectedOversizedOutput = false
      do {
        _ = try await ProcessRunner.output(
          executable: helperExecutable,
          arguments: ["--oversized-output-helper"],
          environment: ProcessInfo.processInfo.environment,
          timeout: .seconds(2))
      } catch UsageProviderError.invalidResponse {
        rejectedOversizedOutput = true
      } catch {
        throw Failure("bounded subprocess output")
      }
      guard rejectedOversizedOutput, oversizedStart.duration(to: .now) < .seconds(2) else {
        throw Failure("bounded subprocess output")
      }
      passed.append("bounded subprocess output")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshots.json")
    let cache = SnapshotCache(fileURL: url)
    let snapshot = UsageSnapshot(
      provider: .openAI,
      planName: "Pro",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)],
      source: "test",
      includedSpend: IncludedSpend(
        label: "Included credits", usedMinorUnits: 1234, limitMinorUnits: 5000))
    try await cache.save([.openAI: snapshot])
    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    let loaded = await cache.load()[.openAI]
    let fileMode =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[
        .posixPermissions] as? NSNumber
    guard data.count < 100_000,
      fileMode?.intValue == 0o600,
      directoryMode?.intValue == 0o700,
      !text.localizedCaseInsensitiveContains("access_token"),
      !text.localizedCaseInsensitiveContains("authorization"),
      loaded?.provider == snapshot.provider,
      loaded?.planName == snapshot.planName,
      loaded?.windows == snapshot.windows,
      loaded?.source == snapshot.source,
      loaded?.includedSpend == snapshot.includedSpend
    else { throw Failure("normalized snapshot cache") }
    passed.append("normalized snapshot cache")

    try Data("[]".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: url.path)
    try await cache.save([.openAI: snapshot])
    let repairedMode =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    guard repairedMode?.intValue == 0o600 else {
      throw Failure("restricted cache repairs existing mode")
    }
    passed.append("restricted cache repairs existing mode")

    let older = UsageSnapshot(
      provider: .openAI,
      planName: "Old",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 90)],
      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
      source: "duplicate-test")
    let newer = UsageSnapshot(
      provider: .openAI,
      planName: "New",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)],
      fetchedAt: Date(timeIntervalSince1970: 1_800_000_100),
      source: "duplicate-test")
    let duplicateEncoder = JSONEncoder()
    duplicateEncoder.dateEncodingStrategy = .iso8601
    try duplicateEncoder.encode([newer, older]).write(to: url, options: .atomic)
    let duplicateLoaded = await cache.load()[.openAI]
    guard duplicateLoaded?.planName == "New", duplicateLoaded?.windows == newer.windows else {
      throw Failure("duplicate snapshot recovery")
    }
    passed.append("duplicate snapshot recovery")

    try Data(repeating: 0x41, count: 100 * 1024 + 1).write(to: url, options: .atomic)
    guard await cache.load().isEmpty else { throw Failure("oversized cache rejection") }
    passed.append("oversized cache rejection")


    // MARK: Security regressions

    // A world-writable directory must never supply an executable Reserve runs.
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-locator-\(UUID().uuidString)")
    let openDirectory = sandbox.appendingPathComponent("open")
    try FileManager.default.createDirectory(
      at: openDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o777])
    let planted = openDirectory.appendingPathComponent("reserve-fake-cli")
    FileManager.default.createFile(
      atPath: planted.path, contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: sandbox) }
    guard
      BinaryLocator.find(
        "reserve-fake-cli", environment: ["PATH": openDirectory.path]) == nil
    else { throw Failure("world-writable PATH entry was accepted") }

    // A private directory on PATH still works, so the check is not vacuous.
    let closedDirectory = sandbox.appendingPathComponent("closed")
    try FileManager.default.createDirectory(
      at: closedDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    let trusted = closedDirectory.appendingPathComponent("reserve-fake-cli")
    FileManager.default.createFile(
      atPath: trusted.path, contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755])
    guard
      BinaryLocator.find(
        "reserve-fake-cli", environment: ["PATH": closedDirectory.path]) == trusted.path
    else { throw Failure("a private PATH entry was rejected") }
    passed.append("executable lookup rejects world-writable directories")

    // The dynamic linker must not be steerable through an inherited variable.
    let sanitized = BinaryLocator.childEnvironment([
      "PATH": "/usr/bin",
      "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
      "DYLD_LIBRARY_PATH": "/tmp",
      "LD_PRELOAD": "/tmp/evil.so",
      "HOME": "/Users/someone",
    ])
    guard sanitized["PATH"] == "/usr/bin", sanitized["HOME"] == "/Users/someone",
      sanitized["DYLD_INSERT_LIBRARIES"] == nil, sanitized["DYLD_LIBRARY_PATH"] == nil,
      sanitized["LD_PRELOAD"] == nil
    else { throw Failure("child environment kept a dynamic-linker variable") }
    passed.append("child environment strips dynamic-linker variables")

    return passed
  }

  private struct Failure: LocalizedError {
    let name: String
    init(_ name: String) { self.name = name }
    var errorDescription: String? { "Self-test failed: \(self.name)" }
  }
}
