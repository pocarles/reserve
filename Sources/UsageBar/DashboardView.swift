import AppKit
import UsageBarCore

@MainActor
struct DashboardActions {
  let refreshAll: () -> Void
  let connectAnthropic: () -> Void
  let openSettings: () -> Void
  let quit: () -> Void
}

@MainActor
final class DashboardViewController: NSViewController {
  private let store: UsageStore
  private let actions: DashboardActions
  private var minuteTimer: Timer?

  init(store: UsageStore, actions: DashboardActions) {
    self.store = store
    self.actions = actions
    super.init(nibName: nil, bundle: nil)
    self.preferredContentSize = NSSize(width: DashboardMetrics.width, height: 640)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() { self.update() }

  func update() {
    let dashboard = UsageDashboardView(
      states: self.store.orderedStates.filter { self.store.isEnabled($0.provider) },
      isRefreshing: self.store.isRefreshingAll || self.store.isScanningLocalUsage,
      now: Date(),
      actions: self.actions)
    self.view = dashboard
    self.preferredContentSize = dashboard.frame.size
  }

  func startClock() {
    self.minuteTimer?.invalidate()
    self.minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.update() }
    }
  }

  func stopClock() {
    self.minuteTimer?.invalidate()
    self.minuteTimer = nil
  }
}

