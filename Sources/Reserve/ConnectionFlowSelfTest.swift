#if RESERVE_DEV_AUTOMATION
import AppKit
import ReserveCore

@MainActor
enum ConnectionFlowSelfTest {
  static func run() async -> [String] {
    var failures: [String] = []
    func expect(_ value: Bool, _ message: String) {
      if !value { failures.append(message) }
    }
    let evidence = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-connection-review", isDirectory: true)
    try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let browserURL = URL(string: "https://auth.x.ai/test?state=one&value=two")!
    let browserArguments = LoginBrowser.chromeArguments(
      for: browserURL, home: URL(fileURLWithPath: "/Users/Example User"))
    expect(browserArguments == [
      "--user-data-dir=/Users/Example User/Library/Application Support/Google/Chrome",
      browserURL.absoluteString,
    ], "login browser did not target the normal Chrome instance with an intact URL")
    expect(UsageStore.authorizationURL(
      in: "Continue: https://accounts.x.ai/oauth2/device?user_code=test-code", for: .grok)?
      .query == "user_code=test-code", "Grok browser handoff lost the prefilled device code")
    expect(UsageStore.authorizationURL(
      in: "https://accounts.x.ai.example.org/oauth2/device?user_code=test-code", for: .grok) == nil,
      "Grok browser handoff accepted an unrelated host")
    do {
      var handedOffURL = ""
      let pipe = try ClaudeLoginBrowserPipe { data in
        handedOffURL += String(decoding: data, as: UTF8.self)
      }
      let callbackURL = "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A12345%2Fcallback&state=test"
      let writer = Process()
      writer.executableURL = URL(fileURLWithPath: pipe.browserExecutable)
      writer.arguments = [callbackURL]
      writer.environment = ["RESERVE_LOGIN_PIPE": pipe.path]
      writer.standardOutput = FileHandle.nullDevice
      writer.standardError = FileHandle.nullDevice
      try writer.run()
      await settle { handedOffURL.contains("\n") && !writer.isRunning }
      expect(handedOffURL.trimmingCharacters(in: .whitespacesAndNewlines) == callbackURL,
        "Claude browser pipe did not preserve the automatic callback URL")
      expect(UsageStore.authorizationURL(in: handedOffURL, for: .anthropic)?.query?
        .contains("localhost") == true, "Claude callback URL was not accepted")
      let pipeDirectory = pipe.directory
      pipe.close()
      expect(!FileManager.default.fileExists(atPath: pipeDirectory.path),
        "Claude browser pipe was not removed after login cleanup")
    } catch {
      failures.append("Claude browser pipe could not complete its handoff: \(error.localizedDescription)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-connection-check-\(UUID().uuidString)", isDirectory: true)
    let suite = "Reserve.ConnectionSelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["isolated preferences unavailable"] }
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { return ["isolated test directory unavailable"] }
    let cache = SnapshotCache(fileURL: directory.appendingPathComponent("snapshots.json"))
    let responses = ConnectionTestResponses()
    var openedBrowserCount = 0
    var lastOpenedBrowserURL: URL?
    let store = UsageStore(
      defaults: defaults, startAutomatically: false, cache: cache,
      fetchOverride: { provider, allowAccess in
        try await responses.fetch(provider, allowAccess: allowAccess)
      },
      loginCommandOverride: { _ in
        ("/bin/sh", [directory.appendingPathComponent("login.sh").path])
      },
      openLoginURL: { url in openedBrowserCount += 1; lastOpenedBrowserURL = url; return true })
    let coordinator = ProviderSetupCoordinator(store: store)
    defer { coordinator.close() }

    await responses.set(.missingHelper)
    coordinator.start(.openAI)
    await settle { coordinator.phase == .needsInstall }
    expect(coordinator.phase == .needsInstall, "missing helper did not offer installation")
    expect(coordinator.panel?.isVisible == true, "connection window is not visible")
    let window = coordinator.panel
    coordinator.start(.cursor)
    expect(coordinator.panel === window && coordinator.activeProvider == .openAI,
      "overlapping connections created a second flow")
    click("connection-close", in: coordinator.panel)
    expect(coordinator.activeProvider == nil, "Cancel did not dismiss setup")

    await responses.set(.permission)
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsAccess }
    let accessWindow = coordinator.panel
    expect(coordinator.phase == .needsAccess, "permission was presented as expired login")
    click("connection-primary", in: accessWindow)
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected && coordinator.panel === accessWindow,
      "permission did not finish in the same window after reading usage")
    expect(openedBrowserCount == 0, "existing sign-in unnecessarily opened a browser")
    click("connection-primary", in: coordinator.panel)
    expect(coordinator.activeProvider == nil, "Done did not dismiss the verified connection")

