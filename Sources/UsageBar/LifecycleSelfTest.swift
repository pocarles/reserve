import AppKit
import UsageBarCore

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

  /// A card counts as reachable when it is inside the window's content bounds.
  /// A card that is present in the hierarchy but sitting outside the visible
  /// rectangle has, from the user's point of view, disappeared.
  static func isReachable(_ card: ProviderDashboardCard, in window: NSWindow) -> Bool {
    guard let root = window.contentView else { return false }
    let frame = card.convert(card.bounds, to: root)
    // Clipped by an enclosing scroll view is fine — it can be scrolled back into
    // view. Outside the window entirely is not.
    let visible = root.bounds.insetBy(dx: -1, dy: -1)
    return visible.intersects(frame) || card.enclosingScrollView != nil
  }

  static func providerIdentifier(_ card: ProviderDashboardCard) -> String {
    card.identifier?.rawValue ?? "unknown"
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
      for card in cards where !self.isReachable(card, in: window) {
        result.failures.append(
          "\(step): \(self.providerIdentifier(card)) is outside the visible dashboard")
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
      toggle(provider)
      result.expect(
        store.expandedProvider == provider,
        "expanding \(provider.rawValue) did not record the expansion")
      audit("expanded \(provider.rawValue)")
      toggle(provider)
      result.expect(
        store.expandedProvider == nil,
        "collapsing \(provider.rawValue) did not clear the expansion")
      audit("collapsed after \(provider.rawValue)")
    }
    // Straight from one open provider to another, without collapsing first.
    if enabled.count >= 2 {
      toggle(enabled[0])
      audit("open \(enabled[0].rawValue)")
      toggle(enabled[1])
      audit("switched to \(enabled[1].rawValue)")
      result.expect(
        store.expandedProvider == enabled[1],
        "switching between providers did not move the expansion")
      toggle(enabled[1])
      audit("collapsed after switch")
    }
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
    guard let window = controller.dashboardWindowForTesting else {
      result.failures.append("popover window was not created")
      return result
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

        guard let root = window.contentView else {
          result.failures.append("\(label): popover has no content view")
          continue
        }
        let appearance = root.effectiveAppearance
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
          in: root.effectiveAppearance),
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

    let roomy = DashboardMetrics.availableHeight(on: nil, visibleHeight: 1_400)
    result.expect(
      roomy == DashboardMetrics.maximumHeight,
      "a large display should still respect the design ceiling, got \(Int(roomy))")
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