/// The popover surface: a header, one overview panel, a card per provider, and
/// a footer. The view sizes itself to its content so the popover never scrolls
/// and never shows dead space.
@MainActor
final class UsageDashboardView: DashboardSurface {
  init(
    states: [ProviderViewState],
    isRefreshing: Bool,
    now: Date,
    actions: DashboardActions
  ) {
    super.init(fill: DashboardPalette.background)
    self.identifier = NSUserInterfaceItemIdentifier("usage-dashboard")

    var sections: [NSView] = [
      DashboardHeaderView(
        states: states, isRefreshing: isRefreshing, now: now, refresh: actions.refreshAll),
      OverviewPanel(states: states),
    ]
    for state in states {
      let card = ProviderCard(
        state: state, now: now, isScanning: isRefreshing,
        connectAnthropic: actions.connectAnthropic)
      card.identifier = NSUserInterfaceItemIdentifier("provider-card-\(state.provider.rawValue)")
      sections.append(card)
    }
    if states.isEmpty {
      sections.append(EmptyProvidersView(openSettings: actions.openSettings))
    }
    sections.append(DashboardFooterView(actions: actions))

    let stack = NSStackView.vertical(sections, spacing: DashboardMetrics.sectionSpacing)
    stack.setCustomSpacing(16, after: sections[1])
    stack.setCustomSpacing(16, after: sections[sections.count - 2])
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: self.leadingAnchor, constant: DashboardMetrics.horizontalInset),
      stack.trailingAnchor.constraint(
        equalTo: self.trailingAnchor, constant: -DashboardMetrics.horizontalInset),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: DashboardMetrics.topInset),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: self.bottomAnchor, constant: -DashboardMetrics.bottomInset),
    ])

    // Measure from a real layout pass at the final width, then shrink to fit.
    self.frame = NSRect(
      x: 0, y: 0, width: DashboardMetrics.width, height: DashboardMetrics.maximumHeight)
    self.layoutSubtreeIfNeeded()
    let content =
      stack.frame.height + DashboardMetrics.topInset + DashboardMetrics.bottomInset
    let height = min(
      DashboardMetrics.maximumHeight, max(DashboardMetrics.minimumHeight, ceil(content)))
    self.frame = NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: height)
    self.layoutSubtreeIfNeeded()
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardHeaderView: NSView {
  init(states: [ProviderViewState], isRefreshing: Bool, now: Date, refresh: @escaping () -> Void) {
    super.init(frame: .zero)
    let title = DashboardLabel(
      "Usage", font: DashboardFont.serif(25, .semibold), color: DashboardPalette.text)
    let subtitle = DashboardLabel(
      Self.subtitle(states: states, isRefreshing: isRefreshing, now: now),
      font: DashboardFont.sans(10.5),
      color: DashboardPalette.muted)
    subtitle.flexible()
    let copy = NSStackView.vertical([title, subtitle], spacing: 1)
    let button = DashboardIconButton(
      symbol: "arrow.clockwise", toolTip: "Refresh all", action: refresh)
    button.identifier = NSUserInterfaceItemIdentifier("refresh-all")
    for view in [copy, button] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      copy.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      copy.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
      copy.topAnchor.constraint(equalTo: self.topAnchor),
      copy.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      button.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      button.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static func subtitle(states: [ProviderViewState], isRefreshing: Bool, now: Date) -> String
  {
    if isRefreshing { return "Reading limits and local usage…" }
    let dates = states.flatMap { state in
      [state.snapshot?.fetchedAt, state.localUsage?.fetchedAt].compactMap { $0 }
    }
    guard let latest = dates.max() else { return "Last 30 days · waiting for first refresh" }
    return "Last 30 days · \(DashboardFormat.updated(latest, now: now))"
  }
}

/// The one number that answers "is the subscription worth it", with the
/// supporting totals kept deliberately quiet beside it.
@MainActor
private final class OverviewPanel: DashboardSurface {
  init(states: [ProviderViewState]) {
    super.init(
      fill: DashboardPalette.card, stroke: DashboardPalette.border, radius: 16)

    let usage = states.compactMap(\.localUsage)
    let tokens = usage.reduce(Int64(0)) { $0 + $1.totalTokens }
    let apiValue = usage.reduce(0.0) { $0 + $1.apiEquivalentCostUSD }
    let plans = states.reduce(0.0) { $0 + $1.subscriptionCostUSD }
    let saved = apiValue - plans

    // Before the first local scan there is nothing to compare against, so the
    // panel stays neutral instead of announcing a loss.
    let measured = !usage.isEmpty
    let heading = DashboardLabel.caption(
      measured && saved < 0 ? "Over plan cost" : "Saved vs plans"
    ).width(Self.heroWidth)
    let hero = DashboardLabel(
      measured ? DashboardFormat.savings(saved) : "—",
      font: DashboardFont.serif(27, .semibold),
      color: !measured
        ? DashboardPalette.subtle
        : (saved >= 0 ? DashboardPalette.text : DashboardPalette.warning)
    ).width(Self.heroWidth)
    let headline = NSStackView.vertical([heading, hero], spacing: 1)

    let metrics = NSStackView.horizontal(
      [
        OverviewMetric(
          label: "Tokens", value: measured ? DashboardFormat.tokens(tokens) : "—"),
        OverviewMetric(
          label: "API value", value: measured ? DashboardFormat.money(apiValue) : "—"),
        OverviewMetric(label: "Plans", value: DashboardFormat.money(plans) + "/mo"),
      ],
      spacing: 6,
      alignment: .top)

    let row = NSStackView.horizontal([headline, NSView(), metrics], spacing: 8, alignment: .top)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(
        equalTo: self.leadingAnchor, constant: DashboardMetrics.cardPadding),
      row.trailingAnchor.constraint(
        equalTo: self.trailingAnchor, constant: -DashboardMetrics.cardPadding),
      row.topAnchor.constraint(equalTo: self.topAnchor, constant: 14),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -14),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  fileprivate static let heroWidth: CGFloat = 120
}

@MainActor
private final class OverviewMetric: NSView {
  init(label: String, value: String) {
    super.init(frame: .zero)
    let caption = DashboardLabel.caption(label, alignment: .right).width(Self.width)
    let value = DashboardLabel(
      value,
      font: DashboardFont.digits(12.5, .semibold),
      color: DashboardPalette.text,
      alignment: .right
    ).width(Self.width)
    let stack = NSStackView.vertical([caption, value], spacing: 3, alignment: .trailing)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
    ])
    self.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { nil }

  fileprivate static let width: CGFloat = 74
}