    // Grant access while an older background check is still returning a
    // consent error. That older result must not revoke the new permission.
    await responses.set(.slowPermission)
    var queuedPermissionFinished = false
    store.refresh(.anthropic)
    try? await Task.sleep(for: .milliseconds(30))
    store.allowKeychainAccess(for: .anthropic) { queuedPermissionFinished = true }
    await settle { queuedPermissionFinished }
    expect(queuedPermissionFinished && store.states[.anthropic]?.error == nil
      && store.claudeKeychainReadAllowed, "a late consent error undid newly granted access")

    await responses.set(.deniedPermission)
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsAccess }
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .accessNotGranted }
    expect(coordinator.phase == .accessNotGranted, "denied permission silently repeated the first permission screen")
    let recoveryScript = """
      #!/bin/sh
      echo 'https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback'
      "$BROWSER" 'https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A12345%2Fcallback&state=simulation'
      sleep 1
      exit 0
      """
    do { try recoveryScript.write(to: directory.appendingPathComponent("login.sh"), atomically: true, encoding: .utf8) }
    catch { failures.append("recovery login script could not be saved") }
    await responses.set(.success)
    click("connection-primary", in: coordinator.panel)
    await settle { store.canReopenLoginBrowser(.anthropic) }
    expect(store.canReopenLoginBrowser(.anthropic) && coordinator.phase == .signingIn,
      "failed permission retried the inaccessible item instead of opening fresh sign-in")
    expect(lastOpenedBrowserURL?.query?.contains("localhost") == true,
      "Claude simulation opened the manual-code fallback instead of the browser callback")
    expect(openedBrowserCount == 1, "Claude simulation opened duplicate browser links")
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected, "fresh sign-in did not verify usage after failed permission")
    expect(store.states[.anthropic]?.snapshot?.windows.first?.usedPercent == 20,
      "Claude simulation did not return its expected usage data")
    coordinator.panel?.markAsSimulation()
    do { try coordinator.panel?.render(to: evidence.appendingPathComponent("claude-simulation-connected.png")) }
    catch { failures.append("Claude simulation evidence could not be saved") }
    coordinator.close()
    openedBrowserCount = 0

    let resumeTime = Date()
    var staleConnection = ProviderViewState(provider: .grok)
    staleConnection.error = "Sign-in needed"
    expect(!UsageStore.resumeRefreshNeeded(states: [staleConnection], intervalMinutes: 30,
      isRefreshingAll: false, lastCompletedAt: resumeTime.addingTimeInterval(-10), now: resumeTime),
      "switching windows immediately repeated a failed background check")
    expect(UsageStore.resumeRefreshNeeded(states: [staleConnection], intervalMinutes: 30,
      isRefreshingAll: false, lastCompletedAt: resumeTime.addingTimeInterval(-61), now: resumeTime),
      "resume retry stayed blocked after the cooldown")
    expect(UsageStore.resumeRefreshNeeded(states: [staleConnection], intervalMinutes: 30,
      isRefreshingAll: false, lastCompletedAt: resumeTime.addingTimeInterval(10), now: resumeTime),
      "clock changes prevented resume checks")

    await responses.set(.accessDenied)
    coordinator.start(.openAI)
    await settle { coordinator.phase == .accessDenied }
    expect(coordinator.phase == .accessDenied, "account permissions were described as a temporary outage")
    coordinator.close()

    await responses.set(.offline)
    coordinator.start(.openAI)
    await settle { coordinator.phase == .unavailable }
    expect(coordinator.phase == .unavailable, "network failure asked for sign-in")
    await responses.set(.success)
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected, "Try again did not recover usage")
    coordinator.close()

    var emptyUsage = ProviderViewState(provider: .openAI)
    emptyUsage.snapshot = UsageSnapshot(provider: .openAI, windows: [], source: "empty fixture")
    expect(ProviderSetupCoordinator.phase(after: emptyUsage) == .unavailable,
      "a fresh response without usable usage was shown as connected")

    // Exercise the real login process, browser handoff, queued verification,
    // and cancellation with a local script and fake provider responses.
    let script = "#!/bin/sh\necho https://auth.openai.com/reserve-test\nsleep 1\nexit 0\n"
    do { try script.write(to: directory.appendingPathComponent("login.sh"), atomically: true, encoding: .utf8) }
    catch { failures.append("mock login script could not be saved") }
    await responses.set(.signedOut)
    coordinator.start(.openAI)
    await settle { store.canReopenLoginBrowser(.openAI) }
    expect(store.canReopenLoginBrowser(.openAI), "browser link was not retained during login")
    expect(coordinator.phase == .signingIn, "opening the browser falsely completed connection")
    click("connection-primary", in: coordinator.panel)
    expect(openedBrowserCount == 2, "Open browser again did not reuse the login URL")
    await responses.set(.success)
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected, "successful login did not wait for fresh usage")
    expect(!store.canReopenLoginBrowser(.openAI), "completed login retained its browser URL")
    coordinator.close()

    await responses.set(.signedOut)
    coordinator.start(.openAI)
    await settle { store.canReopenLoginBrowser(.openAI) }
    let callsBeforeCancellation = await responses.calls
    click("connection-close", in: coordinator.panel)
    await responses.set(.success)
    try? await Task.sleep(for: .milliseconds(1200))
    let callsAfterCancellation = await responses.calls
    expect(coordinator.activeProvider == nil && store.states[.openAI]?.isConnecting == false,
      "cancelled login stayed active")
    expect(!store.canReopenLoginBrowser(.openAI), "cancelled login retained its browser URL")
    expect(callsBeforeCancellation == callsAfterCancellation, "cancelled login started a late usage check")

    await responses.set(.signedOut)
    coordinator.start(.openAI)
    await settle { store.canReopenLoginBrowser(.openAI) }
    await responses.set(.offline)
    await settle { coordinator.phase == .unavailable }
    expect(coordinator.phase == .unavailable, "login success masked unavailable usage")
    coordinator.close()

    do {
      try "#!/bin/sh\nexit 1\n".write(
        to: directory.appendingPathComponent("login.sh"), atomically: true, encoding: .utf8)
    } catch { failures.append("failed-login fixture could not be saved") }
    await responses.set(.signedOut)
    coordinator.start(.openAI)
    await settle { coordinator.phase == .needsSignIn }
    try? await Task.sleep(for: .milliseconds(120))
    expect(coordinator.phase == .needsSignIn && store.states[.openAI]?.isConnecting == false,
      "failed login retried automatically instead of offering an explicit retry")
    coordinator.close()

    // Cursor prints a storage error but exits zero. Also cover a successful
    // exit whose subsequent status check still finds no saved session.
    for diagnostic in ["Failed to store authentication tokens. Please try again.", ""] {
      let cursorScript = "#!/bin/sh\necho https://cursor.com/loginDeepControl?challenge=test\nsleep 0.1\necho '\(diagnostic)'\nexit 0\n"
      do { try cursorScript.write(to: directory.appendingPathComponent("login.sh"), atomically: true, encoding: .utf8) }
      catch { failures.append("Cursor storage failure fixture could not be saved") }
      await responses.set(.signedOut)
      let beforeCursorLogin = openedBrowserCount
      coordinator.start(.cursor)
      await settle { coordinator.phase == .signInNotSaved }
      expect(coordinator.phase == .signInNotSaved && store.loginFailedToSave(.cursor),
        "Cursor storage failure returned to browser sign-in instead of explaining the Mac problem")
      expect(openedBrowserCount == beforeCursorLogin + 1 && store.states[.cursor]?.isConnecting == false,
        "Cursor storage failure retried login or stayed busy")
      coordinator.close()
      expect(coordinator.panel == nil, "Cursor failed-login window did not close")
    }

    // A pending response must not repopulate a disconnected account or cache.
    await responses.set(.slowSuccess)
    coordinator.start(.cursor)
    await settle { store.states[.cursor]?.isRefreshing == true }
    try? await Task.sleep(for: .milliseconds(50))
    store.disconnect(.cursor)
    try? await Task.sleep(for: .milliseconds(350))
    expect(!store.isEnabled(.cursor) && store.states[.cursor]?.snapshot == nil
      && store.states[.cursor]?.localUsage == nil && !store.cursorKeychainReadAllowed,
      "late response restored a disconnected account")
    let saved = await cache.load()
    expect(saved[.cursor] == nil, "disconnected account survived in the snapshot cache")
    expect(coordinator.activeProvider == nil, "disconnect left the connection window open")

    // A provider that ignores normal termination must not survive Cancel.
    let stubborn = Process()
    stubborn.executableURL = URL(fileURLWithPath: "/bin/sh")
    stubborn.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
    stubborn.standardInput = FileHandle.nullDevice
    stubborn.standardOutput = FileHandle.nullDevice
    stubborn.standardError = FileHandle.nullDevice
    do {
      try stubborn.run()
      try? await Task.sleep(for: .milliseconds(80))
      ProcessRunner.stop(stubborn)
      await settle { !stubborn.isRunning }
      expect(!stubborn.isRunning, "cancelled provider survived SIGTERM escalation")
      if stubborn.isRunning { ProcessRunner.stop(stubborn) }
    } catch { failures.append("could not launch the cancellation fixture") }

    // Render actual native controls for each step, with no real credentials.
    let preview = ProviderConnectionPanel(provider: .anthropic)
    defer { preview.close() }
    for (name, phase) in [
      ("setup", ProviderSetupCoordinator.Phase.needsInstall),
      ("browser", .signingIn), ("permission", .needsAccess),
      ("connected", .connected), ("unavailable", .unavailable), ("access-denied", .accessDenied),
    ] {
      preview.update(phase: phase, canReopenBrowser: true)
      preview.markAsSimulation()
      preview.show()
      try? await Task.sleep(for: .milliseconds(50))
      if let root = preview.contentView {
        for field in LifecycleSelfTest.descendants(of: root).compactMap({ $0 as? NSTextField }) {
          let cellHeight = field.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: field.bounds.width, height: 1000)).height ?? 0
          expect(cellHeight <= field.bounds.height + 1, "\(name) text is clipped")
          expect(root.bounds.contains(field.convert(field.bounds, to: root)), "\(name) text exceeds window")
        }
      }
      do { try preview.render(to: evidence.appendingPathComponent("\(name).png")) }
      catch { failures.append("\(name) screenshot could not be saved") }
    }
    return failures
  }

  private static func click(_ identifier: String, in panel: ProviderConnectionPanel?) {
    guard let root = panel?.contentView else { return }
    let button = LifecycleSelfTest.descendants(of: root).compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == identifier }
    button?.performClick(nil)
  }

  private static func settle(until condition: () -> Bool) async {
    for _ in 0..<150 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}

