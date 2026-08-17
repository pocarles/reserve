import AppKit
import ReserveCore

/// Lifecycle checks that drive real state transitions through the live surfaces.
///
/// The static self-test proves the dashboard is *built* correctly. These checks
/// prove it stays correct while someone uses it: appearance changes reach every
/// open surface, and opening or closing a provider never costs a card.
///
/// Everything here is inspected through the popover's own window, because the
/// controller's view can be right while the window shows something else.
@MainActor
enum LifecycleSelfTest {
  struct Result {
    var failures: [String] = []
    var notes: [String] = []

    mutating func expect(_ condition: Bool, _ description: String) {
      if !condition { self.failures.append(description) }
    }

    var success: Bool { self.failures.isEmpty }
  }

  /// Lets AppKit finish the work a transition schedules. A popover resize and a
  /// view swap both land on the next run-loop turn, so checking before that
  /// would measure a state no person ever sees.
  static func settle(_ seconds: TimeInterval = 0.08) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { self.descendants(of: $0) }
  }

  /// The provider cards the popover window is actually drawing.
  static func visibleCards(in window: NSWindow?) -> [ProviderDashboardCard] {
    guard let root = window?.contentView else { return [] }
    return self.descendants(of: root).compactMap { $0 as? ProviderDashboardCard }
  }

  /// Why a card is reachable, or why it is not.
  ///
  /// The first version of this returned true for anything inside a scroll view,
  /// which excused the exact failure it existed to catch: a card pushed past the
  /// popover's edge sat in a scroll view, so the check passed while the provider
  /// was invisible. Being in a scroll view is not reachability — the card has to
  /// lie within the document's scrollable range, and the scroll view has to
  /// advertise that there is more to see.
  static func unreachableReason(_ card: ProviderDashboardCard, in window: NSWindow) -> String? {
    guard let root = window.contentView else { return "no content view" }
    let frame = card.convert(card.bounds, to: root)
    if root.bounds.insetBy(dx: -1, dy: -1).contains(frame) { return nil }

    guard let scroll = card.enclosingScrollView, let document = scroll.documentView else {
      return "outside the popover with nothing to scroll"
    }
    let inDocument = card.convert(card.bounds, to: document)
    guard inDocument.minY >= -0.5, inDocument.maxY <= document.frame.height + 0.5 else {
      return "outside the scrollable document, so no amount of scrolling reveals it"
    }
    guard document.frame.height > scroll.contentView.bounds.height + 0.5 else {
      return "past the edge but the document is not taller than the viewport"
    }
    // Reachable only if the scroll view says so. An auto-hiding overlay scroller
    // leaves no sign that the column continues.
    guard scroll.hasVerticalScroller, !scroll.autohidesScrollers else {
      return "only reachable by scrolling, with no visible scroller to suggest it"
    }
    return nil
  }

  static func isReachable(_ card: ProviderDashboardCard, in window: NSWindow) -> Bool {
    self.unreachableReason(card, in: window) == nil
  }

  static func providerIdentifier(_ card: ProviderDashboardCard) -> String {
    card.identifier?.rawValue ?? "unknown"
  }

  /// Prints what the popover actually looks like, step by step. Diagnostic
  /// only — it asserts nothing, so it cannot hide a failure behind a passing
  /// condition the way an over-permissive assertion can.
  static func dumpGeometry(
    _ step: String,
    store: UsageStore,
    controller: StatusItemController
  ) {
    guard let window = controller.dashboardWindowForTesting,
      let root = window.contentView
    else {
      print("  \(step): NO WINDOW")
      return
    }
    let screen = window.screen ?? NSScreen.main
    let win: Int = Int(window.frame.height)
    let content: Int = Int(root.frame.height)
    let popoverSize: Int = Int(controller.popoverContentSizeForTesting.height)
    let preferred: Int = Int(controller.dashboardControllerForTesting.preferredContentSize.height)
    let hasScroll: Bool = self.descendants(of: root).contains { $0 is NSScrollView }
    let visible: Int = Int(screen?.visibleFrame.height ?? 0)
    var line = "  \(step)  window=\(win) content=\(content)"
    line += " popoverContentSize=\(popoverSize) preferred=\(preferred)"
    line += " scroll=\(hasScroll) screenVisible=\(visible)"
    print(line)
    for card in self.visibleCards(in: window) {
      let f = card.convert(card.bounds, to: nil)
      let name = self.providerIdentifier(card).replacingOccurrences(
        of: "provider-card-", with: "")
      let insideWindow: Bool = f.minY >= -0.5 && f.maxY <= window.frame.height + 0.5
      let lo: Int = Int(f.minY)
      let hi: Int = Int(f.maxY)
      let h: Int = Int(f.height)
      var cardLine = "      \(name): y=\(lo)..\(hi) h=\(h)"
      if !insideWindow { cardLine += "   <-- OUTSIDE WINDOW" }
      if let scroll = card.enclosingScrollView, let doc = scroll.documentView {
        let inDoc = card.convert(card.bounds, to: doc)
        let maxScroll = max(0, doc.frame.height - scroll.contentView.bounds.height)
        let reachable = inDoc.minY >= -0.5 && inDoc.maxY <= doc.frame.height + 0.5
        cardLine += "  [doc y=\(Int(inDoc.minY))..\(Int(inDoc.maxY))"
        cardLine += " docH=\(Int(doc.frame.height)) maxScroll=\(Int(maxScroll))"
        cardLine += " scrollReachable=\(reachable)]"
      }
      print(cardLine)
    }
  }

  // MARK: - Provider disclosure

  /// Opens and closes every provider, moves directly between two open providers,
  /// and confirms no card is ever lost from the visible dashboard.
  static func checkDisclosure(
    store: UsageStore,
    controller: StatusItemController,
    toggle: (ProviderID) -> Void
  ) -> Result {
    var result = Result()
    guard let window = controller.dashboardWindowForTesting else {
      result.failures.append("popover window was not created")
      return result
    }
    let enabled = ProviderID.allCases.filter { store.isEnabled($0) }

    func audit(_ step: String) {
      self.settle()
      let cards = self.visibleCards(in: window)
      let present = Set(cards.map(self.providerIdentifier))
      let expected = Set(enabled.map { "provider-card-\($0.rawValue)" })
      result.expect(
        present == expected,
        "\(step): visible cards \(present.sorted()) but expected \(expected.sorted())")
      for card in cards {
        if let reason = self.unreachableReason(card, in: window) {
          result.failures.append(
            "\(step): \(self.providerIdentifier(card)) is \(reason)")
        }
      }
      // The window must be able to show the content it was sized for.
      if let root = window.contentView {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 0
        result.notes.append(
          "\(step): content=\(Int(root.frame.height)) window=\(Int(window.frame.height)) "
            + "screenVisible=\(Int(visible))")
        // The popover has to show the dashboard at the height it was laid out
        // for. When it does not, the popover keeps its previous height and the
        // rows past that height are simply not on screen.
        if let dashboard = root as? UsageDashboardView {
          result.expect(
            abs(dashboard.frame.height - dashboard.intendedHeight) < 1,
            "\(step): the dashboard was laid out for \(Int(dashboard.intendedHeight))pt but the "
              + "popover is showing it at \(Int(dashboard.frame.height))pt")
        } else {
          result.failures.append("\(step): the popover is not showing a dashboard")
        }
        // The whole popover has to fit the screen it is on, or the rows past the
        // bottom edge cannot be reached at all.
        result.expect(
          window.frame.height <= visible + 1,
          "\(step): the popover is \(Int(window.frame.height))pt on a screen with "
            + "\(Int(visible))pt available")
      }
    }

    audit("collapsed")
    for provider in enabled {
      let xBeforeExpansion = window.frame.minX
      toggle(provider)
      self.settle()
      result.expect(
        abs(window.frame.minX - xBeforeExpansion) < 0.5,
        "expanding \(provider.rawValue) moved the popover horizontally by "
          + "\(abs(window.frame.minX - xBeforeExpansion))pt")
      result.expect(
        store.expandedProvider == provider,
        "expanding \(provider.rawValue) did not record the expansion")
      audit("expanded \(provider.rawValue)")
      let xBeforeCollapse = window.frame.minX
      toggle(provider)
      self.settle()
      result.expect(
        abs(window.frame.minX - xBeforeCollapse) < 0.5,
        "collapsing \(provider.rawValue) moved the popover horizontally by "
          + "\(abs(window.frame.minX - xBeforeCollapse))pt")
      result.expect(
        store.expandedProvider == nil,
        "collapsing \(provider.rawValue) did not clear the expansion")
      audit("collapsed after \(provider.rawValue)")
    }
    // Straight from one open provider to another, without collapsing first.
    if enabled.count >= 2 {
      toggle(enabled[0])
      audit("open \(enabled[0].rawValue)")
      let xBeforeSwitch = window.frame.minX
      toggle(enabled[1])
      self.settle()
      result.expect(
        abs(window.frame.minX - xBeforeSwitch) < 0.5,
        "switching expanded providers moved the popover horizontally by "
          + "\(abs(window.frame.minX - xBeforeSwitch))pt")
      audit("switched to \(enabled[1].rawValue)")
      result.expect(
        store.expandedProvider == enabled[1],
        "switching between providers did not move the expansion")
      toggle(enabled[1])
      audit("collapsed after switch")
    }
    return result
  }

  /// Selecting a provider changes both the status-item image and its text. The
  /// open popover must keep the same anchor until it closes, otherwise the whole
  /// dashboard visibly jumps sideways under the pointer.
  static func checkProviderSelectionAnchor(
    store: UsageStore,
    controller: StatusItemController
  ) -> Result {
    var result = Result()
    guard let window = controller.dashboardWindowForTesting else {
      result.failures.append("popover window was not created for the provider anchor check")
      return result
    }
    let originalProvider = store.menuBarProvider
    let originalRemaining = store.menuBarShowsRemaining
    defer {
      store.menuBarProvider = originalProvider
      store.menuBarShowsRemaining = originalRemaining
    }
    guard
      let target = ProviderID.allCases.first(where: {
        store.isEnabled($0) && $0 != originalProvider
      }),
      let card = self.visibleCards(in: window).first(where: {
        self.providerIdentifier($0) == "provider-card-\(target.rawValue)"
      })
    else {
      result.failures.append("no alternate provider card was available for the anchor check")
      return result
    }

    let origin = window.frame.origin
    let statusItemLength = controller.statusItemLengthForTesting
    card.selectForMenuBar()
    self.settle(0.15)
    let moved = hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y)
    result.expect(moved < 0.5, "selecting \(target.rawValue) moved the popover by \(moved)pt")
    result.expect(
      controller.statusItemLengthForTesting == statusItemLength,
      "selecting \(target.rawValue) changed the status-item width under the open popover")
    result.expect(
      controller.statusItemProviderForTesting == target,
      "selecting \(target.rawValue) did not update the menu-bar provider immediately")
    result.expect(
      controller.statusItemLengthIsLockedForTesting,
      "the status-item width was not locked under the open popover")
    return result
  }

  /// AppKit can move an anchored popover during its resize animation even when
  /// the final frame returns to the original position. Sample the whole
  /// transition so a visible sideways jump cannot hide behind a stable endpoint.
  static func checkAnimatedDisclosureAnchor(
    store: UsageStore,
    controller: StatusItemController,
    toggle: (ProviderID) -> Void
  ) -> Result {
    var result = Result()
    guard let window = controller.dashboardWindowForTesting,
      let provider = ProviderID.allCases.first(where: { store.isEnabled($0) })
    else {
      result.failures.append("no provider was available for the animated disclosure anchor check")
      return result
    }

    func maximumHorizontalMovement(from origin: CGFloat) -> CGFloat {
      var maximum: CGFloat = 0
      for _ in 0..<30 {
        self.settle(0.01)
        maximum = max(maximum, abs(window.frame.minX - origin))
      }
      return maximum
    }

    let expansionOrigin = window.frame.minX
    toggle(provider)
    let expansionMovement = maximumHorizontalMovement(from: expansionOrigin)
    result.expect(
      expansionMovement < 0.5,
      "animated expansion moved the popover horizontally by \(expansionMovement)pt")

    let collapseOrigin = window.frame.minX
    toggle(provider)
    let collapseMovement = maximumHorizontalMovement(from: collapseOrigin)
    result.expect(
      collapseMovement < 0.5,
      "animated collapse moved the popover horizontally by \(collapseMovement)pt")
    return result
  }

  /// Enabling and disabling a provider must move exactly that provider.
  static func checkEnablement(
    store: UsageStore,
    controller: StatusItemController
  ) -> Result {
    var result = Result()
    guard let window = controller.dashboardWindowForTesting else {
      result.failures.append("popover window was not created")
      return result
    }
    let original = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { ($0, store.isEnabled($0)) })
    defer { for (provider, value) in original { store.setEnabled(provider, enabled: value) } }

    for target in ProviderID.allCases {
      store.setEnabled(target, enabled: false)
      self.settle()
      let present = Set(self.visibleCards(in: window).map(self.providerIdentifier))
      let expected = Set(
        ProviderID.allCases.filter { store.isEnabled($0) }.map {
          "provider-card-\($0.rawValue)"
        })
      result.expect(
        present == expected,
        "disabling \(target.rawValue): visible \(present.sorted()) expected \(expected.sorted())")
      store.setEnabled(target, enabled: true)
      self.settle()
      let restored = Set(self.visibleCards(in: window).map(self.providerIdentifier))
      result.expect(
        restored.contains("provider-card-\(target.rawValue)"),
        "re-enabling \(target.rawValue) did not bring its card back")
    }
    return result
  }

  // MARK: - Appearance

  /// The colour a view is actually painted, resolved in that view's own
  /// appearance rather than whatever happens to be current.
  static func resolvedBackground(_ view: NSView) -> NSColor? {
    guard let cgColor = view.layer?.backgroundColor else { return nil }
    return NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB)
  }

  /// The appearance the person actually asked for, which is the only correct
  /// yardstick. Resolving an expectation in the *view's* appearance compares a
  /// stale surface against a stale expectation, so a surface stuck in the wrong
  /// mode agrees with itself and the check passes while the window is visibly
  /// wrong. Every appearance assertion has to be anchored outside the view.
  static func intendedAppearance(mode: AppearanceMode) -> NSAppearance {
    if let explicit = mode.nsAppearance { return explicit }
    let system = NSApplication.shared.effectiveAppearance
    return NSAppearance(named: system.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua) ?? system
  }

  static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  static func matches(_ color: NSColor?, _ expected: NSColor, in appearance: NSAppearance) -> Bool {
    guard let color else { return false }
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = expected.usingColorSpace(.sRGB)
    }
    guard let resolved else { return false }
    let tolerance: CGFloat = 0.02
    return abs(color.redComponent - resolved.redComponent) < tolerance
      && abs(color.greenComponent - resolved.greenComponent) < tolerance
      && abs(color.blueComponent - resolved.blueComponent) < tolerance
  }

  /// Every theme and every mode must reach the open popover and the open
  /// Settings window without either being reopened.
  static func checkAppearance(
    store: UsageStore,
    controller: StatusItemController,
    settings: SettingsWindowController
  ) -> Result {
    var result = Result()
    let originalTheme = store.appearanceTheme
    let originalMode = store.appearanceMode
    defer {
      store.appearanceTheme = originalTheme
      store.appearanceMode = originalMode
    }

    for mode in AppearanceMode.allCases {
      store.appearanceMode = mode
      for theme in AppearanceTheme.allCases {
        store.appearanceTheme = theme
        self.settle()
        let label = "\(mode.rawValue)+\(theme.rawValue)"

        // Re-fetched every time: the popover builds a new window on each show,
        // so a window captured once goes stale and reports old colours.
        guard let window = controller.dashboardWindowForTesting else {
          result.failures.append("\(label): popover window was not created")
          continue
        }
        guard let root = window.contentView else {
          result.failures.append("\(label): popover has no content view")
          continue
        }
        // Anchored to what was asked for, never to the view's own appearance.
        let appearance = self.intendedAppearance(mode: mode)
        // The window itself has to be in the right mode before its colours can
        // possibly be. This is the check the old tautological one could not make.
        result.expect(
          self.isDark(window.effectiveAppearance) == self.isDark(appearance),
          "\(label): popover window is \(self.isDark(window.effectiveAppearance) ? "dark" : "light")"
            + " but \(self.isDark(appearance) ? "dark" : "light") was asked for")
        result.expect(
          self.isDark(root.effectiveAppearance) == self.isDark(appearance),
          "\(label): dashboard view is in the wrong light/dark mode")
        // The dashboard surface itself.
        result.expect(
          self.matches(self.resolvedBackground(root), theme.palette.windowBase, in: appearance),
          "\(label): dashboard background did not follow the theme")

        // Hairlines are layer-backed and are the classic place a cached CGColor
        // survives an appearance change.
        let hairlines = self.descendants(of: root).compactMap { $0 as? ReserveHairline }
        for hairline in hairlines
        where !self.matches(
          self.resolvedBackground(hairline), theme.palette.border, in: appearance) {
          result.failures.append("\(label): a hairline kept a stale colour")
          break
        }

        // Settings must agree with the dashboard about the mode.
        if let settingsWindow = settings.window {
          let settingsMatch = settingsWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
          let dashboardMatch = appearance.bestMatch(from: [.aqua, .darkAqua])
          result.expect(
            settingsMatch == dashboardMatch,
            "\(label): Settings=\(settingsMatch?.rawValue ?? "nil") dashboard=\(dashboardMatch?.rawValue ?? "nil") app=\(NSApp.effectiveAppearance.name.rawValue) popoverAppearance=\(String(describing: window.appearance?.name.rawValue))")
        }
        result.expect(
          ReserveAppearance.current == theme,
          "\(label): the shared appearance did not adopt the theme")
      }
    }

    // A surface that was closed while the appearance changed must come back in
    // the current appearance, not the one it was built in.
    store.appearanceTheme = .matrix
    controller.closeMenuForStressTest()
    self.settle(0.2)
    store.appearanceTheme = .ember
    controller.showMenu()
    self.settle(0.2)
    if let root = controller.dashboardWindowForTesting?.contentView {
      result.expect(
        self.matches(
          self.resolvedBackground(root), AppearanceTheme.ember.palette.windowBase,
          in: self.intendedAppearance(mode: store.appearanceMode)),
        "a reopened dashboard kept the appearance it was closed in")
    } else {
      result.failures.append("the dashboard did not come back after being closed")
    }
    return result
  }

  // MARK: - Geometry

  /// The popover has to fit the screen it opens on, including the smallest
  /// display Reserve supports. A ceiling taller than the screen cannot be
  /// scrolled back into view — the popover is simply cut off by the screen edge.
  static func checkGeometry() -> Result {
    var result = Result()
    // A 1280×800 display, less the menu bar.
    let small: CGFloat = 800 - 25
    let smallCeiling = DashboardMetrics.availableHeight(
      on: nil, visibleHeight: small)
    result.expect(
      smallCeiling + DashboardMetrics.popoverChrome <= small,
      "on a 1280×800 display the dashboard ceiling is \(Int(smallCeiling))pt, which does not "
        + "leave room for the popover's own chrome in \(Int(small))pt")
    result.expect(
      smallCeiling >= DashboardMetrics.minimumHeight,
      "the small-display ceiling collapsed below the minimum dashboard height")

    // A roomy screen must not truncate. A fully expanded provider is around
    // 960pt, so a ceiling pinned to 860 forced it to scroll and pushed the last
    // card past the bottom edge even though the screen had room to spare.
    let roomy = DashboardMetrics.availableHeight(on: nil, visibleHeight: 1_400)
    result.expect(
      roomy > DashboardMetrics.maximumHeight,
      "a large display is still clamped to the old \(Int(DashboardMetrics.maximumHeight))pt "
        + "ceiling, got \(Int(roomy))")
    result.expect(
      roomy + DashboardMetrics.popoverChrome <= 1_400,
      "the roomy ceiling \(Int(roomy))pt does not leave room for the popover's own chrome")
    result.expect(
      roomy >= 1_000,
      "the ceiling \(Int(roomy))pt is still below a fully expanded provider, which scrolls "
        + "at roughly 960pt")
    return result
  }

  /// A control that spins has to spin in place.
  ///
  /// The previous version of this built the control in a bare host view and
  /// asserted that the layer was not displaced. Both were wrong: the real
  /// control lives inside the dashboard's stack views, and displacement was
  /// zero precisely *because* the anchor had never moved — the check could not
  /// fail. The invariant that matters is geometric: under the rotation the
  /// control's own centre must map to itself. Rotating about a corner moves it.
  static func checkSpinnerGeometry() -> Result {
    var result = Result()
    // The real construction path, refreshing, so the control is actually turning.
    let dashboard = UsageDashboardView(
      states: [], selectedMenuBarProvider: nil, isRefreshing: true,
      refreshStartedAt: Date().addingTimeInterval(-0.4), now: Date(),
      actions: DashboardActions(
        refreshAll: {}, connectProvider: { _ in }, selectMenuBarProvider: { _ in },
        openSettings: {}, openInsights: {}, dismiss: {}, toggleProviderDetail: { _ in },
        quit: {}))
    dashboard.layoutSubtreeIfNeeded()
    guard let button = self.descendants(of: dashboard).compactMap({ $0 as? ReserveIconButton })
      .first(where: { $0.identifier?.rawValue == "refresh-all" })
    else {
      result.failures.append("the dashboard has no refresh control")
      return result
    }
    guard !ReserveMotion.isReduced else { return result }
    guard let layer = button.layer else {
      result.failures.append("the refresh control has no layer to rotate")
      return result
    }
    result.expect(button.isSpinning, "the refresh control did not start turning")
    guard let spin = layer.animation(forKey: "reserve.refresh.spin") as? CAKeyframeAnimation,
      let values = spin.values as? [CATransform3D], values.count > 4
    else {
      result.failures.append(
        "the refresh control's rotation is not expressed as centre-relative matrices, so it "
          + "turns about its layer's anchor point")
      return result
    }
    // Take a quarter turn in and confirm the centre has not travelled.
    let centre = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
    let matrix = values[values.count / 4]
    let moved = CGPoint(
      x: matrix.m11 * centre.x + matrix.m21 * centre.y + matrix.m41,
      y: matrix.m12 * centre.x + matrix.m22 * centre.y + matrix.m42)
    let drift = hypot(moved.x - centre.x, moved.y - centre.y)
    result.expect(
      drift < 0.5,
      "a quarter turn moves the refresh control's centre by \(Int(drift))pt, so it swings "
        + "around a point beside itself instead of turning in place")
    return result
  }

  /// Local session activity and provider-reported plan limits are independent.
  /// A signed-out card must say so before someone opens its detail layer, or
  /// the locally reconstructed token totals look like contradictory live data.
  static func checkLocalActivityWithoutPlanLimits() -> Result {
    var result = Result()
    let now = Date()
    var missingCLI = ProviderViewState(provider: .grok)
    missingCLI.error = "Grok Build CLI is not installed."
    result.expect(
      !AllowanceBuilder.needsConnection(missingCLI),
      "a missing provider CLI is still presented as an authentication problem")
    var unavailable = ProviderViewState(provider: .anthropic)
    unavailable.error = "Anthropic usage request failed: The Internet connection appears offline."
    result.expect(
      !AllowanceBuilder.needsConnection(unavailable),
      "a provider availability failure is still presented as an authentication problem")
    var signedOut = ProviderViewState(provider: .anthropic)
    signedOut.error = "Claude OAuth credentials were not found. Use Sign in to authenticate."
    result.expect(
      AllowanceBuilder.needsConnection(signedOut),
      "missing provider credentials do not offer the sign-in recovery action")
    var keychainAccess = ProviderViewState(provider: .anthropic)
    keychainAccess.error = UsageProviderError.keychainConsentRequired.localizedDescription
    keychainAccess.requiresClaudeKeychainAccess = true
    result.expect(
      AllowanceBuilder.needsConnection(keychainAccess),
      "Claude access no longer offers its action after the explanation changes")
    result.expect(
      AppDelegate.claudeSetupTitle == "Show your Claude limits?"
        && AppDelegate.claudeSetupMessage
          == "Claude keeps your sign-in protected by macOS. Reserve uses it only to check your "
            + "plan limits—it never sees your password or saves your sign-in.\n\n"
            + "macOS may ask once. Choose Always Allow so future checks stay automatic.",
      "the Claude access explanation is no longer short and reassuring")
    let summary = ProviderSummary(
      provider: .anthropic,
      planName: "",
      allowances: [],
      paceState: .unknown,
      serviceStatus: nil,
      isConnecting: false,
      isRefreshing: false,
      needsConnection: true,
      requiresClaudeKeychainAccess: true,
      error: "Anthropic sign-in was not completed.",
      lastUpdated: nil,
      localUsage: LocalUsageSummary(
        provider: .anthropic, periodDays: 30, inputTokens: 100, outputTokens: 20,
        apiEquivalentCostUSD: 1, todayTokens: 12),
      subscriptionCostUSD: nil,
      quotaSource: nil)
    let card = ProviderDashboardCard(
      summary: summary, now: now, isSelectedForMenuBar: false, isExpanded: true,
      connectProvider: { _ in }, selectMenuBarProvider: { _ in })
    card.layoutSubtreeIfNeeded()
    let descendants = self.descendants(of: card)
    let signIn = descendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "connect-anthropic" }
    result.expect(
      signIn?.title == "Show limits",
      "the Claude recovery action does not lead with its benefit")
    let copy = descendants.compactMap { $0 as? NSTextField }.map(\.stringValue)
    result.expect(
      copy.contains("Claude is ready · show your plan limits"),
      "Claude access does not explain the benefit in plain language")
    result.expect(
      copy.contains("Monthly cost") && copy.contains("Not set")
        && !copy.contains("$20.00/mo") && !copy.contains("Anthropic Plan"),
      "an unknown provider plan is still presented as a detected $20 plan")

    let domain = "com.pocarles.reserve.cost-selftest"
    guard let defaults = UserDefaults(suiteName: domain) else {
      result.failures.append("could not create isolated defaults for monthly-cost checks")
      return result
    }
    let plist = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(domain).plist")
    defaults.removePersistentDomain(forName: domain)
    try? FileManager.default.removeItem(at: plist)
    defer {
      defaults.removePersistentDomain(forName: domain)
      try? FileManager.default.removeItem(at: plist)
    }
    let store = UsageStore(defaults: defaults, startAutomatically: false, notificationsActive: false)
    result.expect(
      store.monthlySubscriptionCost(for: .openAI) == nil
        && store.monthlySubscriptionCost(for: .anthropic) == nil
        && store.monthlySubscriptionCost(for: .grok) == nil,
      "Reserve still invents a monthly cost before a user enters one")
    store.setMonthlySubscriptionCost(90, for: .anthropic)
    result.expect(
      store.monthlySubscriptionCost(for: .anthropic) == 90,
      "a user's actual monthly cost is not preserved")
    store.setMonthlySubscriptionCost(nil, for: .anthropic)
    result.expect(
      store.monthlySubscriptionCost(for: .anthropic) == nil,
      "clearing a monthly cost restores the honest unset state")
    return result
  }

  // MARK: - Observation

  /// Every surface has to see the same store. A single-callback store silently
  /// drops whichever observer registered first.
  static func checkObservation(store: UsageStore) -> Result {
    var result = Result()
    final class Counter { var value = 0 }
    let first = Counter()
    let second = Counter()
    let one = store.observe { first.value += 1 }
    let two = store.observe { second.value += 1 }
    store.menuBarShowsReset.toggle()
    result.expect(first.value == 1, "the first observer was not notified (got \(first.value))")
    result.expect(second.value == 1, "the second observer was not notified (got \(second.value))")
    store.removeObserver(one)
    store.menuBarShowsReset.toggle()
    result.expect(first.value == 1, "a removed observer kept receiving updates")
    result.expect(second.value == 2, "the remaining observer stopped receiving updates")
    store.removeObserver(two)
    store.menuBarShowsReset.toggle()
    result.expect(second.value == 2, "the second observer was not removed")
    return result
  }
}