@MainActor
private final class ProviderCard: DashboardSurface {
  init(
    state: ProviderViewState,
    now: Date,
    isScanning: Bool,
    connectAnthropic: @escaping () -> Void
  ) {
    super.init(fill: DashboardPalette.card, stroke: DashboardPalette.border, radius: 16)

    var rows: [NSView] = [
      Self.identityRow(state: state, connectAnthropic: connectAnthropic),
      QuotaBlock(state: state, now: now),
    ]
    rows.append(DashboardRule(width: DashboardMetrics.cardContentWidth))
    rows.append(EconomicsRow(state: state, isScanning: isScanning))

    let stack = NSStackView.vertical(rows, spacing: 10)
    stack.setCustomSpacing(10, after: rows[1])
    stack.setCustomSpacing(9, after: rows[2])
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: self.leadingAnchor, constant: DashboardMetrics.cardPadding),
      stack.trailingAnchor.constraint(
        equalTo: self.trailingAnchor, constant: -DashboardMetrics.cardPadding),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 13),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -12),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static func identityRow(
    state: ProviderViewState,
    connectAnthropic: @escaping () -> Void
  ) -> NSView {
    let logo = ProviderLogo(provider: state.provider)
    let name = DashboardLabel(
      state.provider.displayName,
      font: DashboardFont.sans(13.5, .semibold),
      color: DashboardPalette.text
    ).flexible()
    let planName = state.snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let plan = DashboardLabel(
      "\((planName?.isEmpty == false ? planName : nil) ?? "Plan") · \(DashboardFormat.money(state.subscriptionCostUSD))/month",
      font: DashboardFont.sans(9.5),
      color: DashboardPalette.muted
    ).flexible()
    let identity = NSStackView.vertical([name, plan], spacing: 1)
    identity.setClippingResistancePriority(.defaultLow, for: .horizontal)
    identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let trailing: NSView
    if state.provider == .anthropic, state.needsConnection, !state.isConnecting,
      !state.isRefreshing
    {
      let connect = DashboardPillButton(
        title: "Connect", accent: state.provider.accent, action: connectAnthropic)
      connect.identifier = NSUserInterfaceItemIdentifier("connect-anthropic")
      trailing = connect
    } else {
      trailing = StatusPill(state: state)
    }
    trailing.setContentHuggingPriority(.required, for: .horizontal)
    trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

    let row = NSStackView.horizontal([logo, identity, NSView(), trailing], spacing: 10)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }
}

@MainActor
private final class StatusPill: DashboardSurface {
  init(state: ProviderViewState) {
    let status: String
    let color: NSColor
    if state.isConnecting {
      (status, color) = ("Connecting", state.provider.accent)
    } else if state.isRefreshing {
      (status, color) = ("Refreshing", state.provider.accent)
    } else if state.snapshot != nil && state.error == nil {
      (status, color) = ("Live", DashboardPalette.success)
    } else if state.snapshot != nil {
      (status, color) = ("Saved", DashboardPalette.warning)
    } else {
      (status, color) = ("Offline", DashboardPalette.subtle)
    }
    super.init(fill: color, fillAlpha: 0.12, radius: 9)

    let dot = DashboardSurface(fill: color, radius: 2.5)
    dot.translatesAutoresizingMaskIntoConstraints = false
    let label = DashboardLabel(status, font: DashboardFont.sans(9.5, .medium), color: color)
      .rigid()
    let row = NSStackView.horizontal([dot, label], spacing: 5)
    row.setClippingResistancePriority(.required, for: .horizontal)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 5),
      dot.heightAnchor.constraint(equalToConstant: 5),
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 9),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.heightAnchor.constraint(equalToConstant: 18),
      self.widthAnchor.constraint(
        equalToConstant: ceil(label.intrinsicContentSize.width) + 29),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