private actor ConnectionTestResponses {
  enum Mode { case success, missingHelper, permission, deniedPermission, offline, signedOut, slowSuccess, slowPermission, accessDenied }
  private var mode: Mode = .success
  private(set) var calls = 0

  func set(_ mode: Mode) { self.mode = mode }

  func fetch(_ provider: ProviderID, allowAccess: Bool) async throws -> UsageSnapshot {
    self.calls += 1
    switch self.mode {
    case .missingHelper: throw UsageProviderError.executableNotFound("test helper")
    case .slowPermission:
      if !allowAccess {
        try? await Task.sleep(for: .milliseconds(200))
        throw UsageProviderError.keychainConsentRequired(provider)
      }
    case .permission:
      if !allowAccess { throw UsageProviderError.keychainConsentRequired(provider) }
    case .deniedPermission: throw UsageProviderError.keychainConsentRequired(provider)
    case .offline: throw UsageProviderError.unavailable("offline fixture")
    case .accessDenied: throw UsageProviderError.accessDenied("denied fixture")
    case .signedOut: throw UsageProviderError.unauthorized("expired fixture")
    case .slowSuccess: try? await Task.sleep(for: .milliseconds(250))
    case .success: break
    }
    return UsageSnapshot(provider: provider, planName: "Pro", windows: [
      UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20,
        windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86400)),
    ], source: "isolated connection test")
  }
}
#endif
