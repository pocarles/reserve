import Foundation
import Testing
@testable import ReserveCore

@Suite struct CopilotProviderTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func quota(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = [
      "isUnlimitedEntitlement": false, "entitlementRequests": 300,
      "usedRequests": 75, "remainingPercentage": 75, "resetDate": "2027-02-01T00:00:00Z",
    ]
    value.merge(overrides) { _, replacement in replacement }
    return value
  }

  static func data(_ quotas: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["quotaSnapshots": quotas])
  }

  @Test func readsLimitedQuotasAndOmitsUnlimitedProducts() throws {
    let data = try Self.data([
      "premium_interactions": Self.quota(),
      "chat": Self.quota(["entitlementRequests": -1, "isUnlimitedEntitlement": true]),
      "completions": Self.quota(["remainingPercentage": 20]),
    ])
    let snapshot = try CopilotProvider.decodeQuota(data, now: Self.now)
    #expect(snapshot.provider == .copilot)
    #expect(snapshot.windows.map(\.id) == ["premium_interactions", "completions"])
    #expect(snapshot.windows.map(\.usedPercent) == [25, 80])
    #expect(snapshot.windows.allSatisfy { $0.windowMinutes == nil && $0.resetsAt != nil })
    #expect(snapshot.planName == nil)
    #expect(snapshot.monthlyPriceMinorUnits == nil)
    #expect(snapshot.accountUsage == nil)
    #expect(snapshot.detailedUsageUnavailable)
    #expect(snapshot.fetchedAt == Self.now)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
  }

  @Test func doesNotInventPeriodLengthOrUnknownQuotaMeaning() throws {
    let snapshot = try CopilotProvider.decodeQuota(Self.data([
      "future_allowance": Self.quota(["resetDate": NSNull()]),
      "premium_interactions": Self.quota(["resetDate": "2027-02-01"]),
    ]), now: Self.now)
    #expect(snapshot.windows[0].resetsAt != nil)
    #expect(snapshot.windows[1].label == "Future Allowance")
    #expect(snapshot.windows[1].resetsAt == nil)
    #expect(UsagePaceProjection.calculate(for: snapshot.windows[0], now: Self.now) == nil)
  }

  @Test func rejectsInvalidUnknownOrExpiredData() throws {
    for overrides: [String: Any] in [
      ["remainingPercentage": -1], ["remainingPercentage": 101],
      ["remainingPercentage": true], ["remainingPercentage": "NaN"],
      ["usedRequests": -1], ["entitlementRequests": -2],
      ["isUnlimitedEntitlement": "false"], ["resetDate": "invalid"],
      ["resetDate": "2000-01-01T00:00:00Z"], ["resetDate": "2040-01-01T00:00:00Z"],
    ] {
      #expect(throws: UsageProviderError.self) {
        try CopilotProvider.decodeQuota(Self.data(["premium_interactions": Self.quota(overrides)]), now: Self.now)
      }
    }
    for data in [Data(), Data("{}".utf8), Data("[]".utf8), Data(repeating: 32, count: 65_537),
      try Self.data([:]), try Self.data(["chat": Self.quota(["isUnlimitedEntitlement": true])])]
    {
      #expect(throws: UsageProviderError.self) { try CopilotProvider.decodeQuota(data, now: Self.now) }
    }
  }

  @Test func childUsesSavedLoginWithoutInheritedTokensOrRuntimeInjection() {
    let safe = CopilotProvider.childEnvironment([
      "HOME": "/home/test", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
      "GH_TOKEN": "fixture", "COPILOT_GITHUB_TOKEN": "fixture", "GITHUB_TOKEN": "fixture",
      "NODE_OPTIONS": "fixture", "COPILOT_API_URL": "fixture", "COPILOT_HOME": "fixture",
    ])
    #expect(safe == ["HOME": "/home/test", "PATH": "/usr/bin", "LANG": "en_US.UTF-8"])
    #expect(CopilotProvider.runtimeArguments == ["--headless", "--no-auto-update", "--stdio"])
  }

  @Test func frameReaderHandlesFragmentedHeadersAndBodies() throws {
    let parser = CopilotFrameBuffer()
    #expect(try parser.append(Data("Content-Len".utf8)).isEmpty)
    #expect(try parser.append(Data("gth: 7\r\n\r\n{\"x\"".utf8)).isEmpty)
    let frames = try parser.append(Data(":1}Content-Length: 2\r\n\r\n{}".utf8))
    #expect(frames == [Data("{\"x\":1}".utf8), Data("{}".utf8)])
  }

  @Test func frameReaderRejectsUnboundedOrAmbiguousInput() {
    for input in [
      "Content-Length: -1\r\n\r\n", "Content-Length: 65537\r\n\r\n",
      "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
      String(repeating: "x", count: 1_025), "Other: 2\r\n\r\n{}",
    ] {
      #expect(throws: UsageProviderError.self) { try CopilotFrameBuffer().append(Data(input.utf8)) }
    }
  }

  @Test func completeTransportReadsOnlyHandshakeAuthenticationAndQuota() async throws {
    let fixture = try Self.fixture(mode: "normal")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let process = try CopilotQuotaProcess(executable: "/usr/bin/python3",
      arguments: [fixture.script.path, fixture.calls.path, "normal"], environment: ["PATH": "/usr/bin:/bin"])
    defer { process.shutdown() }
    let result = try await process.readQuota()
    let snapshot = try CopilotProvider.decodeQuota(result, now: Self.now)
    #expect(snapshot.windows.first?.usedPercent == 25)
    let calls = try String(contentsOf: fixture.calls, encoding: .utf8).split(separator: "\n")
    #expect(calls == ["connect", "auth.getStatus", "account.getQuota"])
  }

  @Test func legacyHandshakeFallsBackWithoutCreatingSession() async throws {
    let fixture = try Self.fixture(mode: "legacy")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let process = try CopilotQuotaProcess(executable: "/usr/bin/python3",
      arguments: [fixture.script.path, fixture.calls.path, "legacy"], environment: ["PATH": "/usr/bin:/bin"])
    defer { process.shutdown() }
    _ = try await process.readQuota()
    #expect(try String(contentsOf: fixture.calls, encoding: .utf8).split(separator: "\n")
      == ["connect", "ping", "auth.getStatus", "account.getQuota"])
  }

  @Test func unsupportedProtocolAndSignedOutAccountHaveActionableFailures() async throws {
    for mode in ["version", "signedout", "missingquota"] {
      let fixture = try Self.fixture(mode: mode)
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let process = try CopilotQuotaProcess(executable: "/usr/bin/python3",
        arguments: [fixture.script.path, fixture.calls.path, mode], environment: ["PATH": "/usr/bin:/bin"])
      defer { process.shutdown() }
      do {
        _ = try await process.readQuota()
        Issue.record("Invalid account or protocol was accepted")
      } catch let error as UsageProviderError {
        if mode == "signedout" { #expect(error.requiresConnection) }
        else if case .updateRequired = error {} else { Issue.record("Expected an update action") }
      }
      let calls = try String(contentsOf: fixture.calls, encoding: .utf8)
      #expect(!calls.contains("session."))
      if mode != "missingquota" { #expect(!calls.contains("account.getQuota")) }
    }
  }

  @Test func timeoutAndCancellationStopWaitingForSilentRuntime() async throws {
    for cancel in [false, true] {
      let fixture = try Self.fixture(mode: "silent")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let process = try CopilotQuotaProcess(executable: "/usr/bin/python3",
        arguments: [fixture.script.path, fixture.calls.path, "silent"], environment: ["PATH": "/usr/bin:/bin"])
      defer { process.shutdown() }
      let start = ContinuousClock.now
      let task = Task { try await process.readQuota(timeout: cancel ? .seconds(10) : .milliseconds(300)) }
      if cancel {
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
      }
      do { _ = try await task.value; Issue.record("Silent runtime returned a result") }
      catch let error as UsageProviderError {
        if !cancel { #expect(error == .timedOut("Copilot usage check")) }
      } catch {
        #expect(cancel && error is CancellationError)
      }
      #expect(start.duration(to: .now) < .seconds(3))
    }
  }

  private static func fixture(mode: String) throws -> (directory: URL, script: URL, calls: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("quota-fixture.py")
    let calls = directory.appendingPathComponent("calls.txt")
    try #"""
    import sys, json, time
    while True:
        header = sys.stdin.buffer.readline()
        if not header: break
        length = int(header.decode().split(":", 1)[1])
        assert sys.stdin.buffer.readline() == b"\r\n"
        request = json.loads(sys.stdin.buffer.read(length))
        method = request["method"]
        with open(sys.argv[1], "a") as log: log.write(method + "\n")
        mode = sys.argv[2]
        if mode == "silent":
            time.sleep(30)
            continue
        error = None
        if method == "connect" and mode == "legacy": error = {"code": -32601}
        elif method in ("connect", "ping"): result = {"protocolVersion": 99 if mode == "version" else 3}
        elif method == "auth.getStatus": result = {"isAuthenticated": mode != "signedout"}
        elif method == "account.getQuota" and mode == "missingquota": error = {"code": -32601}
        elif method == "account.getQuota":
            result = {"quotaSnapshots": {"premium_interactions": {
                "isUnlimitedEntitlement": False, "entitlementRequests": 300,
                "usedRequests": 75, "remainingPercentage": 75,
                "resetDate": "2027-02-01T00:00:00Z"}}}
        else: raise Exception("Unexpected RPC: " + method)
        response = {"jsonrpc": "2.0", "id": request["id"]}
        response["error" if error else "result"] = error or result
        body = json.dumps(response).encode()
        sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
        sys.stdout.buffer.flush()
    """#.write(to: script, atomically: true, encoding: .utf8)
    return (directory, script, calls)
  }
}

@Suite struct ProviderDescriptorTests {
  @Test func everyProviderHasOneCompleteDescriptor() {
    for provider in ProviderID.allCases {
      let descriptor = ProviderDescriptor.forProvider(provider)
      #expect(descriptor.id == provider)
      #expect(!descriptor.displayName.isEmpty)
      var urls = [descriptor.accountURL]
      if descriptor.usesAPIKey {
        // Key-connected plans have no helper; the key page is their setup URL.
        #expect(descriptor.helper == nil)
        #expect(descriptor.apiKeyConnection != nil)
        urls += descriptor.apiKeyConnection.map { [$0.keySettingsURL] } ?? []
      } else {
        #expect(descriptor.helper?.provider == provider)
        #expect(descriptor.helper?.executable.isEmpty == false)
        urls += descriptor.helper.map { [$0.installerURL] } ?? []
        // Every helper-backed provider has an official status page.
        #expect(descriptor.statusURL != nil && descriptor.statusFeedURL != nil)
      }
      urls += [descriptor.statusURL, descriptor.statusFeedURL].compactMap { $0 }
      for url in urls {
        #expect(url.scheme == "https")
        #expect(url.host != nil)
      }
    }
    #expect(!ProviderDescriptor.forProvider(.copilot).supportsAutomaticHelperInstallation)
    #expect(!ProviderDescriptor.forProvider(.copilot).capabilities.contains(.localHistory))
    #expect(ProviderDescriptor.forProvider(.grok).statusFormat == .rss)
  }

  @Test func authenticationAndInstallerStrategiesKeepExistingBoundaries() {
    #expect(ProviderDescriptor.forProvider(.anthropic).authenticationStrategy == .protectedSession)
    #expect(ProviderDescriptor.forProvider(.cursor).authenticationStrategy == .protectedSession)
    #expect(ProviderDescriptor.forProvider(.copilot).authenticationStrategy == .cliOAuth)
    #expect(ProviderDescriptor.forProvider(.grok).loginArguments == ["login", "--device-auth"])
    #expect(ProviderDescriptor.forProvider(.anthropic).loginArguments == ["auth", "login", "--claudeai"])
    #expect(ProviderDescriptor.forProvider(.copilot).trustedLoginHosts == ["github.com"])
    #expect(ProviderDescriptor.forProvider(.copilot).installationStrategy == .manualHelper)
    #expect(ProviderDescriptor.forProvider(.copilot).helper?.updateArguments.isEmpty == true)
    #expect(ProviderDescriptor.forProvider(.openAI).helper?.updateArguments == ["update"])
  }
}