/// Percentage, reset timing, meter, and any secondary windows.
@MainActor
private final class QuotaBlock: NSView {
  init(state: ProviderViewState, now: Date) {
    super.init(frame: .zero)
    let windows = state.snapshot?.windows ?? []
    let primary =
      windows.first { $0.label.localizedCaseInsensitiveCompare("Weekly") == .orderedSame }
      ?? windows.max(by: { $0.usedPercent < $1.usedPercent })

    // Without a snapshot there is no meter: an empty bar would read as "0% used"
    // rather than "not connected".
    guard let primary else {
      let stack = NSStackView.vertical([Self.message(state: state)], spacing: 0)
      self.install(stack)
      return
    }

    let isCritical = primary.usedPercent >= 90
    let value = DashboardLabel(
      String(format: "%.0f%%", primary.usedPercent),
      font: DashboardFont.serif(27, .semibold),
      color: isCritical ? DashboardPalette.warning : DashboardPalette.text
    ).width(Self.valueWidth)

    let detail = Self.detail(primary: primary, now: now)
    let headline = NSStackView.horizontal([value, detail], spacing: 8, alignment: .bottom)
    headline.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive =
      true

    let meter = UsageMeter(
      value: primary.usedPercent,
      color: isCritical ? DashboardPalette.warning : state.provider.accent)
    meter.heightAnchor.constraint(equalToConstant: 6).isActive = true
    meter.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true

    var rows: [NSView] = [headline, meter]
    let secondary = windows
      .filter { $0.id != primary.id }
      .sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    if !secondary.isEmpty {
      rows.append(WindowChipRow(windows: secondary, now: now))
    }

    let stack = NSStackView.vertical(rows, spacing: 8)
    stack.setCustomSpacing(6, after: headline)
    self.install(stack)
  }

  required init?(coder: NSCoder) { nil }

  private func install(_ stack: NSStackView) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  private static let valueWidth: CGFloat = 86
  private static var detailWidth: CGFloat { DashboardMetrics.cardContentWidth - valueWidth - 8 }

  /// Explains what to do when a provider has no readable limits yet.
  private static func message(state: ProviderViewState) -> DashboardLabel {
    let text: String
    let color: NSColor
    if state.isConnecting {
      text = "Finish the Claude sign-in in your browser…"
      color = DashboardPalette.muted
    } else if let error = state.error {
      text = error
      color = DashboardPalette.warning
    } else {
      switch state.provider {
      case .openAI: text = "Sign in with the Codex CLI to read your limits"
      case .anthropic: text = "Connect Claude to read your limits"
      case .grok: text = "Run grok login to read your limits"
      }
      color = DashboardPalette.muted
    }
    let label = DashboardLabel(text, font: DashboardFont.sans(10.5), color: color)
      .width(DashboardMetrics.cardContentWidth)
    label.toolTip = text
    return label
  }

  private static func detail(
    primary: UsageWindow,
    now: Date
  ) -> NSView {
    let title = DashboardLabel(
      primary.label,
      font: DashboardFont.sans(10.5, .medium),
      color: DashboardPalette.text,
      alignment: .right
    ).width(Self.detailWidth)
    let reset: String
    if let resetsAt = primary.resetsAt, resetsAt > now {
      reset =
        "resets \(DashboardFormat.countdown(to: resetsAt, now: now)) · \(DashboardFormat.shortDate(resetsAt))"
    } else {
      reset = "next reset unknown"
    }
    let subtitle = DashboardLabel(
      reset,
      font: DashboardFont.sans(9.5),
      color: DashboardPalette.muted,
      alignment: .right
    ).width(Self.detailWidth)
    subtitle.toolTip = reset
    return NSStackView.vertical([title, subtitle], spacing: 1, alignment: .trailing)
  }
}

