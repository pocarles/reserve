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
      // The shim is written at runtime into the private directory, so a
      // running Reserve whose app bundle was deleted can still sign in.
      expect(Bundle.reserveResources?.url(forResource: "ClaudeLoginBrowser", withExtension: "sh") == nil,
        "the Claude browser shim is still shipped as a bundle resource")
      expect(URL(fileURLWithPath: pipe.browserExecutable).deletingLastPathComponent().standardizedFileURL
        == pipe.directory.standardizedFileURL,
        "the Claude browser shim was not written into the private sign-in directory")
      expect(ClaudeLoginBrowserPipe.isPrivate(pipe.directory.path, type: S_IFDIR)
        && ClaudeLoginBrowserPipe.isPrivate(pipe.browserExecutable, type: S_IFREG),
        "the Claude browser shim or its directory is not owned by this user with mode 0700")
      expect((try? String(contentsOfFile: pipe.browserExecutable, encoding: .utf8))
        == ClaudeLoginBrowserPipe.browserScript, "the Claude browser shim was not written intact")
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
    var browserOpens = true
    var loginCommands: [ProviderID] = []
    // The helper Reserve launches for sign-in. A path that does not exist
    // stands in for a deleted or broken installation.
    var loginExecutable = "/bin/sh"
    // Plan keys live in memory here, so no real Keychain item is written.
    var savedPlanKeys: [ProviderID: String] = [:]
    let memoryKeys = PlanKeyStorage(
      hasKey: { savedPlanKeys[$0] != nil },
      save: { key, provider in
        guard key.count >= 16 else {
          throw UsageProviderError.credentialsNotFound("\(provider.displayName) needs a single-line API key.")
        }
        savedPlanKeys[provider] = key
      },
      delete: { savedPlanKeys[$0] = nil })
    let store = UsageStore(
      defaults: defaults, startAutomatically: false, cache: cache,
      fetchOverride: { provider, allowAccess in
        try await responses.fetch(provider, allowAccess: allowAccess)
      },
      loginCommandOverride: { provider in
        loginCommands.append(provider)
        return (loginExecutable, [directory.appendingPathComponent("login.sh").path])
      },
      openLoginURL: { url in openedBrowserCount += 1; lastOpenedBrowserURL = url; return browserOpens },
      planKeys: memoryKeys)
    let coordinator = ProviderSetupCoordinator(store: store)
    defer { coordinator.close() }

    // Key-connected plans: off by default, connected by pasting a key, never
    // through a helper, CLI sign-in, browser or Keychain-consent prompt.
    for provider in [ProviderID.zai, .kimi] {
      expect(!store.isEnabled(provider), "\(provider.displayName) did not start disabled")
      expect(AllowanceBuilder.setupAction(for: ProviderViewState(provider: provider)) == .addKey,
        "\(provider.displayName) offered a sign-in or install instead of a key")
      var rejected = ProviderViewState(provider: provider)
      rejected.requiresConnection = true
      rejected.error = "rejected fixture"
      expect(ProviderSetupCoordinator.phase(after: rejected) == .needsKey,
        "a rejected \(provider.displayName) key did not ask for a new key")

      await responses.set(.success)
      coordinator.start(provider)
      expect(coordinator.phase == .needsKey && coordinator.panel?.isVisible == true,
        "\(provider.displayName) did not ask for an API key")
      let keyField = coordinator.panel?.contentView.flatMap { root in
        LifecycleSelfTest.descendants(of: root).compactMap { $0 as? NSSecureTextField }
          .first { $0.identifier?.rawValue == "connection-key" }
      }
      expect(keyField != nil && keyField?.isHiddenOrHasHiddenAncestor == false,
        "\(provider.displayName) key field is not a visible secure field")
      keyField?.stringValue = "short"
      click("connection-primary", in: coordinator.panel)
      expect(coordinator.phase == .needsKey && savedPlanKeys[provider] == nil,
        "an invalid \(provider.displayName) key was accepted")
      keyField?.stringValue = "test-\(provider.rawValue)-key-0123456789"
      click("connection-primary", in: coordinator.panel)
      await settle { coordinator.activeProvider == nil }
      expect(coordinator.activeProvider == nil && store.isEnabled(provider)
        && store.states[provider]?.snapshot != nil && savedPlanKeys[provider] != nil,
        "saving a \(provider.displayName) key did not connect it")
      expect(keyField?.stringValue.isEmpty == true, "the pasted key stayed in the field")

      // A rejected key reopens the key prompt rather than a browser sign-in.
      await responses.set(.signedOut)
      coordinator.start(provider)
      await settle { coordinator.phase == .needsKey }
      expect(coordinator.phase == .needsKey && coordinator.panel?.isVisible == true,
        "a rejected \(provider.displayName) key did not ask for a replacement")
      // A replacement that is rejected too, then abandoned, must not stay in
      // Keychain.
      keyField?.stringValue = "test-\(provider.rawValue)-rejected-0123456789"
      click("connection-primary", in: coordinator.panel)
      await settle { coordinator.phase == .needsKey }
      expect(savedPlanKeys[provider] != nil, "a rejected \(provider.displayName) key was not checked")
      click("connection-close", in: coordinator.panel)
      expect(coordinator.activeProvider == nil && savedPlanKeys[provider] == nil
        && !store.hasPlanKey(provider),
        "a rejected \(provider.displayName) key stayed in Keychain after Cancel")

      store.removePlanKey(provider)
      expect(!store.isEnabled(provider) && store.states[provider]?.snapshot == nil
        && savedPlanKeys[provider] == nil && !store.hasPlanKey(provider),
        "removing the \(provider.displayName) key did not disconnect it")
      // Disconnect rewrites the cache in the background.
      var cached = await cache.load()
      for _ in 0..<50 where cached[provider] != nil {
        try? await Task.sleep(for: .milliseconds(20))
        cached = await cache.load()
      }
      expect(cached[provider] == nil, "a removed \(provider.displayName) key left a cached snapshot")
    }
    expect(loginCommands.isEmpty && openedBrowserCount == 0,
      "a key-connected plan started a CLI sign-in or opened a browser")
    expect(!store.keychainReadAllowed(for: .zai) && !store.keychainReadAllowed(for: .kimi),
      "a key-connected plan was granted Claude/Cursor Keychain consent")

    // A manually installed helper starts disabled, and a failed refresh must
    // keep the last good snapshot while disconnect clears it.
    expect(!store.isEnabled(.copilot), "Copilot did not start disabled")
    await responses.set(.success)
    store.setEnabled(.copilot, enabled: true, refreshImmediately: false)
    store.refresh(.copilot)
    await settle { store.states[.copilot]?.isRefreshing == false }
    let copilotSnapshot = store.states[.copilot]?.snapshot
    expect(copilotSnapshot != nil, "an enabled provider did not load usage from its fixture")
    await responses.set(.offline)
    store.refresh(.copilot)
    await settle { store.states[.copilot]?.isRefreshing == false }
    expect(store.states[.copilot]?.snapshot == copilotSnapshot && store.states[.copilot]?.error != nil,
      "a failed refresh discarded the last good snapshot")
    store.disconnect(.copilot)
    expect(!store.isEnabled(.copilot) && store.states[.copilot]?.snapshot == nil,
      "disconnect did not clear the cached snapshot")

    await responses.set(.missingHelper)
    coordinator.start(.openAI)
    await settle { coordinator.phase == .needsInstall }
    expect(coordinator.phase == .needsInstall, "missing helper did not offer installation")
    expect(coordinator.panel?.isVisible == true, "connection window is not visible")
    let window = coordinator.panel
    coordinator.start(.cursor)
    expect(coordinator.panel === window && coordinator.activeProvider == .openAI,
      "overlapping connections created a second flow")
    expect(coordinator.panel?.isVisible == true
      && visibleText("connection-detail", in: coordinator.panel)?.contains("Finish or cancel it, then connect Cursor") == true,
      "Connect for another provider was silently dropped while a connection was active")

    // (6) An installer failure keeps its own reason instead of a generic hint.
    do {
      let failingInstaller = ProviderHelperInstaller(session: FailingInstallerProtocol.session())
      let installCoordinator = ProviderSetupCoordinator(store: store, installer: failingInstaller)
      click("connection-close", in: coordinator.panel)
      installCoordinator.start(.openAI)
      await settle { installCoordinator.phase == .needsInstall }
      click("connection-primary", in: installCoordinator.panel)
      await settle { installCoordinator.phase == .failed }
      let reason = visibleText("connection-detail", in: installCoordinator.panel)
      expect(installCoordinator.phase == .failed && reason?.contains("could not be downloaded") == true,
        "an installer failure hid its reason behind a generic message")
      expect(text("connection-message", in: installCoordinator.panel)?.contains("Check your connection") == false,
        "an installer failure with a reason still blamed the connection")
      installCoordinator.close()
      coordinator.start(.openAI)
      await settle { coordinator.phase == .needsInstall }
    }
    click("connection-close", in: coordinator.panel)
    expect(coordinator.activeProvider == nil, "Cancel did not dismiss setup")

    await responses.set(.permission)
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsAccess }
    let accessWindow = coordinator.panel
    expect(coordinator.phase == .needsAccess, "permission was presented as expired login")
    click("connection-primary", in: accessWindow)
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected && coordinator.activeProvider == nil
      && accessWindow?.isVisible != true,
      "a verified connection kept a window open instead of finishing quietly")
    expect(openedBrowserCount == 0, "existing sign-in unnecessarily opened a browser")

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
    expect(store.claudeKeychainReadAllowed, "a temporary macOS denial erased saved consent")
    // A denial is answered by asking again, never by a fresh sign-in, which
    // would replace the Claude Code sign-in on this Mac.
    let launchesBeforeDenial = store.loginLaunchCount(for: .anthropic)
    expect(coordinator.panel?.isVisible == true
      && buttonTitle("connection-primary", in: coordinator.panel) == "Allow usage access",
      "a macOS denial did not offer to allow usage access again")
    expect(visibleText("connection-detail", in: coordinator.panel) == nil,
      "the access window repeated the consent request as an error")
    coordinator.panel?.markAsSimulation()
    do { try coordinator.panel?.render(to: evidence.appendingPathComponent("claude-simulation-access-not-allowed.png")) }
    catch { failures.append("Claude simulation evidence could not be saved") }
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .accessNotGranted }
    expect(coordinator.phase == .accessNotGranted
      && store.loginLaunchCount(for: .anthropic) == launchesBeforeDenial,
      "Allow usage access after a denial started a sign-in instead of asking again")
    // Turning access off in Settings mid-check must not land on a sign-in.
    await responses.set(.slowDeniedPermission)
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .grantingAccess }
    store.claudeKeychainReadAllowed = false
    await settle { coordinator.phase == .accessNotGranted }
    expect(coordinator.phase == .accessNotGranted
      && buttonTitle("connection-primary", in: coordinator.panel) == "Allow usage access"
      && store.loginLaunchCount(for: .anthropic) == launchesBeforeDenial,
      "turning access off mid-check offered a sign-in")
    coordinator.close()

    // Only a saved sign-in that is readable but unusable leads to a fresh
    // sign-in, and Claude's window says it replaces the CLI's sign-in first.
    await responses.set(.unusableSavedSignIn)
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsAccess }
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .needsSignIn }
    expect(coordinator.phase == .needsSignIn && coordinator.panel?.isVisible == true
      && store.loginLaunchCount(for: .anthropic) == launchesBeforeDenial,
      "an unusable Claude sign-in started a fresh login without asking first")
    expect(text("connection-privacy", in: coordinator.panel)?
      .contains("replaces the Claude Code sign-in on this Mac") == true,
      "Claude sign-in did not warn that it replaces the Claude Code sign-in")
    coordinator.panel?.markAsSimulation()
    do { try coordinator.panel?.render(to: evidence.appendingPathComponent("claude-simulation-sign-in-again.png")) }
    catch { failures.append("Claude simulation evidence could not be saved") }
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
      "an unusable saved sign-in did not open a fresh sign-in")
    expect(coordinator.panel?.isVisible != true,
      "the sign-in window stayed open while the browser sign-in was in progress")
    expect(lastOpenedBrowserURL?.query?.contains("localhost") == true,
      "Claude simulation opened the manual-code fallback instead of the browser callback")
    expect(openedBrowserCount == 1, "Claude simulation opened duplicate browser links")
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected, "fresh sign-in did not verify usage after an unusable sign-in")
    expect(store.states[.anthropic]?.snapshot?.windows.first?.usedPercent == 20,
      "Claude simulation did not return its expected usage data")
    coordinator.close()
    openedBrowserCount = 0

    // (1) A sign-in that cannot even launch explains why, and its button
    // re-checks the installation instead of repeating the launch.
    loginExecutable = directory.appendingPathComponent("missing-helper").path
    await responses.set(.signedOut)
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsSignIn }
    let launchesBeforeFailure = store.loginLaunchCount(for: .anthropic)
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .signInCouldNotStart }
    expect(store.loginLaunchCount(for: .anthropic) == launchesBeforeFailure + 1,
      "the failing sign-in launch fixture was not attempted exactly once")
    let launchesAfterFailure = store.loginLaunchCount(for: .anthropic)
    expect(coordinator.phase == .signInCouldNotStart && coordinator.panel?.isVisible == true,
      "a sign-in that could not start was presented as an unfinished sign-in")
    expect(visibleText("connection-detail", in: coordinator.panel)?
      .contains("Could not start Claude Code sign-in") == true,
      "the window hid why the sign-in could not start")
    expect(buttonTitle("connection-primary", in: coordinator.panel) == "Try again"
      && text("connection-privacy", in: coordinator.panel)?.contains("reinstall Reserve") == true,
      "a sign-in that could not start did not offer repair guidance")
    expect(store.states[.anthropic]?.signInCouldNotStart == true,
      "the dashboard cannot tell a failed launch from an unfinished sign-in")
    coordinator.panel?.markAsSimulation()
    do { try coordinator.panel?.render(to: evidence.appendingPathComponent("claude-simulation-could-not-start.png")) }
    catch { failures.append("Claude simulation evidence could not be saved") }
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .signInCouldNotStart }
    expect(coordinator.phase == .signInCouldNotStart
      && store.loginLaunchCount(for: .anthropic) == launchesAfterFailure
      && store.states[.anthropic]?.isConnecting == false,
      "Try again relaunched a sign-in that could not start")
    loginExecutable = "/bin/sh"
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.phase == .needsSignIn }
    expect(coordinator.phase == .needsSignIn
      && buttonTitle("connection-primary", in: coordinator.panel) == "Continue in browser"
      && store.loginLaunchCount(for: .anthropic) == launchesAfterFailure,
      "a repaired installation did not return to an explicit sign-in")
    coordinator.close()

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
    expect(coordinator.panel?.isVisible != true,
      "an opened browser sign-in showed a window that only asked to wait")
    coordinator.start(.openAI)
    expect(openedBrowserCount == 2, "Connect during a pending sign-in did not reopen the login page")
    expect(coordinator.panel?.isVisible != true, "reopening the login page showed a window")
    await responses.set(.success)
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected, "successful login did not wait for fresh usage")
    expect(coordinator.activeProvider == nil, "a finished sign-in kept its connection window")
    expect(!store.canReopenLoginBrowser(.openAI), "completed login retained its browser URL")
    coordinator.close()

    // A browser that cannot open is the one sign-in problem that needs a
    // window, and that window is where Cancel lives.
    browserOpens = false
    await responses.set(.signedOut)
    coordinator.start(.openAI)
    await settle { store.loginBrowserFailedToOpen(.openAI) }
    expect(coordinator.phase == .signingIn && coordinator.panel?.isVisible == true,
      "a browser that failed to open was not reported in a window")
    browserOpens = true
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
    expect(visibleText("connection-detail", in: coordinator.panel)?.contains("sign-in was not completed") == true,
      "a failed sign-in did not show its reason")
    coordinator.close()

    // A helper can report an error after the account was already connected in
    // the browser. Usage decides whether the sign-in finished, not the exit
    // status, and the browser must not open a second time to prove it.
    do {
      try "#!/bin/sh\necho https://auth.openai.com/reserve-test\nsleep 1\nexit 1\n".write(
        to: directory.appendingPathComponent("login.sh"), atomically: true, encoding: .utf8)
    } catch { failures.append("verified-login fixture could not be saved") }
    await responses.set(.signedOut)
    openedBrowserCount = 0
    coordinator.start(.openAI)
    await settle { store.canReopenLoginBrowser(.openAI) }
    await responses.set(.success)
    await settle { coordinator.phase == .connected }
    expect(coordinator.phase == .connected && openedBrowserCount == 1,
      "a completed sign-in was discarded because its helper exited with an error")
    expect(store.states[.openAI]?.requiresConnection == false
      && store.states[.openAI]?.isConnecting == false
      && store.states[.openAI]?.error == nil,
      "verified sign-in left the account marked as unfinished")
    coordinator.close()
    openedBrowserCount = 0

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

    failures += await self.checkRefreshScheduling(in: directory)
    failures += await self.checkLoginHandoff(in: directory)
    failures += await self.checkEarlyCompletions(in: directory)
    failures += self.checkPhaseTable()

    // Render actual native controls for each step, with no real credentials.
    let preview = ProviderConnectionPanel(provider: .anthropic)
    defer { preview.close() }
    for (name, phase) in [
      ("setup", ProviderSetupCoordinator.Phase.needsInstall),
      ("browser", .signingIn), ("permission", .needsAccess),
      ("unavailable", .unavailable), ("access-denied", .accessDenied),
      ("access-not-allowed", .accessNotGranted), ("could-not-start", .signInCouldNotStart),
      ("sign-in-first", .needsSignIn), ("failed", .failed),
    ] {
      preview.update(phase: phase, canReopenBrowser: true,
        detail: phase == .signingIn || phase == .needsAccess ? nil
          : "Could not start Claude Code sign-in: Reserve could not prepare its browser handoff.")
      preview.markAsSimulation()
      preview.show()
      try? await Task.sleep(for: .milliseconds(50))
      if let root = preview.contentView {
        for field in LifecycleSelfTest.descendants(of: root).compactMap({ $0 as? NSTextField })
        where !field.isHiddenOrHasHiddenAncestor {
          let cellHeight = field.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: field.bounds.width, height: 1000)).height ?? 0
          expect(cellHeight <= field.bounds.height + 1, "\(name) text is clipped")
          expect(root.bounds.contains(field.convert(field.bounds, to: root)), "\(name) text exceeds window")
        }
      }
      do { try preview.render(to: evidence.appendingPathComponent("\(name).png")) }
      catch { failures.append("\(name) screenshot could not be saved") }
    }
    let keyPreview = ProviderConnectionPanel(provider: .kimi)
    defer { keyPreview.close() }
    for (name, phase) in [
      ("kimi-key", ProviderSetupCoordinator.Phase.needsKey), ("kimi-checking", .savingKey),
    ] {
      keyPreview.update(phase: phase)
      keyPreview.show()
      try? await Task.sleep(for: .milliseconds(50))
      if let root = keyPreview.contentView {
        for field in LifecycleSelfTest.descendants(of: root).compactMap({ $0 as? NSTextField })
        where !field.isHiddenOrHasHiddenAncestor {
          expect(root.bounds.contains(field.convert(field.bounds, to: root)), "\(name) text exceeds window")
        }
      }
      do { try keyPreview.render(to: evidence.appendingPathComponent("\(name).png")) }
      catch { failures.append("\(name) screenshot could not be saved") }
    }
    let manualPreview = ProviderConnectionPanel(provider: .copilot)
    defer { manualPreview.close() }
    for (name, phase) in [
      ("copilot-install", ProviderSetupCoordinator.Phase.needsInstall),
      ("copilot-manual-setup", .waitingForManualSetup), ("copilot-unavailable", .unavailable),
    ] {
      manualPreview.update(phase: phase)
      manualPreview.show()
      try? await Task.sleep(for: .milliseconds(50))
      if let root = manualPreview.contentView {
        for field in LifecycleSelfTest.descendants(of: root).compactMap({ $0 as? NSTextField }) {
          let cellHeight = field.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: field.bounds.width, height: 1000)).height ?? 0
          expect(cellHeight <= field.bounds.height + 1, "\(name) text is clipped")
          expect(root.bounds.contains(field.convert(field.bounds, to: root)), "\(name) text exceeds window")
        }
      }
      do { try manualPreview.render(to: evidence.appendingPathComponent("\(name).png")) }
      catch { failures.append("\(name) screenshot could not be saved") }
    }
    return failures
  }

  /// These stores have isolated preferences/cache and a synthetic fetcher.
  /// No login helper, provider request, or real session history is involved.
  private static func checkRefreshScheduling(in directory: URL) async -> [String] {
    var failures: [String] = []
    for scenario in ["interactive-sweep", "bounded-sweep", "history-cleared"] {
      let suite = "Reserve.SchedulingSelfTest.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suite) else {
        failures.append("\(scenario): isolated preferences unavailable")
        continue
      }
      defer { defaults.removePersistentDomain(forName: suite) }
      let cache = SnapshotCache(fileURL: directory.appendingPathComponent("\(scenario).json"))
      let probe = ConnectionSchedulingProbe(historyThenNone: scenario == "history-cleared")
      let store = UsageStore(
        defaults: defaults, startAutomatically: false, notificationsActive: false, cache: cache,
        fetchOverride: { provider, allowAccess in
          try await probe.fetch(provider, allowAccess: allowAccess)
        },
        openLoginURL: { _ in failures.append("\(scenario): unexpectedly opened sign-in"); return false })
      for provider in ProviderID.allCases {
        store.setEnabled(provider, enabled: false, refreshImmediately: false)
      }
      if scenario == "interactive-sweep" {
        store.setEnabled(.cursor, enabled: true, refreshImmediately: false)
        var completions = 0
        store.allowKeychainAccess(for: .cursor) { completions += 1 }
        for _ in 0..<100 {
          if await probe.stats().total > 0 { break }
          try? await Task.sleep(for: .milliseconds(10))
        }
        store.refreshAll()
        await settle { !store.isRefreshingAll && store.states[.cursor]?.isRefreshing == false }
        let stats = await probe.stats()
        if stats.total != 1 || stats.interactive != 1 || stats.cancelled != 0 {
          failures.append("scheduled sweep interrupted or duplicated an explicit access check")
        }
        if completions != 1 || store.states[.cursor]?.isConnecting != false
          || store.states[.cursor]?.snapshot == nil {
          failures.append("explicit access did not finish cleanly while a sweep waited")
        }
      } else if scenario == "bounded-sweep" {
        let enabled: Set<ProviderID> = [.openAI, .grok, .cursor, .copilot, .zai, .kimi]
        for provider in enabled {
          store.setEnabled(provider, enabled: true, refreshImmediately: false)
        }
        store.refreshAll()
        await settle { !store.isRefreshingAll }
        let stats = await probe.stats()
        if stats.maximumActive != 2 || stats.total != enabled.count
          || Set(stats.providers) != enabled || stats.cancelled != 0 {
          failures.append("idle sweep did not check exactly the enabled providers with two concurrent fetches")
        }
        if enabled.contains(where: { store.states[$0]?.snapshot == nil
          || store.states[$0]?.isRefreshing != false }) {
          failures.append("bounded sweep left an enabled provider unfinished")
        }
      } else {
        store.setEnabled(.cursor, enabled: true, refreshImmediately: false)
        store.refresh(.cursor)
        await settle { store.states[.cursor]?.isRefreshing == false }
        if store.states[.cursor]?.localUsage?.origin != .providerAccount {
          failures.append("account-history fixture did not populate Insights")
        }
        store.refresh(.cursor)
        await settle { store.states[.cursor]?.isRefreshing == false }
        let saved = await cache.load()
        if store.states[.cursor]?.snapshot?.accountUsage != nil
          || store.states[.cursor]?.localUsage != nil || saved[.cursor]?.accountUsage != nil {
          failures.append("account history survived a newer snapshot without account history")
        }
      }
      for provider in ProviderID.allCases { store.cancelConnection(provider) }
    }
    return failures
  }

  /// A helper that prints nothing must not leave the person waiting without
  /// a window, and Claude falls back to a trusted stdout URL only after its
  /// `$BROWSER` handoff has missed the deadline. Short deadline, local scripts,
  /// synthetic usage: no real helper, browser or account is involved.
  private static func checkLoginHandoff(in directory: URL) async -> [String] {
    var failures: [String] = []
    func expect(_ value: Bool, _ message: String) {
      if !value { failures.append(message) }
    }
    let suite = "Reserve.HandoffSelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["handoff: isolated preferences unavailable"] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let script = directory.appendingPathComponent("handoff-login.sh")
    let responses = ConnectionTestResponses()
    var opened: [URL] = []
    let store = UsageStore(
      defaults: defaults, startAutomatically: false, notificationsActive: false,
      cache: SnapshotCache(fileURL: directory.appendingPathComponent("handoff.json")),
      fetchOverride: { provider, allowAccess in try await responses.fetch(provider, allowAccess: allowAccess) },
      loginCommandOverride: { _ in ("/bin/sh", [script.path]) },
      openLoginURL: { opened.append($0); return true },
      planKeys: PlanKeyStorage(hasKey: { _ in false }, save: { _, _ in }, delete: { _ in }),
      loginHandoffDeadline: .milliseconds(300))
    let coordinator = ProviderSetupCoordinator(store: store)
    defer { coordinator.close() }

    // Nothing from the helper at first: the window comes back and says so,
    // then offers the browser again once the page does arrive.
    do {
      try "#!/bin/sh\nsleep 1\necho https://auth.openai.com/reserve-late\nsleep 2\n".write(
        to: script, atomically: true, encoding: .utf8)
    } catch { return ["handoff: login fixture could not be saved"] }
    await responses.set(.signedOut)
    coordinator.start(.openAI)
    await settle { store.states[.openAI]?.isConnecting == true }
    expect(coordinator.phase == .signingIn && coordinator.panel?.isVisible != true,
      "handoff: the sign-in window appeared before the deadline")
    await settle { coordinator.panel?.isVisible == true }
    expect(coordinator.phase == .signingIn && coordinator.panel?.isVisible == true
      && text("connection-message", in: coordinator.panel) == "Waiting for Codex to open the sign-in page…",
      "handoff: a helper that opened nothing left the person waiting without a window")
    expect(buttonVisible("connection-close", in: coordinator.panel),
      "handoff: the waiting window offered no way to cancel")
    coordinator.panel?.markAsSimulation()
    let evidence = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-connection-review", isDirectory: true)
    try? coordinator.panel?.render(to: evidence.appendingPathComponent("waiting-for-helper.png"))
    await settle { store.canReopenLoginBrowser(.openAI) }
    expect(opened.last?.absoluteString == "https://auth.openai.com/reserve-late"
      && coordinator.panel?.isVisible == true
      && buttonTitle("connection-primary", in: coordinator.panel) == "Open browser again",
      "handoff: a late sign-in page did not offer Open browser again")
    coordinator.close()

    // Claude's pipe never receives a URL; a trusted stdout URL is used, but
    // only after the deadline.
    opened.removeAll()
    do {
      try "#!/bin/sh\necho 'https://claude.ai/oauth/authorize?state=stdout-only'\nsleep 3\n".write(
        to: script, atomically: true, encoding: .utf8)
    } catch { return failures + ["handoff: Claude fixture could not be saved"] }
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsSignIn }
    click("connection-primary", in: coordinator.panel)
    try? await Task.sleep(for: .milliseconds(120))
    expect(opened.isEmpty, "handoff: Claude used stdout before its browser handoff deadline")
    await settle { !opened.isEmpty }
    expect(opened.first?.absoluteString == "https://claude.ai/oauth/authorize?state=stdout-only"
      && opened.count == 1 && store.canReopenLoginBrowser(.anthropic),
      "handoff: Claude ignored a trusted stdout URL after its browser handoff missed the deadline")
    coordinator.close()

    // An untrusted stdout URL is still never opened.
    opened.removeAll()
    do {
      try "#!/bin/sh\necho 'https://claude.ai.example.org/oauth/authorize'\nsleep 2\n".write(
        to: script, atomically: true, encoding: .utf8)
    } catch { return failures + ["handoff: untrusted fixture could not be saved"] }
    coordinator.start(.anthropic)
    await settle { coordinator.phase == .needsSignIn }
    click("connection-primary", in: coordinator.panel)
    await settle { coordinator.panel?.isVisible == true && store.loginHandoffIsOverdue(.anthropic) }
    try? await Task.sleep(for: .milliseconds(100))
    expect(opened.isEmpty && store.loginHandoffIsOverdue(.anthropic),
      "handoff: an untrusted stdout URL was opened")
    coordinator.close()
    return failures
  }

  /// Every early return hands back to its caller exactly once, so a window
  /// waiting on it can never stay in a busy step.
  private static func checkEarlyCompletions(in directory: URL) async -> [String] {
    var failures: [String] = []
    let suite = "Reserve.CompletionSelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["completions: isolated preferences unavailable"] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let script = directory.appendingPathComponent("completion-login.sh")
    do { try "#!/bin/sh\nsleep 0.4\nexit 1\n".write(to: script, atomically: true, encoding: .utf8) }
    catch { return ["completions: login fixture could not be saved"] }
    let responses = ConnectionTestResponses()
    await responses.set(.signedOut)
    let store = UsageStore(
      defaults: defaults, startAutomatically: false, notificationsActive: false,
      cache: SnapshotCache(fileURL: directory.appendingPathComponent("completions.json")),
      fetchOverride: { provider, allowAccess in try await responses.fetch(provider, allowAccess: allowAccess) },
      loginCommandOverride: { _ in ("/bin/sh", [script.path]) },
      openLoginURL: { _ in failures.append("completions: unexpectedly opened sign-in"); return false },
      planKeys: PlanKeyStorage(hasKey: { _ in false }, save: { _, _ in }, delete: { _ in }))
    for provider in ProviderID.allCases { store.setEnabled(provider, enabled: false, refreshImmediately: false) }

    var counts: [String: Int] = [:]
    store.refresh(.openAI) { counts["refresh-disabled", default: 0] += 1 }
    store.allowKeychainAccess(for: .openAI) { counts["access-unsupported", default: 0] += 1 }
    store.connect(.zai) { counts["key-disabled", default: 0] += 1 }
    store.connect(.gemini) { counts["terminal-disabled", default: 0] += 1 }
    store.setEnabled(.grok, enabled: true, refreshImmediately: false)
    store.connect(.grok) { counts["login-first", default: 0] += 1 }
    store.connect(.grok) { counts["login-while-running", default: 0] += 1 }
    await settle { counts["login-first"] != nil && counts["login-while-running"] != nil }
    try? await Task.sleep(for: .milliseconds(150))
    for name in ["refresh-disabled", "access-unsupported", "key-disabled", "terminal-disabled",
      "login-first", "login-while-running"] where counts[name] != 1 {
      failures.append("completions: \(name) finished \(counts[name] ?? 0) times instead of once")
    }
    if store.loginLaunchCount(for: .grok) != 1 {
      failures.append("completions: a second Connect launched a second sign-in helper")
    }
    for provider in ProviderID.allCases { store.cancelConnection(provider) }
    return failures
  }

  /// Which window each failed check opens. Built through the same state
  /// update a real refresh applies, one row per `UsageProviderError`.
  private static func checkPhaseTable() -> [String] {
    var failures: [String] = []
    typealias Phase = ProviderSetupCoordinator.Phase
    let table: [(ProviderID, UsageProviderError, Phase)] = [
      (.openAI, .executableNotFound("Codex CLI"), .needsInstall),
      (.openAI, .credentialsNotFound("signed out"), .needsSignIn),
      (.cursor, .keychainConsentRequired(.cursor), .needsAccess),
      (.openAI, .keychainConsentRequired(.anthropic), .needsSignIn),
      (.openAI, .unauthorized("expired"), .needsSignIn),
      (.openAI, .accessDenied("denied"), .accessDenied),
      (.openAI, .updateRequired("old"), .needsUpdate),
      (.openAI, .rateLimited(retryAt: nil), .unavailable),
      (.openAI, .timedOut("usage"), .unavailable),
      (.openAI, .invalidResponse("bad"), .unavailable),
      (.openAI, .unavailable("offline"), .unavailable),
      (.openAI, .processFailed("crashed"), .unavailable),
      (.copilot, .unavailable(CopilotProvider.newerThanSupportedMessage), .unavailable),
      (.zai, .credentialsNotFound("rejected key"), .needsKey),
      (.zai, .unauthorized("rejected key"), .needsKey),
      (.zai, .unavailable("offline"), .unavailable),
    ]
    for (provider, error, expected) in table {
      var state = ProviderViewState(provider: provider)
      UsageStore.applyFailure(error, to: &state)
      let phase = ProviderSetupCoordinator.phase(after: state)
      if phase != expected {
        failures.append("phase table: \(provider.rawValue) \(error) opened \(phase), expected \(expected)")
      }
    }
    var couldNotStart = ProviderViewState(provider: .anthropic)
    couldNotStart.requiresConnection = true
    couldNotStart.signInCouldNotStart = true
    couldNotStart.error = "Could not start Claude Code sign-in"
    if ProviderSetupCoordinator.phase(after: couldNotStart) != .signInCouldNotStart {
      failures.append("phase table: a failed launch was shown as an unfinished sign-in")
    }
    // The dashboard and the window agree that a missing helper comes first.
    var both = ProviderViewState(provider: .grok)
    both.requiresInstallation = true
    both.requiresUpdate = true
    if ProviderSetupCoordinator.phase(after: both) != .needsInstall
      || AllowanceBuilder.setupAction(for: both, connectionToolAvailable: true) != .install
    {
      failures.append("phase table: the dashboard and Connect window disagree on install before update")
    }
    // A newer Copilot protocol is fixed by updating Reserve, not Copilot.
    var newer = ProviderViewState(provider: .copilot)
    UsageStore.applyFailure(
      UsageProviderError.unavailable(CopilotProvider.newerThanSupportedMessage), to: &newer)
    if AllowanceBuilder.setupAction(for: newer, connectionToolAvailable: true) == .update {
      failures.append("phase table: a Copilot protocol newer than Reserve asked for a Copilot update")
    }
    // A sign-in URL in an error never reaches the window.
    if ProviderSetupCoordinator.displayableError(
      "Open https://claude.ai/oauth/authorize?code=secret to continue", provider: .anthropic)?.contains("claude.ai") != false
    {
      failures.append("phase table: an error line could show a sign-in URL")
    }
    return failures
  }

  private static func field(_ identifier: String, in panel: ProviderConnectionPanel?) -> NSTextField? {
    guard let root = panel?.contentView else { return nil }
    return LifecycleSelfTest.descendants(of: root).compactMap { $0 as? NSTextField }
      .first { $0.identifier?.rawValue == identifier }
  }

  private static func text(_ identifier: String, in panel: ProviderConnectionPanel?) -> String? {
    self.field(identifier, in: panel)?.stringValue
  }

  /// The label's text only when it is actually on screen.
  private static func visibleText(_ identifier: String, in panel: ProviderConnectionPanel?) -> String? {
    guard let field = self.field(identifier, in: panel), !field.isHiddenOrHasHiddenAncestor else { return nil }
    return field.stringValue
  }

  private static func button(_ identifier: String, in panel: ProviderConnectionPanel?) -> NSButton? {
    guard let root = panel?.contentView else { return nil }
    return LifecycleSelfTest.descendants(of: root).compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == identifier }
  }

  private static func buttonTitle(_ identifier: String, in panel: ProviderConnectionPanel?) -> String? {
    guard let button = self.button(identifier, in: panel), !button.isHidden else { return nil }
    return button.title
  }

  private static func buttonVisible(_ identifier: String, in panel: ProviderConnectionPanel?) -> Bool {
    self.button(identifier, in: panel).map { !$0.isHiddenOrHasHiddenAncestor } ?? false
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
  enum Mode {
    case success, missingHelper, permission, deniedPermission, offline, signedOut, slowSuccess
    case slowPermission, accessDenied
    /// The protected item can be read once allowed, but holds no usable sign-in.
    case unusableSavedSignIn
    /// The macOS prompt stays up for a while and is then denied.
    case slowDeniedPermission
  }
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
    case .slowDeniedPermission:
      try? await Task.sleep(for: .milliseconds(300))
      throw UsageProviderError.keychainConsentRequired(provider)
    case .unusableSavedSignIn:
      if !allowAccess { throw UsageProviderError.keychainConsentRequired(provider) }
      throw UsageProviderError.credentialsNotFound("The Claude Keychain item does not contain a usable subscription sign-in.")
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
/// Answers every installer download with a server error, so installation
/// fails the way a real outage would without any network request.
private final class FailingInstallerProtocol: URLProtocol, @unchecked Sendable {
  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FailingInstallerProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = self.request.url,
      let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])
    else { return }
    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    self.client?.urlProtocol(self, didLoad: Data())
    self.client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private actor ConnectionSchedulingProbe {
  private let historyThenNone: Bool
  private var total = 0
  private var active = 0
  private var maximumActive = 0
  private var interactive = 0
  private var cancelled = 0
  private var providers: [ProviderID] = []

  init(historyThenNone: Bool) { self.historyThenNone = historyThenNone }

  func stats() -> (total: Int, maximumActive: Int, interactive: Int, cancelled: Int, providers: [ProviderID]) {
    (self.total, self.maximumActive, self.interactive, self.cancelled, self.providers)
  }

  func fetch(_ provider: ProviderID, allowAccess: Bool) async throws -> UsageSnapshot {
    self.total += 1
    let call = self.total
    self.active += 1
    self.maximumActive = max(self.maximumActive, self.active)
    if allowAccess { self.interactive += 1 }
    self.providers.append(provider)
    defer { self.active -= 1 }
    if !self.historyThenNone {
      do { try await Task.sleep(for: .milliseconds(300)) }
      catch { self.cancelled += 1; throw error }
    }
    let usage: LocalUsageSummary? = self.historyThenNone && call == 1
      ? LocalUsageSummary(provider: provider, periodDays: 30, inputTokens: 10,
          outputTokens: 5, apiEquivalentCostUSD: 0.01, origin: .providerAccount)
      : nil
    return UsageSnapshot(provider: provider, planName: "Synthetic plan", windows: [
      UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20,
        windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86400)),
    ], source: "isolated scheduling test", accountUsage: usage)
  }
}

#endif
