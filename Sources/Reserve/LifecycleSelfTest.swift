import AppKit
import ReserveCore

/// Lifecycle checks that drive real state transitions through the live surfaces.
///
/// The static self-test proves the dashboard is *built* correctly. These checks
/// prove it stays correct while someone uses it: appearance changes reach every
/// open surface, and provider navigation never loses a tile or detail panel.
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

  /// The dashboard is the popover window's content view, so it has to sit
  /// exactly in the window's content rect. A dashboard that sets its own frame
  /// drops to the frame view's origin: the popover's gray border shows above it
  /// and at its trailing edge, and the footer runs into the bottom border.
  static func contentRectMismatch(_ root: NSView, in window: NSWindow) -> String? {
    let content = window.contentRect(forFrameRect: window.frame)
    let expected = NSRect(
      x: content.minX - window.frame.minX, y: content.minY - window.frame.minY,
      width: content.width, height: content.height)
    let actual = root.frame
    let matches = abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1
      && abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
    if matches { return nil }
    func r(_ rect: NSRect) -> String {
      "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }
    return "dashboard frame \(r(actual)) is not the popover content rect \(r(expected))"
  }

  /// The provider cards the popover window is actually drawing.
  static func visibleCards(in window: NSWindow?) -> [ProviderDashboardCard] {
    guard let root = window?.contentView else { return [] }
    return self.descendants(of: root).compactMap { $0 as? ProviderDashboardCard }
  }

  static func visibleTiles(in window: NSWindow?) -> [ProviderOverviewTile] {
    guard let root = window?.contentView else { return [] }
    return self.descendants(of: root).compactMap { $0 as? ProviderOverviewTile }
  }

  /// Why a card is reachable, or why it is not.
  ///
  /// The first version of this returned true for anything inside a scroll view,
  /// which excused the exact failure it existed to catch: a card pushed past the
  /// popover's edge sat in a scroll view, so the check passed while the provider
  /// was invisible. Being in a scroll view is not reachability — the card has to
  /// lie within the document's scrollable range, and the scroll view has to
  /// advertise that there is more to see.
  static func unreachableReason(_ card: NSView, in window: NSWindow) -> String? {
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

  static func providerIdentifier(_ card: NSView) -> String {
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

  // MARK: - Display changes

  /// A display change while the popover is open has to re-measure it: a
  /// shorter screen must not leave the popover taller than the space it has,
  /// and a taller one must give the scrolled rows back.
  static func checkScreenChangeResize(
    store: UsageStore,
    controller: StatusItemController,
    toggle: (ProviderID) -> Void
  ) -> Result {
    var result = Result()
    guard let window = controller.dashboardWindowForTesting else {
      result.failures.append("screen change check needs the open dashboard")
      return result
    }
    let originalSelection = store.expandedProvider
    defer {
      controller.availableHeightOverrideForTesting = nil
      NotificationCenter.default.post(
        name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
      store.expandedProvider = originalSelection
      self.settle()
    }
    // The tallest fixture card makes the height change visible.
    if store.expandedProvider != .openAI { toggle(.openAI) }
    self.settle()
    let natural = controller.popoverContentSizeForTesting.height
    let shorter = max(DashboardMetrics.minimumHeight + 20, natural - 160)

    func check(_ step: String, ceiling: CGFloat?) {
      controller.availableHeightOverrideForTesting = ceiling
      NotificationCenter.default.post(
        name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
      self.settle()
      let height = controller.popoverContentSizeForTesting.height
      if let ceiling {
        result.expect(
          height <= ceiling + 1,
          "\(step): the open popover stayed \(Int(height))pt for \(Int(ceiling))pt of screen")
      } else {
        result.expect(
          abs(height - natural) < 1,
          "\(step): the open popover is \(Int(height))pt, not its natural \(Int(natural))pt")
      }
      if let root = window.contentView, let mismatch = self.contentRectMismatch(root, in: window) {
        result.failures.append("\(step): \(mismatch)")
      }
    }
    check("shorter display", ceiling: shorter)
    check("display restored", ceiling: nil)
    return result
  }

  // MARK: - Provider disclosure

  /// Selects every provider, repeats a selection, and confirms the complete tile
  /// overview and exactly one matching detail panel remain reachable.
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
    let originalSelection = store.expandedProvider
    defer { store.expandedProvider = originalSelection }

    func audit(_ step: String) {
      self.settle()
      let tiles = self.visibleTiles(in: window)
      let tileIDs = Set(tiles.map(self.providerIdentifier))
      let expectedTiles = Set(enabled.map { "provider-tile-\($0.rawValue)" })
      result.expect(
        tileIDs == expectedTiles,
        "\(step): visible tiles \(tileIDs.sorted()) but expected \(expectedTiles.sorted())")
      let cards = self.visibleCards(in: window)
      let present = Set(cards.map(self.providerIdentifier))
      let expected = Set(store.expandedProvider.map { ["provider-card-\($0.rawValue)"] } ?? [])
      result.expect(
        present == expected,
        "\(step): detail panels \(present.sorted()) but expected \(expected.sorted())")
      let navigableViews: [NSView] = tiles.map { $0 as NSView } + cards.map { $0 as NSView }
      for view in navigableViews {
        if let reason = self.unreachableReason(view, in: window) {
          result.failures.append(
            "\(step): \(self.providerIdentifier(view)) is \(reason)")
        }
      }
      // The window must be able to show the content it was sized for.
      if let root = window.contentView {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 0
        let chrome = window.frame.height - root.frame.height
        if let mismatch = self.contentRectMismatch(root, in: window) {
          result.failures.append("\(step): \(mismatch)")
        }
        result.expect(
          abs(chrome - DashboardMetrics.popoverChrome) < 2,
          "\(step): popover window is \(Int(window.frame.height))pt but its dashboard is "
            + "\(Int(root.frame.height))pt (chrome \(Int(chrome))pt)")
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

    audit("initial selection")
    for provider in enabled {
      let xBeforeExpansion = window.frame.minX
      toggle(provider)
      self.settle()
      result.expect(
        abs(window.frame.minX - xBeforeExpansion) < 0.5,
        "selecting \(provider.rawValue) moved the popover horizontally by "
          + "\(abs(window.frame.minX - xBeforeExpansion))pt")
      result.expect(
        store.expandedProvider == provider,
        "selecting \(provider.rawValue) did not record the selection")
      audit("selected \(provider.rawValue)")
      let xBeforeRepeat = window.frame.minX
      toggle(provider)
      self.settle()
      result.expect(
        abs(window.frame.minX - xBeforeRepeat) < 0.5,
        "re-selecting \(provider.rawValue) moved the popover horizontally by "
          + "\(abs(window.frame.minX - xBeforeRepeat))pt")
      result.expect(
        store.expandedProvider == provider,
        "re-selecting \(provider.rawValue) cleared the persistent selection")
      audit("re-selected \(provider.rawValue)")
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
    let originalSelection = store.expandedProvider
    defer {
      store.menuBarProvider = originalProvider
      store.menuBarShowsRemaining = originalRemaining
      store.expandedProvider = originalSelection
    }
    guard let target = ProviderID.allCases.first(where: {
      store.isEnabled($0) && $0 != originalProvider
    }) else {
      result.failures.append("no alternate provider was available for the anchor check")
      return result
    }
    store.expandedProvider = target
    self.settle()
    guard
      let card = self.visibleCards(in: window).first(where: {
        self.providerIdentifier($0) == "provider-card-\(target.rawValue)"
      })
    else {
      result.failures.append("the selected provider detail was unavailable for the anchor check")
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
    let enabled = ProviderID.allCases.filter { store.isEnabled($0) }
    guard let window = controller.dashboardWindowForTesting,
      let first = enabled.first,
      let second = enabled.first(where: { $0 != first })
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

    let firstOrigin = window.frame.minX
    toggle(first)
    let firstMovement = maximumHorizontalMovement(from: firstOrigin)
    result.expect(
      firstMovement < 0.5,
      "animated provider selection moved the popover horizontally by \(firstMovement)pt")

    let secondOrigin = window.frame.minX
    toggle(second)
    let secondMovement = maximumHorizontalMovement(from: secondOrigin)
    result.expect(
      secondMovement < 0.5,
      "animated provider switch moved the popover horizontally by \(secondMovement)pt")
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
    let originalSelection = store.expandedProvider
    defer {
      for (provider, value) in original {
        store.setEnabled(provider, enabled: value, refreshImmediately: false)
      }
      store.expandedProvider = originalSelection
    }

    for target in ProviderID.allCases {
      store.setEnabled(target, enabled: false)
      self.settle()
      let present = Set(self.visibleTiles(in: window).map(self.providerIdentifier))
      let expected = Set(
        ProviderID.allCases.filter { store.isEnabled($0) }.map {
          "provider-tile-\($0.rawValue)"
        })
      result.expect(
        present == expected,
        "disabling \(target.rawValue): visible \(present.sorted()) expected \(expected.sorted())")
      let detailCards = self.visibleCards(in: window)
      result.expect(
        detailCards.count == (expected.isEmpty ? 0 : 1),
        "disabling \(target.rawValue) left \(detailCards.count) detail panels")
      store.setEnabled(target, enabled: true, refreshImmediately: false)
      self.settle()
      let restored = Set(self.visibleTiles(in: window).map(self.providerIdentifier))
      result.expect(
        restored.contains("provider-tile-\(target.rawValue)"),
        "re-enabling \(target.rawValue) did not bring its tile back")
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
    if let dashboardWindow = controller.dashboardWindowForTesting,
      let settingsWindow = settings.window
    {
      func isInFront(_ candidate: NSWindow, of other: NSWindow) -> Bool {
        guard let orderedWindows = NSWindow.windowNumbers(options: []),
          let candidateIndex = orderedWindows.firstIndex(
            of: NSNumber(value: candidate.windowNumber)),
          let otherIndex = orderedWindows.firstIndex(of: NSNumber(value: other.windowNumber))
        else { return false }
        return candidateIndex < otherIndex
      }

      controller.bringSettingsToFrontForTesting()
      self.settle()
      result.expect(
        settingsWindow.level.rawValue > dashboardWindow.level.rawValue
          && isInFront(settingsWindow, of: dashboardWindow),
        "Settings did not move in front when it was activated")

      controller.bringDashboardToFrontForTesting()
      self.settle()
      result.expect(
        dashboardWindow.level.rawValue > settingsWindow.level.rawValue
          && isInFront(dashboardWindow, of: settingsWindow),
        "dashboard did not move back in front when it was activated")

      controller.bringSettingsToFrontForTesting()
      self.settle()
      result.expect(
        settingsWindow.level.rawValue > dashboardWindow.level.rawValue
          && isInFront(settingsWindow, of: dashboardWindow),
        "Settings did not return to the front when it was activated again")
    } else {
      result.failures.append("dashboard and Settings were not both open for the window-order check")
    }
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

  /// Routine readings keep the open dashboard and the Settings controls already
  /// on screen. A value typed into one field survives an update of other rows.
  static func checkLiveUpdateIdentity(
    store: UsageStore,
    controller: StatusItemController,
    settings: SettingsWindowController
  ) -> Result {
    var result = Result()
    guard let window = controller.dashboardWindowForTesting,
      let root = window.contentView as? UsageDashboardView
    else {
      result.failures.append("live update check needs the open dashboard")
      return result
    }
    settings.show(.providers)
    self.settle()
    guard let settingsWindow = settings.window, let settingsRoot = settingsWindow.contentView else {
      result.failures.append("settings was not open for the live update check")
      return result
    }
    let disclose = self.descendants(of: settingsRoot).compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "provider-disclose-openAI"
    }
    disclose?.performClick(nil)
    self.settle()
    guard let field = self.descendants(of: settingsWindow.contentView ?? NSView())
      .compactMap({ $0 as? NSTextField })
      .first(where: { $0.identifier?.rawValue == "subscription.openAI" }),
      let updated = self.descendants(of: settingsWindow.contentView ?? NSView())
      .compactMap({ $0 as? NSTextField })
      .first(where: { $0.identifier?.rawValue == "settings-updated-grok" })
    else {
      result.failures.append("the provider row or subscription field was not on screen")
      return result
    }
    let originalField = field.stringValue
    settingsWindow.makeFirstResponder(field)
    field.stringValue = "42"
    let rootID = ObjectIdentifier(root)
    let openAITile = self.visibleTiles(in: window).first {
      self.providerIdentifier($0) == "provider-tile-openAI"
    }
    let grokTile = self.visibleTiles(in: window).first {
      self.providerIdentifier($0) == "provider-tile-grok"
    }
    let card = self.visibleCards(in: window).first
    let tileID = openAITile.map(ObjectIdentifier.init)
    let grokID = grokTile.map(ObjectIdentifier.init)
    let cardID = card.map(ObjectIdentifier.init)
    let fieldID = ObjectIdentifier(field)
    let updatedID = ObjectIdentifier(updated)
    let beforeUpdated = updated.stringValue
    let fullBefore = controller.dashboardFullRebuildsForTesting
    let regionBefore = controller.dashboardRegionRebuildsForTesting

    store.installPreviewSnapshots(
      now: Date().addingTimeInterval(-180), scenario: .exhausted)
    self.settle(0.25)

    let sameRoot = window.contentView.map(ObjectIdentifier.init) == rootID
    let openAIAfter = self.visibleTiles(in: window).first {
      self.providerIdentifier($0) == "provider-tile-openAI"
    }
    let grokAfter = self.visibleTiles(in: window).first {
      self.providerIdentifier($0) == "provider-tile-grok"
    }
    let settingsAfter = settingsWindow.contentView.map { self.descendants(of: $0) } ?? []
    let fieldAfter = settingsAfter.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "subscription.openAI"
    }
    let updatedAfter = settingsAfter.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "settings-updated-grok"
    }
    result.expect(sameRoot, "a usage reading replaced the dashboard view")
    if let mismatch = self.contentRectMismatch(root, in: window) {
      result.failures.append("after a usage reading, \(mismatch)")
    }
    result.expect(
      openAIAfter.map(ObjectIdentifier.init) == tileID,
      "a usage reading replaced the OpenAI tile")
    result.expect(
      grokAfter.map(ObjectIdentifier.init) == grokID,
      "a usage reading replaced an unchanged provider tile")
    result.expect(
      self.visibleCards(in: window).first.map(ObjectIdentifier.init) == cardID,
      "a usage reading replaced the open provider card")
    let openAIText = openAIAfter.flatMap { tile in
      self.descendants(of: tile).compactMap { $0 as? NSTextField }.first {
        $0.identifier?.rawValue == "tile-value-openAI"
      }?.stringValue
    }
    result.expect(
      openAIText == "0% left",
      "the OpenAI tile still reads \(openAIText ?? "nothing") after the exhausted reading")
    result.expect(
      fieldAfter.map(ObjectIdentifier.init) == fieldID && fieldAfter?.stringValue == "42",
      "editing the subscription cost was lost while another provider updated")
    result.expect(
      updatedAfter.map(ObjectIdentifier.init) == updatedID
        && updatedAfter?.stringValue != beforeUpdated,
      "the other provider row did not take the new reading")
    result.expect(
      controller.dashboardFullRebuildsForTesting == fullBefore,
      "the usage reading rebuilt the whole dashboard")
    result.expect(
      controller.dashboardRegionRebuildsForTesting == regionBefore,
      "the usage reading rebuilt a provider region")

    field.stringValue = originalField
    settingsWindow.makeFirstResponder(nil)
    store.installPreviewSnapshots(scenario: .deficit)
    settings.show(.general)
    self.settle(0.2)
    return result
  }

  /// Cached history and preferences must update retained controls, including
  /// after an unrelated layout change was deferred by a key draft.
  static func checkSettingsLiveValues() -> Result {
    var result = Result()
    let suite = "com.reserve.settings-live.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      result.failures.append("could not create isolated Settings preferences")
      return result
    }
    let originalTheme = ReserveAppearance.current
    let originalMode = ReserveAppearance.mode
    defer {
      defaults.removePersistentDomain(forName: suite)
      ReserveAppearance.current = originalTheme
      ReserveAppearance.mode = originalMode
    }
    let store = UsageStore(defaults: defaults, startAutomatically: false, notificationsActive: false)
    store.installPreviewSnapshots()
    let settings = SettingsWindowController(store: store, updater: nil, setupProvider: { _ in })
    defer { settings.window?.close() }
    func view(_ id: String) -> NSView? {
      self.descendants(of: settings.window?.contentView ?? NSView()).first {
        $0.identifier?.rawValue == id
      }
    }
    settings.show(.general)
    self.settle()
    let privacy = view("settings-hide-personal") as? NSButton
    let privacyID = privacy.map(ObjectIdentifier.init)
    let originalPrivacy = store.hidesPersonalInfo
    store.hidesPersonalInfo.toggle()
    store.menuBarProvider = .grok
    store.refreshIntervalMinutes = 15
    self.settle()
    result.expect(view("settings-hide-personal").map(ObjectIdentifier.init) == privacyID
      && privacy?.state == (originalPrivacy ? .off : .on),
      "Settings privacy checkbox did not update in place")
    result.expect((view("settings-refresh-interval") as? NSPopUpButton)?.indexOfSelectedItem == 4,
      "Settings refresh interval kept an old selection")
    result.expect((view("menu-bar-provider") as? NSPopUpButton)?.indexOfSelectedItem
      == (ProviderID.allCases.firstIndex(of: .grok) ?? -1) + 1,
      "Settings pin selection kept an old provider")

    let day = InsightHistoryRange.dayKeys(count: 1, now: Date())[0]
    store.publishDailyHistoryForTesting([InsightHistoryDay(day: day, tokens: 100, costUSD: 1)], provider: .openAI)
    settings.show(.insights)
    self.settle()
    let heatmap = view("insights-heatmap-openAI") as? UsageHeatmapView
    let heatmapID = heatmap.map(ObjectIdentifier.init)
    let beforeCaption = heatmap?.dayCaptionForTesting(at: store.insightHistoryDays - 1)
    let total = view("insights-total") as? NSTextField
    let totalID = total.map(ObjectIdentifier.init)
    let beforeTotal = total?.stringValue
    store.publishDailyHistoryForTesting([InsightHistoryDay(day: day, tokens: 9_000, costUSD: 99)], provider: .openAI)
    self.settle()
    result.expect(view("insights-heatmap-openAI").map(ObjectIdentifier.init) == heatmapID
      && heatmap?.dayCaptionForTesting(at: store.insightHistoryDays - 1) != beforeCaption,
      "Insights heatmap failed to update the retained chart")
    result.expect(view("insights-total").map(ObjectIdentifier.init) == totalID
      && total?.stringValue != beforeTotal,
      "Insights total failed to update the retained label")
    if let last = view("insights-total"), let window = settings.window {
      result.expect(self.unreachableReason(last, in: window) == nil,
        "updated Insights total fell outside the scrollable document")
    }

    settings.show(.api)
    self.settle()
    if let key = view("api-key-openAI") as? NSTextField, let window = settings.window {
      window.makeFirstResponder(key)
      key.stringValue = "unsaved-fixture"
      let before = view("api-provider-openAI")
      store.appearanceTheme = store.appearanceTheme == .ember ? .ocean : .ember
      self.settle()
      result.expect(view("api-provider-openAI") === before && key.stringValue == "unsaved-fixture",
        "a required Settings layout change interrupted key editing")
      window.makeFirstResponder(nil)
      self.settle()
      result.expect(view("api-provider-openAI") !== before,
        "Settings left a layout change pending after key editing ended")
      result.expect((view("api-key-openAI") as? NSTextField)?.stringValue == "unsaved-fixture",
        "a required Settings layout change discarded an unsaved key draft")
    } else {
      result.failures.append("API key field missing from isolated Settings check")
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
        quit: {}, apiConsumptionReadings: { [] }))
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
    missingCLI.requiresInstallation = true
    result.expect(
      AllowanceBuilder.setupAction(for: missingCLI, connectionToolAvailable: false) == .install,
      "a missing provider helper does not offer native setup")
    var outdatedCLI = ProviderViewState(provider: .grok)
    outdatedCLI.error = "Grok Build 1.0.0 or newer is required."
    outdatedCLI.requiresUpdate = true
    result.expect(
      AllowanceBuilder.setupAction(for: outdatedCLI, connectionToolAvailable: true) == .update,
      "an outdated provider helper does not offer a one-click update")
    var unavailable = ProviderViewState(provider: .anthropic)
    unavailable.error = "Anthropic usage request failed: The Internet connection appears offline."
    result.expect(
      !AllowanceBuilder.needsConnection(unavailable),
      "a provider availability failure is still presented as an authentication problem")
    var signedOut = ProviderViewState(provider: .anthropic)
    signedOut.error = "Claude OAuth credentials were not found. Use Sign in to authenticate."
    signedOut.requiresConnection = true
    result.expect(
      AllowanceBuilder.needsConnection(signedOut),
      "missing provider credentials do not offer the sign-in recovery action")
    signedOut.snapshot = UsageSnapshot(
      provider: .anthropic, windows: [], fetchedAt: now, source: "cached")
    result.expect(
      AllowanceBuilder.needsConnection(signedOut),
      "cached provider data hides the sign-in recovery action")
    var keychainAccess = ProviderViewState(provider: .anthropic)
    keychainAccess.error = UsageProviderError.keychainConsentRequired(.anthropic).localizedDescription
    keychainAccess.requiresKeychainAccess = true
    result.expect(
      AllowanceBuilder.needsConnection(keychainAccess),
      "Claude access no longer offers its action after the explanation changes")
    result.expect(
      AppDelegate.claudeSetupTitle == "Show your Claude limits"
        && AppDelegate.claudeSetupMessage
          == "Reserve can use the Claude sign-in already on this Mac to check your plan limits."
        && AppDelegate.claudeSetupReassurance == "Your sign-in stays protected by macOS"
        && AppDelegate.claudeSetupPrivacy
          == "Reserve never sees your password or saves your sign-in."
        && AppDelegate.claudeSetupFootnote
          == "You can turn this access off at any time in Settings > Providers.",
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
      connectionToolAvailable: true,
      requiresKeychainAccess: true,
      setupAction: .allowAccess,
      error: "Anthropic sign-in was not completed.",
      lastUpdated: nil,
      localUsage: LocalUsageSummary(
        provider: .anthropic, periodDays: 30, inputTokens: 100, outputTokens: 20,
        apiEquivalentCostUSD: 1, todayTokens: 12),
      subscriptionCostUSD: nil,
      quotaSource: nil,
      includedSpend: nil,
      detailedUsageUnavailable: false)
    var recoveryProvider: ProviderID?
    let card = ProviderDashboardCard(
      summary: summary, now: now, isSelectedForMenuBar: false, isExpanded: true,
      connectProvider: { recoveryProvider = $0 }, selectMenuBarProvider: { _ in })
    card.layoutSubtreeIfNeeded()
    let descendants = self.descendants(of: card)
    let signIn = descendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "connect-anthropic" }
    signIn?.performClick(nil)
    result.expect(
      signIn?.title == "Allow access" && recoveryProvider == .anthropic,
      "the Claude recovery action does not open the shared connection flow")
    let copy = descendants.compactMap { $0 as? NSTextField }.map(\.stringValue)
    result.expect(
      copy.contains("Waiting for permission to read usage"),
      "Claude access is not clearly distinguished from sign-in")
    result.expect(
      !copy.contains("Subscription") && !copy.contains("Not set")
        && !copy.contains("$20.00/mo") && !copy.contains("Anthropic Plan"),
      "an unknown provider plan is still presented as a detected $20 plan")

    let setupSummary = ProviderSummary(
      provider: .anthropic,
      planName: "",
      allowances: [],
      paceState: .unknown,
      serviceStatus: nil,
      isConnecting: false,
      isRefreshing: false,
      needsConnection: true,
      connectionToolAvailable: false,
      requiresKeychainAccess: false,
      setupAction: .install,
      error: "Claude OAuth credentials were not found.",
      lastUpdated: nil,
      localUsage: summary.localUsage,
      subscriptionCostUSD: nil,
      quotaSource: nil,
      includedSpend: nil,
      detailedUsageUnavailable: false)
    let setupCard = ProviderDashboardCard(
      summary: setupSummary, now: now, isSelectedForMenuBar: false,
      connectProvider: { _ in }, selectMenuBarProvider: { _ in })
    setupCard.layoutSubtreeIfNeeded()
    let setupDescendants = self.descendants(of: setupCard)
    let setupButton = setupDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "connect-anthropic" }
    let setupCopy = setupDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
    result.expect(
      setupButton?.title == "Set up"
        && setupCopy.contains("Set up Claude to show plan limits"),
      "a missing provider helper still looks broken instead of offering setup")
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
        && store.monthlySubscriptionCost(for: .grok) == nil
        && store.monthlySubscriptionCost(for: .cursor) == nil
        && store.monthlySubscriptionCost(for: .copilot) == nil,
      "Reserve still invents a monthly cost before a user enters one")
    result.expect(
      !store.isEnabled(.cursor) && !store.cursorKeychainReadAllowed,
      "Cursor no longer starts disabled with Keychain access off")
    result.expect(!store.isEnabled(.copilot), "Copilot no longer starts disabled")
    result.expect(
      !store.isEnabled(.gemini) && store.monthlySubscriptionCost(for: .gemini) == nil,
      "Gemini no longer starts disabled without a cost")
    result.expect(
      !store.isEnabled(.zai) && !store.isEnabled(.kimi)
        && store.monthlySubscriptionCost(for: .zai) == nil
        && store.monthlySubscriptionCost(for: .kimi) == nil,
      "Z.ai and Kimi no longer start disabled without a cost")
    result.expect(
      store.localHistoryEnabled,
      "local history no longer remains available after updating Reserve")
    store.localHistoryEnabled = false
    result.expect(
      !store.localHistoryEnabled,
      "an explicit choice to disable local history is not preserved")
    result.expect(
      store.exerciseCursorAccessDisableForSelfTest(),
      "turning off Cursor access did not take effect immediately")
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