/// Secondary quota windows, condensed into at most two chips plus an overflow
/// marker so the card height stays predictable.
@MainActor
private final class WindowChipRow: NSView {
  init(windows: [UsageWindow], now: Date) {
    super.init(frame: .zero)
    let shown = windows.prefix(2)
    var chips: [NSView] = shown.map { WindowChip(window: $0, now: now) }
    if windows.count > shown.count {
      chips.append(ChipLabel(text: "+\(windows.count - shown.count) more"))
    }
    let row = NSStackView.horizontal(chips, spacing: 6)
    row.toolTip = windows.map { window in
      let reset =
        window.resetsAt.map { "resets \(DashboardFormat.countdown(to: $0, now: now))" }
        ?? "next reset unknown"
      return "\(window.label) · \(String(format: "%.0f%%", window.usedPercent)) · \(reset)"
    }.joined(separator: "\n")
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: self.topAnchor),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class WindowChip: DashboardSurface {
  init(window: UsageWindow, now: Date) {
    super.init(fill: DashboardPalette.surface, radius: 8)
    let reset =
      window.resetsAt.map { DashboardFormat.countdown(to: $0, now: now) } ?? "reset unknown"
    let label = DashboardLabel(
      "\(window.label) · \(String(format: "%.0f%%", window.usedPercent))",
      font: DashboardFont.sans(9.5, .medium),
      color: DashboardPalette.muted)
    let trailing = DashboardLabel(
      reset, font: DashboardFont.sans(9.5), color: DashboardPalette.subtle)
    let row = NSStackView.horizontal([label, trailing], spacing: 5)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.heightAnchor.constraint(equalToConstant: 19),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ChipLabel: DashboardSurface {
  init(text: String) {
    super.init(fill: DashboardPalette.surface, radius: 8)
    let label = DashboardLabel(
      text, font: DashboardFont.sans(9.5, .medium), color: DashboardPalette.subtle)
    label.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.heightAnchor.constraint(equalToConstant: 19),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class EconomicsRow: NSView {
  init(state: ProviderViewState, isScanning: Bool) {
    super.init(frame: .zero)
    let usage = state.localUsage
    let placeholder = isScanning ? "…" : "—"
    let saved = usage.map { $0.apiEquivalentCostUSD - state.subscriptionCostUSD }
    let cells = [
      EconomicsCell(
        label: "30-day tokens",
        value: usage.map { DashboardFormat.tokens($0.totalTokens) } ?? placeholder,
        alignment: .left),
      EconomicsCell(
        label: "API value",
        value: usage.map {
          DashboardFormat.money($0.apiEquivalentCostUSD, approximate: $0.isCostEstimate)
        } ?? placeholder,
        alignment: .center),
      EconomicsCell(
        label: "Saved",
        value: saved.map { DashboardFormat.savings($0) } ?? "—",
        alignment: .right,
        color: Self.savedColor(saved)),
    ]
    let row = NSStackView.horizontal(cells, spacing: EconomicsCell.spacing, alignment: .top)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: self.topAnchor),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static func savedColor(_ saved: Double?) -> NSColor {
    guard let saved else { return DashboardPalette.subtle }
    return saved < 0 ? DashboardPalette.warning : DashboardPalette.success
  }
}

@MainActor
private final class EconomicsCell: NSView {
  init(
    label: String,
    value: String,
    alignment: NSTextAlignment,
    color: NSColor = DashboardPalette.text
  ) {
    super.init(frame: .zero)
    let caption = DashboardLabel.caption(label, alignment: alignment).width(Self.width)
    let value = DashboardLabel(
      value,
      font: DashboardFont.digits(12, .semibold),
      color: color,
      alignment: alignment
    ).width(Self.width)
    let stack = NSStackView.vertical([caption, value], spacing: 2, alignment: .leading)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  fileprivate static let spacing: CGFloat = 7
  fileprivate static var width: CGFloat {
    (DashboardMetrics.cardContentWidth - 2 * self.spacing) / 3
  }
}

@MainActor
private final class ProviderLogo: DashboardSurface {
  init(provider: ProviderID) {
    super.init(fill: provider.accent, fillAlpha: 0.12, radius: 11)
    self.identifier = NSUserInterfaceItemIdentifier("provider-logo-\(provider.rawValue)")
    let image = NSImageView(image: Self.image(provider: provider))
    image.contentTintColor = provider.accent
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: 34),
      self.heightAnchor.constraint(equalToConstant: 34),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 18),
      image.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static func image(provider: ProviderID) -> NSImage {
    let url =
      Bundle.module.url(
        forResource: provider.resourceName, withExtension: "svg", subdirectory: "Resources")
      ?? Bundle.module.url(forResource: provider.resourceName, withExtension: "svg")
    let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    image.isTemplate = true
    image.accessibilityDescription = provider.displayName
    return image
  }
}

@MainActor
private final class EmptyProvidersView: DashboardSurface {
  init(openSettings: @escaping () -> Void) {
    super.init(fill: DashboardPalette.card, stroke: DashboardPalette.border, radius: 16)
    let title = DashboardLabel(
      "No providers enabled",
      font: DashboardFont.serif(15, .semibold),
      color: DashboardPalette.text)
    let subtitle = DashboardLabel(
      "Choose which subscriptions to track.",
      font: DashboardFont.sans(10.5),
      color: DashboardPalette.muted)
    let button = DashboardTextButton(
      title: "Open Settings", symbol: "gearshape", action: openSettings)
    let stack = NSStackView.vertical([title, subtitle, button], spacing: 4, alignment: .centerX)
    stack.setCustomSpacing(10, after: subtitle)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 132),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardFooterView: NSView {
  init(actions: DashboardActions) {
    super.init(frame: .zero)
    let rule = DashboardRule(width: DashboardMetrics.contentWidth)
    let settings = DashboardTextButton(
      title: "Settings", symbol: "gearshape", action: actions.openSettings)
    settings.identifier = NSUserInterfaceItemIdentifier("open-settings")
    let quit = DashboardTextButton(
      title: "Quit", color: DashboardPalette.subtle, action: actions.quit)
    quit.identifier = NSUserInterfaceItemIdentifier("quit-app")
    let row = NSStackView.horizontal([settings, NSView(), quit], spacing: 0)
    for view in [rule, row] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      rule.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      rule.topAnchor.constraint(equalTo: self.topAnchor),
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

extension ProviderViewState {
  fileprivate var needsConnection: Bool {
    guard self.provider == .anthropic else { return false }
    guard let error = self.error?.lowercased() else { return self.snapshot == nil }
    return self.snapshot == nil
      || ["auth", "credential", "keychain", "sign in"].contains { error.contains($0) }
  }
}

enum DashboardFormat {
  static func tokens(_ value: Int64) -> String {
    let number = Double(value)
    if value >= 1_000_000_000 { return Self.compact(number / 1_000_000_000, suffix: "B") }
    if value >= 1_000_000 { return Self.compact(number / 1_000_000, suffix: "M") }
    if value >= 1_000 { return Self.compact(number / 1_000, suffix: "K") }
    return "\(value)"
  }

  static func money(_ value: Double, approximate: Bool = false) -> String {
    let prefix = approximate ? "~" : ""
    if value >= 1_000_000 {
      return prefix + Self.compact(value / 1_000_000, prefix: "$", suffix: "M")
    }
    if value >= 10_000 { return prefix + Self.compact(value / 1_000, prefix: "$", suffix: "K") }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = value < 100 ? 2 : 0
    return prefix + (formatter.string(from: NSNumber(value: value)) ?? "$—")
  }

  static func savings(_ value: Double) -> String {
    value >= 0 ? Self.money(value) : "−" + Self.money(abs(value))
  }

  static func updated(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "updated just now" }
    if seconds < 3600 { return "updated \(Int(seconds / 60))m ago" }
    return "updated \(Int(seconds / 3600))h ago"
  }

  static func countdown(to date: Date, now: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let remainder = minutes % 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(remainder)m" }
    return "in \(remainder)m"
  }

  static func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter.string(from: date)
  }

  private static func compact(
    _ value: Double,
    prefix: String = "",
    suffix: String
  ) -> String {
    let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
    return prefix + String(format: "%.*f", digits, value) + suffix
  }
}
