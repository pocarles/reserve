import Foundation

public enum ReserveSelfTests {
  public static func run(
    openAIData: Data,
    anthropicData: Data,
    grokData: Data,
    helperExecutable: String? = nil,
    progress: @Sendable (String) -> Void = { _ in }
  ) async throws -> [String] {
    var passed: [String] = []
    func record(_ name: String) {
      passed.append(name)
      progress(name)
    }

    guard UsageWindow(id: "low", label: "Low", usedPercent: -2).usedPercent == 0,
      UsageWindow(id: "high", label: "High", usedPercent: 103).usedPercent == 100
    else { throw Failure("usage percentage clamping") }
    record("usage percentage clamping")

    let unnamedSnapshot = UsageSnapshot(
      provider: .grok,
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 1)],
      source: "metadata fallback check")
    guard unnamedSnapshot.withFallbackPlanName("X Premium+").planName == "X Premium+",
      UsageSnapshot(
        provider: .grok, planName: "SuperGrok", windows: [], source: "named"
      ).withFallbackPlanName("X Premium+").planName == "SuperGrok"
    else { throw Failure("snapshot plan-name fallback") }
    record("snapshot plan-name fallback")

    let saturated = LocalUsageSummary(
      provider: .anthropic, periodDays: 30,
      inputTokens: .max, cachedInputTokens: .max,
      cacheWriteInputTokens: .max, outputTokens: .max,
      apiEquivalentCostUSD: 0)
    guard saturated.totalTokens == .max,
      LocalUsageScanner.parseGrokSignal(
        Data(#"{"totalTokensBeforeCompaction":9223372036854775807,"contextTokensUsed":9223372036854775807}"#.utf8))?.input == .max
    else { throw Failure("saturating token aggregation") }
    record("saturating token aggregation")

    let boundedWindow = UsageWindow(
      id: String(repeating: "x", count: 5_000),
      label: String(repeating: "y", count: 5_000), usedPercent: .infinity,
      windowMinutes: .max, resetsAt: Date().addingTimeInterval(3_600))
    let boundedSnapshot = UsageSnapshot(
      provider: .openAI, windows: Array(repeating: boundedWindow, count: 100), source: "test")
    let extremeReset = UsageWindow(
      id: "extreme", label: "Extreme", usedPercent: 99, windowMinutes: 60,
      resetsAt: Date(timeIntervalSince1970: TimeInterval(Int.max)))
    let notificationID = StableIdentifier.notificationComponent(String(repeating: "z", count: 50_000))
    guard boundedWindow.id.count == UsageWindow.maximumIdentifierCharacters,
      boundedWindow.label.count == UsageWindow.maximumLabelCharacters,
      boundedWindow.usedPercent == 0,
      boundedWindow.windowMinutes == nil,
      extremeReset.resetsAt == nil,
      boundedSnapshot.windows.count == UsageSnapshot.maximumWindows,
      notificationID.count == 32
    else { throw Failure("bounded provider identifiers") }
    record("bounded provider identifiers")

    let lineBuffer = BoundedLineBuffer(maximumBytes: 8)
    guard !lineBuffer.append(Data("12345678".utf8)).exceeded,
      lineBuffer.append(Data("9".utf8)).exceeded
    else { throw Failure("bounded line allocation") }
    let recoveredLines = lineBuffer.append(Data("tail\nok\n".utf8))
    guard recoveredLines.exceeded,
      recoveredLines.lines.map({ String(decoding: $0, as: UTF8.self) }) == ["ok"],
      recoveredLines.consumedBytes == 8
    else { throw Failure("oversized line recovery") }
    let cursorBuffer = BoundedLineBuffer(maximumBytes: 32)
    let firstCursor = cursorBuffer.append(Data("one\ntwo\nthree\n".utf8), maximumLines: 2)
    let secondCursor = cursorBuffer.append(Data(), maximumLines: 2)
    guard firstCursor.consumedBytes == 8, firstCursor.lines.count == 2,
      secondCursor.consumedBytes == 6, secondCursor.lines.count == 1
    else { throw Failure("bounded line cursor") }
    let outputGate = BoundedOutputGate(maximumBytes: 8)
    guard outputGate.append(Data("abc".utf8)) == .scheduleDrain,
      outputGate.append(Data("de".utf8)) == .accepted,
      String(decoding: outputGate.drain(), as: UTF8.self) == "abcde",
      outputGate.append(Data("fghi".utf8)) == .overflow
    else { throw Failure("bounded callback output") }
    record("bounded line and callback output")

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
    let earlyReset = paceNow.addingTimeInterval((7 * 24 * 60 - 30) * 60)
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
        for: UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 1,
          windowMinutes: 7 * 24 * 60, resetsAt: earlyReset),
        fetchedAt: paceNow, now: paceNow) == .unknown,
      UsagePaceState.calculate(
        for: UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20),
        fetchedAt: paceNow.addingTimeInterval(-31 * 60), now: paceNow) == .stale,
      UsagePaceState.calculate(
        for: UsageWindow(id: "weekly", label: "Weekly", usedPercent: 100),
        fetchedAt: paceNow.addingTimeInterval(-31 * 60), now: paceNow) == .stale,
      UsagePaceState.calculate(
        for: UsageWindow(id: "weekly", label: "Weekly", usedPercent: 100),
        fetchedAt: paceNow, hasError: true, now: paceNow) == .stale,
      UsagePaceProjection.calculate(
        for: UsageWindow(
          id: "expired", label: "Weekly", usedPercent: 20,
          windowMinutes: 7 * 24 * 60, resetsAt: paceNow), now: paceNow) == nil
    else { throw Failure("usage pace projection") }
    record("usage pace projection")

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
    let initialFetch = SmartAlertDetector.deficitAlerts(
      previous: nil, current: riskySnapshot, now: paceNow)
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
      initialFetch.isEmpty,
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
    record("smart alert detection")

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
    record("daily usage series")

    let httpConfiguration = ProviderHTTPSession.shared.configuration
    guard httpConfiguration.urlCache == nil,
      httpConfiguration.httpCookieStorage == nil,
      httpConfiguration.httpShouldSetCookies == false,
      httpConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData
    else { throw Failure("ephemeral provider HTTP session") }
    record("ephemeral provider HTTP session")

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
    record("official service status decoding")

    let notificationReset = Date(timeIntervalSince1970: 1_900_000_000)
    let oldNotificationSnapshot = UsageSnapshot(
      provider: .openAI,
      windows: [
        UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 49, resetsAt: notificationReset),
        UsageWindow(
          id: "build-share", label: "Build share", usedPercent: 49,
          resetsAt: notificationReset),
      ], source: "test")
    let newNotificationSnapshot = UsageSnapshot(
      provider: .openAI,
      windows: [
        UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 91, resetsAt: notificationReset),
        UsageWindow(
          id: "build-share", label: "Build share", usedPercent: 91,
          resetsAt: notificationReset),
      ], source: "test")
    let crossings = UsageNotificationEventDetector.thresholdCrossings(
      previous: oldNotificationSnapshot, current: newNotificationSnapshot)
    guard crossings.map(\.threshold) == [50, 90],
      crossings.allSatisfy({ $0.windowID == "weekly" })
    else {
      throw Failure("usage notification thresholds")
    }
    record("usage notification thresholds")

    let openAI = try JSONDecoder().decode(OpenAIRateLimitsResponse.self, from: openAIData)
    guard openAI.rateLimits.primary?.usedPercent == 25.5,
      openAI.rateLimits.secondary?.windowDurationMins == 10080,
      openAI.rateLimits.primary?.stableID(fallback: "primary") == "five-hour",
      openAI.rateLimits.secondary?.stableID(fallback: "secondary") == "weekly",
      openAI.rateLimits.planType == "pro"
    else { throw Failure("OpenAI rate-limit decoding") }
    record("OpenAI rate-limit decoding")

    guard OpenAIPlanFormatter.plan(from: "pro") == "Pro",
      OpenAIPlanFormatter.plan(from: "chatgpt_plus") == "Plus",
      OpenAIPlanFormatter.plan(from: "business") == "Business",
      OpenAIPlanFormatter.plan(from: "  ") == nil,
      ClaudePlanFormatter.plan(from: "default_claude_max_5x") == "Max 5x",
      ClaudePlanFormatter.plan(from: "default-claude-max-20x") == "Max 20x",
      ClaudePlanFormatter.plan(from: "team") == "Team",
      GrokPlanFormatter.plan(from: "supergrok_heavy") == "SuperGrok Heavy",
      GrokPlanFormatter.plan(from: "x_premium_plus") == "X Premium+",
      GrokPlanFormatter.plan(from: "premium") == "X Premium"
    else { throw Failure("provider plan-name normalization") }
    record("provider plan-name normalization")

    let anthropic = try JSONDecoder().decode(ClaudeUsageResponse.self, from: anthropicData)
    guard anthropic.fiveHour?.utilization == 14.2,
      anthropic.limits?.first?.scope?.model?.displayName == "Fable",
      anthropic.extraUsage?.includedSpend?.usedMinorUnits == 2845,
      anthropic.extraUsage?.includedSpend?.limitMinorUnits == 10000,
      ClaudeUsageWindow(utilization: nil, resetsAt: nil).window(
        id: "missing", label: "Missing") == nil
    else { throw Failure("Anthropic usage decoding") }
    record("Anthropic usage decoding")

    let retryNow = Date(timeIntervalSince1970: 1_800_000_000)
    guard
      AnthropicProvider.conservativeRetryDate(retryAfter: "60", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "1800", now: retryNow)
        == retryNow.addingTimeInterval(30 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "invalid", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "inf", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "999999999999", now: retryNow)
        == retryNow.addingTimeInterval(AnthropicProvider.maximumRetryDelay)
    else { throw Failure("Anthropic conservative backoff") }
    record("Anthropic conservative backoff")

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
    record("Anthropic provider request")

    let expiredClaudeCredential = Data(
      #"{"claudeAiOauth":{"accessToken":"old-token","expiresAt":1799999999000}}"#.utf8)
    do {
      _ = try ClaudeCredentialLoader.decode(
        data: expiredClaudeCredential, source: "legacy file",
        now: Date(timeIntervalSince1970: 1_800_000_000))
      throw Failure("expired Claude credential file")
    } catch UsageProviderError.credentialsNotFound {
      record("expired Claude credential file")
    }

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
    record("Anthropic provider backoff")

    let grok = try JSONDecoder().decode(GrokBillingEnvelope.self, from: grokData)
    guard grok.config?.usedPercent == 42.5,
      grok.config?.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY",
      grok.config?.includedSpend?.usedMinorUnits == 12345,
      grok.config?.includedSpend?.limitMinorUnits == 99900,
      grok.config?.productUsage?.count == 2,
      grok.config?.productUsage?.first?.product == "GrokBuild",
      grok.subscriptionTier == "SuperGrok Heavy"
    else { throw Failure("Grok billing decoding") }
    record("Grok billing decoding")

    let unifiedGrokData = Data(
      #"{"config":{"creditUsagePercent":25,"onDemandCap":{"val":4000},"onDemandUsed":{"val":1000},"isUnifiedBillingUser":true}}"#.utf8)
    let unifiedGrok = try JSONDecoder().decode(GrokBillingEnvelope.self, from: unifiedGrokData)
    guard unifiedGrok.config?.usedPercent == 25,
      unifiedGrok.config?.includedSpend?.label == "On-demand cap",
      unifiedGrok.config?.includedSpend?.usedMinorUnits == 1000,
      unifiedGrok.config?.includedSpend?.limitMinorUnits == 4000,
      unifiedGrok.config?.isUnifiedBillingUser == true
    else { throw Failure("Grok unified billing decoding") }
    record("Grok unified billing decoding")

    let incompleteUnifiedGrokData = Data(
      #"{"config":{"onDemandCap":{"val":4000},"onDemandUsed":{"val":1000},"isUnifiedBillingUser":true}}"#.utf8)
    let incompleteUnifiedGrok = try JSONDecoder().decode(
      GrokBillingEnvelope.self, from: incompleteUnifiedGrokData)
    guard incompleteUnifiedGrok.config?.usedPercent == nil else {
      throw Failure("Grok on-demand spend treated as included allowance")
    }
    record("Grok incomplete unified billing")

    let resetUnifiedGrokData = Data(
      #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-15T22:03:41Z","end":"2026-08-22T22:03:41Z"},"monthlyLimit":{"val":99900},"used":{"val":12345},"onDemandCap":{},"onDemandUsed":{},"productUsage":[{"product":"GrokBuild"},{"product":"GrokChat","usagePercent":0}],"isUnifiedBillingUser":true}}"#.utf8)
    let resetUnifiedGrok = try JSONDecoder().decode(
      GrokBillingEnvelope.self, from: resetUnifiedGrokData)
    guard resetUnifiedGrok.config?.usedPercent == 0,
      resetUnifiedGrok.config?.includedSpend?.usedMinorUnits == 12345,
      resetUnifiedGrok.config?.includedSpend?.limitMinorUnits == 99900,
      resetUnifiedGrok.config?.productUsage?.allSatisfy({ $0.usagePercent == 0 }) == true
    else {
      throw Failure("Grok reset-period zero normalization")
    }
    record("Grok reset-period zero normalization")

    let grokSettings = try JSONDecoder().decode(
      GrokRemoteSettings.self,
      from: Data(#"{"subscription_tier_display":"X Premium+"}"#.utf8))
    guard grokSettings.subscriptionTierDisplay == "X Premium+" else {
      throw Failure("Grok remote tier decoding")
    }
    record("Grok remote tier decoding")

    guard SemanticVersion.first(in: "grok 1.0.3") == SemanticVersion(1, 0, 3),
      SemanticVersion(1, 0, 3) > SemanticVersion(0, 1, 210),
      SemanticVersion(1, 0, 3).headerValue == "1.0.3"
    else { throw Failure("semantic version parsing") }
    record("semantic version parsing")

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
    let deterministicCredentials = GrokCredentialLoader.select(
      entries: [
        "zeta": GrokCredentialEntry(key: "zeta-key", userID: "zeta-user", expiresAt: future),
        "alpha": GrokCredentialEntry(
          key: "alpha-key", userID: "alpha-user", expiresAt: future),
      ],
      now: Date(timeIntervalSince1970: 1_800_000_000))
    guard deterministicCredentials?.key == "alpha-key" else {
      throw Failure("deterministic Grok credential selection")
    }
    record("Grok credential selection")

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
    record("incremental local usage accounting")

    let oversizedRoot = usageDirectory.appendingPathComponent("oversized", isDirectory: true)
    let oversizedCodex = oversizedRoot.appendingPathComponent("codex", isDirectory: true)
    let oversizedClaude = oversizedRoot.appendingPathComponent("claude", isDirectory: true)
    let oversizedGrok = oversizedRoot.appendingPathComponent("grok", isDirectory: true)
    for root in [oversizedCodex, oversizedClaude, oversizedGrok] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let oversizedCodexLines =
      [
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":1020}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(oversizedCodexLines.utf8).write(
      to: oversizedCodex.appendingPathComponent("session.jsonl"))
    let healthyClaudeLine = claudeLine(output: 5, message: "oversized-m1", request: "oversized-r1")
    var oversizedClaudeData = Data(repeating: 0x41, count: 1_048_577)
    oversizedClaudeData.append(Data(("\n" + healthyClaudeLine + "\n").utf8))
    try oversizedClaudeData.write(to: oversizedClaude.appendingPathComponent("session.jsonl"))
    let boundedScanner = LocalUsageScanner(
      roots: .init(codex: oversizedCodex, claude: oversizedClaude, grok: oversizedGrok),
      cacheURL: oversizedRoot.appendingPathComponent("index.json"))
    let boundedScanDate = Date(timeIntervalSince1970: 1_700_000_000)
    let boundedUsage = try await boundedScanner.scan(now: boundedScanDate)
    let repeatedBoundedUsage = try await boundedScanner.scan(now: boundedScanDate)
    guard boundedUsage[.openAI]?.totalTokens == 1020,
      boundedUsage[.anthropic]?.totalTokens == 135,
      repeatedBoundedUsage == boundedUsage
    else { throw Failure("oversized session line recovery") }
    record("oversized session line recovery")

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
      record("subprocess timeout escalation")

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
      record("bounded subprocess output")

      let drainStart = ContinuousClock.now
      do {
        _ = try await ProcessRunner.output(
          executable: helperExecutable,
          arguments: ["--descendant-pipe-helper"],
          environment: ProcessInfo.processInfo.environment,
          timeout: .milliseconds(200))
        throw Failure("subprocess descendant pipe deadline")
      } catch UsageProviderError.timedOut {
        guard drainStart.duration(to: .now) < .seconds(2) else {
          throw Failure("subprocess descendant pipe deadline")
        }
      }
      record("subprocess descendant pipe deadline")
    }

    let rpcScript = #"read line; i=0; while [ $i -lt 80 ]; do printf '{"id":999,"result":{}}\n'; i=$((i+1)); done"#
    let overflowingRPC = try JSONRPCProcess(
      executable: "/bin/sh", arguments: ["-c", rpcScript],
      environment: ProcessInfo.processInfo.environment)
    defer { overflowingRPC.shutdown() }
    do {
      _ = try await overflowingRPC.request(method: "test", timeout: .seconds(2))
      throw Failure("bounded JSON-RPC queue")
    } catch UsageProviderError.processFailed {
      record("bounded JSON-RPC queue")
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
    record("normalized snapshot cache")

    let oldSuite = "Reserve.SelfTest.Legacy"
    let newSuite = "Reserve.SelfTest.Current"
    let oldDefaults = Self.freshDefaults(suiteName: oldSuite)
    let newDefaults = Self.freshDefaults(suiteName: newSuite)
    defer {
      Self.cleanDefaults(oldDefaults, suiteName: oldSuite)
      Self.cleanDefaults(newDefaults, suiteName: newSuite)
    }
    oldDefaults.set(false, forKey: "provider.grok.enabled")
    oldDefaults.set(15, forKey: "refresh.intervalMinutes")
    oldDefaults.set("must-not-migrate", forKey: "credential.secret")
    let migrationOld = directory.appendingPathComponent("UsageBar", isDirectory: true)
    let migrationNew = directory.appendingPathComponent("Reserve", isDirectory: true)
    try FileManager.default.createDirectory(at: migrationOld, withIntermediateDirectories: true)
    let migrationEncoder = JSONEncoder()
    migrationEncoder.dateEncodingStrategy = .iso8601
    try migrationEncoder.encode([snapshot]).write(
      to: migrationOld.appendingPathComponent("snapshots.json"))
    try Data(#"{"version":1,"records":{}}"#.utf8).write(
      to: migrationOld.appendingPathComponent("local-usage-index.json"))
    try Data("secret".utf8).write(to: migrationOld.appendingPathComponent("credentials.json"))
    let migration = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: migrationOld, newDirectory: migrationNew)
    let repeatedMigration = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: migrationOld, newDirectory: migrationNew)
    let migratedDirectoryMode = try FileManager.default.attributesOfItem(
      atPath: migrationNew.path)[.posixPermissions] as? NSNumber
    guard migration.migratedPreferenceCount == 2,
      migration.migratedCacheFiles == ["local-usage-index.json", "snapshots.json"],
      !migration.cacheMigrationFailed,
      newDefaults.object(forKey: "credential.secret") == nil,
      !FileManager.default.fileExists(
        atPath: migrationNew.appendingPathComponent("credentials.json").path),
      FileManager.default.fileExists(
        atPath: migrationOld.appendingPathComponent("snapshots.json").path),
      migratedDirectoryMode?.intValue == 0o700,
      repeatedMigration.wasAlreadyCompleted
    else { throw Failure("legacy state migration") }
    record("legacy state migration")

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
    record("restricted cache repairs existing mode")

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
    record("duplicate snapshot recovery")

    try Data(repeating: 0x41, count: 100 * 1024 + 1).write(to: url, options: .atomic)
    guard await cache.load().isEmpty else { throw Failure("oversized cache rejection") }
    record("oversized cache rejection")


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
    record("executable lookup rejects world-writable directories")

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
    record("child environment strips dynamic-linker variables")

    return passed
  }

  private static func freshDefaults(suiteName: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName)!
    Self.cleanDefaults(defaults, suiteName: suiteName)
    return defaults
  }

  private static func cleanDefaults(_ defaults: UserDefaults, suiteName: String) {
    defaults.removePersistentDomain(forName: suiteName)
    let plist = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: plist)
  }

  private struct Failure: LocalizedError {
    let name: String
    init(_ name: String) { self.name = name }
    var errorDescription: String? { "Self-test failed: \(self.name)" }
  }
}
