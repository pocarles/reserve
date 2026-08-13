import AppKit
import UsageBarCore

@MainActor
struct DashboardActions {
  let refreshAll: () -> Void
  let refreshProvider: (ProviderID) -> Void
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
    self.preferredContentSize = NSSize(
      width: DashboardMetrics.width, height: DashboardMetrics.height)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    self.view = UsageDashboardView(
      states: self.store.orderedStates.filter { self.store.isEnabled($0.provider) },
      isRefreshingAll: self.store.isRefreshingAll,
      now: Date(),
      actions: self.actions)
  }

  func update() {
    guard self.isViewLoaded else { return }
    self.view = UsageDashboardView(
      states: self.store.orderedStates.filter { self.store.isEnabled($0.provider) },
      isRefreshingAll: self.store.isRefreshingAll,
      now: Date(),
      actions: self.actions)
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

@MainActor
final class UsageDashboardView: NSView {
  init(
    states: [ProviderViewState],
    isRefreshingAll: Bool,
    now: Date,
    actions: DashboardActions
  ) {
    super.init(
      frame: NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: DashboardMetrics.height))
    self.identifier = NSUserInterfaceItemIdentifier("usage-dashboard")
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.background.cgColor

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(scroll)

    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)

    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: self.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
    ])

    stack.addArrangedSubview(
      DashboardHeaderView(states: states, isRefreshing: isRefreshingAll, now: now) {
        actions.refreshAll()
      })
    stack.addArrangedSubview(DashboardSummaryView(states: states, now: now))

    let section = NSStackView()
    section.orientation = .horizontal
    section.alignment = .centerY
    let providers = DashboardLabel(
      "PROVIDERS", size: 10, weight: .medium, color: DashboardPalette.muted)
    providers.identifier = NSUserInterfaceItemIdentifier("providers-heading")
    section.addArrangedSubview(providers)
    section.addArrangedSubview(NSView())
    section.addArrangedSubview(
      DashboardLabel("CURRENT CYCLE", size: 10, weight: .medium, color: DashboardPalette.subtle))
    section.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth).isActive = true
    stack.addArrangedSubview(section)

    for state in states {
      let card = ProviderDashboardCard(state: state, now: now) {
        actions.refreshProvider(state.provider)
      }
      card.identifier = NSUserInterfaceItemIdentifier("provider-card-\(state.provider.rawValue)")
      stack.addArrangedSubview(card)
    }

    if states.isEmpty {
      stack.addArrangedSubview(EmptyProvidersView(openSettings: actions.openSettings))
    }

    stack.addArrangedSubview(DashboardFooterView(actions: actions))
    self.layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardHeaderView: NSView {
  init(states: [ProviderViewState], isRefreshing: Bool, now: Date, refresh: @escaping () -> Void) {
    super.init(frame: .zero)
    let title = DashboardLabel("Usage", size: 22, weight: .semibold, color: DashboardPalette.text)
    let subtitle = DashboardLabel(
      Self.subtitle(states: states, isRefreshing: isRefreshing, now: now),
      size: 11,
      color: DashboardPalette.muted)
    let copy = NSStackView(views: [title, subtitle])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 4

    let button = DashboardButton(symbol: "arrow.clockwise", toolTip: "Refresh all", action: refresh)
    button.identifier = NSUserInterfaceItemIdentifier("refresh-all")

    self.addSubview(copy)
    self.addSubview(button)
    copy.translatesAutoresizingMaskIntoConstraints = false
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      copy.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      copy.topAnchor.constraint(equalTo: self.topAnchor),
      copy.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      button.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      button.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: 34),
      button.heightAnchor.constraint(equalToConstant: 30),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static func subtitle(states: [ProviderViewState], isRefreshing: Bool, now: Date) -> String
  {
    if isRefreshing { return "Refreshing subscription limits…" }
    guard let latest = states.compactMap({ $0.snapshot?.fetchedAt }).max() else {
      return "Subscription limits · waiting for first refresh"
    }
    return "Subscription limits · \(DashboardFormat.updated(latest, now: now))"
  }
}

@MainActor
private final class DashboardSummaryView: NSView {
  init(states: [ProviderViewState], now: Date) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.surface.cgColor
    self.layer?.borderColor = DashboardPalette.border.cgColor
    self.layer?.borderWidth = 1
    self.layer?.cornerRadius = 13

    let snapshots = states.compactMap(\.snapshot)
    let live = states.filter { $0.snapshot != nil && $0.error == nil }.count
    let windows = snapshots.flatMap(\.windows)
    let nextReset = windows.compactMap(\.resetsAt).filter { $0 > now }.min()
    let peak = windows.map(\.usedPercent).max()

    let row = NSStackView(views: [
      DashboardMetric(
        label: "LIVE", value: "\(live)/\(states.count)",
        detail: live == states.count ? "connected" : "available"),
      DashboardMetric(label: "LIMITS", value: "\(windows.count)", detail: "tracked"),
      DashboardMetric(
        label: "NEXT RESET",
        value: nextReset.map { DashboardFormat.summaryCountdown(to: $0, now: now) } ?? "—",
        detail: "soonest"),
      DashboardMetric(
        label: "PEAK USED", value: peak.map { String(format: "%.0f%%", $0) } ?? "—",
        detail: "highest"),
    ])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fillEqually
    row.spacing = 0
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 4),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -4),
      row.topAnchor.constraint(equalTo: self.topAnchor, constant: 13),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -13),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 78),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardMetric: NSView {
  init(label: String, value: String, detail: String) {
    super.init(frame: .zero)
    let labelView = DashboardLabel(
      label, size: 8.5, weight: .medium, color: DashboardPalette.subtle)
    let valueView = DashboardLabel(value, size: 17, weight: .medium, color: DashboardPalette.text)
    valueView.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
    let detailView = DashboardLabel(detail, size: 9, color: DashboardPalette.muted)
    for label in [labelView, valueView, detailView] {
      label.alignment = .center
      label.lineBreakMode = .byClipping
      label.widthAnchor.constraint(equalToConstant: 88).isActive = true
    }
    if label == "NEXT RESET" {
      valueView.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    }
    let stack = NSStackView(views: [labelView, valueView, detailView])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 3
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ProviderDashboardCard: NSView {
  init(state: ProviderViewState, now: Date, refresh: @escaping () -> Void) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.card.cgColor
    self.layer?.borderColor = state.provider.accent.withAlphaComponent(0.28).cgColor
    self.layer?.borderWidth = 1
    self.layer?.cornerRadius = 15

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -16),
      content.topAnchor.constraint(equalTo: self.topAnchor, constant: 15),
      content.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -14),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])

    content.addArrangedSubview(self.header(state: state, refresh: refresh))
    if let snapshot = state.snapshot, let primary = snapshot.windows.first {
      content.addArrangedSubview(
        PrimaryUsageView(window: primary, accent: state.provider.accent, now: now))
      for window in snapshot.windows.dropFirst() {
        content.addArrangedSubview(
          CompactUsageView(window: window, accent: state.provider.accent, now: now))
      }
      if let spend = snapshot.includedSpend {
        content.addArrangedSubview(IncludedSpendView(spend: spend, accent: state.provider.accent))
      }
      if let error = state.error {
        content.addArrangedSubview(
          StatusMessageView(
            symbol: "clock.arrow.circlepath",
            text: "Saved data · \(error)",
            color: DashboardPalette.warning))
      }
      content.addArrangedSubview(self.metadata(snapshot: snapshot, stale: state.isStale, now: now))
    } else if state.isRefreshing {
      content.addArrangedSubview(
        StatusMessageView(
          symbol: "arrow.triangle.2.circlepath",
          text: "Checking subscription usage…",
          color: state.provider.accent))
    } else {
      content.addArrangedSubview(
        StatusMessageView(
          symbol: "exclamationmark.circle",
          text: state.error ?? "No usage snapshot is available yet.",
          color: DashboardPalette.warning))
    }
  }

  required init?(coder: NSCoder) { nil }

  private func header(state: ProviderViewState, refresh: @escaping () -> Void) -> NSView {
    let mark = ProviderMark(provider: state.provider)
    let name = DashboardLabel(
      state.provider.displayName, size: 13, weight: .semibold, color: DashboardPalette.text)
    let status: String
    let statusColor: NSColor
    if state.isRefreshing {
      status = "Refreshing"
      statusColor = state.provider.accent
    } else if state.snapshot != nil && state.error == nil {
      status = "Live"
      statusColor = DashboardPalette.success
    } else if state.snapshot != nil {
      status = "Saved"
      statusColor = DashboardPalette.warning
    } else {
      status = "Connect"
      statusColor = DashboardPalette.warning
    }
    let stateLabel = DashboardLabel("●  \(status)", size: 9.5, weight: .medium, color: statusColor)
    let identity = NSStackView(views: [name, stateLabel])
    identity.orientation = .vertical
    identity.alignment = .leading
    identity.spacing = 2

    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    row.addArrangedSubview(mark)
    row.addArrangedSubview(identity)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(spacer)
    if let plan = state.snapshot?.planName, !plan.isEmpty {
      let pill = PillLabel(text: plan.uppercased())
      pill.setContentHuggingPriority(.required, for: .horizontal)
      pill.setContentCompressionResistancePriority(.required, for: .horizontal)
      row.addArrangedSubview(pill)
    }
    let button = DashboardButton(
      symbol: "arrow.clockwise", toolTip: "Refresh \(state.provider.displayName)", action: refresh)
    button.identifier = NSUserInterfaceItemIdentifier("refresh-\(state.provider.rawValue)")
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    row.addArrangedSubview(button)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }

  private func metadata(snapshot: UsageSnapshot, stale: Bool, now: Date) -> NSView {
    let source = DashboardLabel(snapshot.source, size: 9, color: DashboardPalette.subtle)
    source.lineBreakMode = .byTruncatingTail
    let updated = DashboardLabel(
      DashboardFormat.age(snapshot.fetchedAt, now: now) + (stale ? " · saved" : ""),
      size: 9,
      color: stale ? DashboardPalette.warning : DashboardPalette.subtle)
    updated.alignment = .right
    let row = NSStackView(views: [source, NSView(), updated])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }
}

@MainActor
private final class PrimaryUsageView: NSView {
  init(window: UsageWindow, accent: NSColor, now: Date) {
    super.init(frame: .zero)
    let label = DashboardLabel(
      window.label.uppercased(), size: 9, weight: .medium, color: DashboardPalette.muted)
    let used = DashboardLabel(
      String(format: "%.0f%%", window.usedPercent), size: 30, weight: .medium,
      color: DashboardPalette.text)
    used.font = .monospacedDigitSystemFont(ofSize: 30, weight: .medium)
    let remaining = DashboardLabel(
      String(format: "%.0f%% remaining", max(0, 100 - window.usedPercent)),
      size: 10,
      color: DashboardPalette.muted)
    remaining.alignment = .right

    let bar = RoundedProgressView(value: window.usedPercent, color: accent)
    let reset = DashboardLabel(
      DashboardFormat.reset(window, now: now), size: 10, color: DashboardPalette.muted)
    let duration = DashboardLabel(
      DashboardFormat.windowDuration(window.windowMinutes), size: 9, color: DashboardPalette.subtle)
    duration.alignment = .right
    duration.setContentHuggingPriority(.required, for: .horizontal)
    duration.setContentCompressionResistancePriority(.required, for: .horizontal)
    duration.widthAnchor.constraint(equalToConstant: 62).isActive = true

    for view in [label, used, remaining, bar, reset, duration] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      label.topAnchor.constraint(equalTo: self.topAnchor),
      used.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      used.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
      remaining.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      remaining.firstBaselineAnchor.constraint(equalTo: used.firstBaselineAnchor),
      bar.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      bar.topAnchor.constraint(equalTo: used.bottomAnchor, constant: 8),
      bar.heightAnchor.constraint(equalToConstant: 7),
      reset.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      reset.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 7),
      duration.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      duration.firstBaselineAnchor.constraint(equalTo: reset.firstBaselineAnchor),
      reset.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class CompactUsageView: NSView {
  init(window: UsageWindow, accent: NSColor, now: Date) {
    super.init(frame: .zero)
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = DashboardPalette.border.cgColor
    let label = DashboardLabel(
      window.label, size: 10.5, weight: .medium, color: DashboardPalette.text)
    let value = DashboardLabel(
      String(format: "%.0f%%", window.usedPercent), size: 10.5, weight: .semibold,
      color: DashboardPalette.text)
    value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    value.alignment = .right
    let bar = RoundedProgressView(value: window.usedPercent, color: accent)
    let reset = DashboardLabel(
      DashboardFormat.compactReset(window, now: now), size: 9, color: DashboardPalette.subtle)

    for view in [divider, label, value, bar, reset] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      divider.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      divider.topAnchor.constraint(equalTo: self.topAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),
      label.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      label.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 9),
      value.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      value.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
      bar.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
      bar.heightAnchor.constraint(equalToConstant: 5),
      reset.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      reset.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 5),
      reset.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class IncludedSpendView: NSView {
  init(spend: IncludedSpend, accent: NSColor) {
    super.init(frame: .zero)
    let percent =
      spend.limitMinorUnits > 0
      ? Double(spend.usedMinorUnits) / Double(spend.limitMinorUnits) * 100
      : 0
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = DashboardPalette.border.cgColor
    let label = DashboardLabel(
      spend.label, size: 10.5, weight: .medium, color: DashboardPalette.text)
    let amount = DashboardLabel(
      "\(DashboardFormat.money(spend.usedMinorUnits, currency: spend.currencyCode)) / \(DashboardFormat.money(spend.limitMinorUnits, currency: spend.currencyCode))",
      size: 10.5,
      weight: .medium,
      color: DashboardPalette.text)
    amount.alignment = .right
    amount.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    amount.lineBreakMode = .byClipping
    amount.setContentHuggingPriority(.required, for: .horizontal)
    amount.setContentCompressionResistancePriority(.required, for: .horizontal)
    amount.widthAnchor.constraint(equalToConstant: 126).isActive = true
    let bar = RoundedProgressView(value: percent, color: accent)
    let detail = DashboardLabel(
      String(format: "%.0f%% used", percent), size: 9, color: DashboardPalette.subtle)
    detail.alignment = .left
    for view in [divider, label, amount, bar, detail] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      divider.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      divider.topAnchor.constraint(equalTo: self.topAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),
      label.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      label.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 9),
      amount.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      amount.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
      bar.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
      bar.heightAnchor.constraint(equalToConstant: 5),
      detail.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 5),
      detail.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class StatusMessageView: NSView {
  init(symbol: String, text: String, color: NSColor) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
    self.layer?.cornerRadius = 9
    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = color
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 10)
    label.textColor = DashboardPalette.muted
    label.maximumNumberOfLines = 3
    icon.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(icon)
    self.addSubview(label)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 14),
      icon.heightAnchor.constraint(equalToConstant: 14),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
      label.topAnchor.constraint(equalTo: self.topAnchor, constant: 9),
      label.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -9),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class EmptyProvidersView: NSView {
  init(openSettings: @escaping () -> Void) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.card.cgColor
    self.layer?.borderColor = DashboardPalette.border.cgColor
    self.layer?.borderWidth = 1
    self.layer?.cornerRadius = 14
    let label = DashboardLabel(
      "No providers are enabled.", size: 12, weight: .medium, color: DashboardPalette.text)
    let button = DashboardTextButton(title: "Open Settings", action: openSettings)
    let stack = NSStackView(views: [label, button])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 110),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardFooterView: NSView {
  init(actions: DashboardActions) {
    super.init(frame: .zero)
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = DashboardPalette.border.cgColor
    let settings = DashboardTextButton(
      title: "Settings", symbol: "gearshape", action: actions.openSettings)
    settings.identifier = NSUserInterfaceItemIdentifier("open-settings")
    let quit = DashboardTextButton(title: "Quit", action: actions.quit)
    quit.identifier = NSUserInterfaceItemIdentifier("quit-app")
    let row = NSStackView(views: [settings, NSView(), quit])
    row.orientation = .horizontal
    row.alignment = .centerY
    line.translatesAutoresizingMaskIntoConstraints = false
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(line)
    self.addSubview(row)
    NSLayoutConstraint.activate([
      line.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      line.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      line.topAnchor.constraint(equalTo: self.topAnchor),
      line.heightAnchor.constraint(equalToConstant: 1),
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ProviderMark: NSView {
  init(provider: ProviderID) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = provider.accent.withAlphaComponent(0.13).cgColor
    self.layer?.cornerRadius = 10
    let image = NSImageView(
      image: NSImage(
        systemSymbolName: provider.symbol, accessibilityDescription: provider.displayName)
        ?? NSImage())
    image.contentTintColor = provider.accent
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: 34),
      self.heightAnchor.constraint(equalToConstant: 34),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 17),
      image.heightAnchor.constraint(equalToConstant: 17),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class PillLabel: NSTextField {
  init(text: String) {
    super.init(frame: .zero)
    self.stringValue = text
    self.isEditable = false
    self.isSelectable = false
    self.isBezeled = false
    self.drawsBackground = true
    self.backgroundColor = DashboardPalette.surfaceRaised
    self.textColor = DashboardPalette.muted
    self.font = .systemFont(ofSize: 8.5, weight: .medium)
    self.alignment = .center
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    self.heightAnchor.constraint(equalToConstant: 22).isActive = true
    let measured = (text as NSString).size(withAttributes: [.font: self.font as Any]).width
    self.widthAnchor.constraint(equalToConstant: min(112, max(38, measured + 18))).isActive = true
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class RoundedProgressView: NSView {
  private let value: Double
  private let color: NSColor

  init(value: Double, color: NSColor) {
    self.value = min(100, max(0, value))
    self.color = color
    super.init(frame: .zero)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let radius = self.bounds.height / 2
    DashboardPalette.track.setFill()
    NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius).fill()
    guard self.value > 0 else { return }
    var fill = self.bounds
    fill.size.width = max(self.bounds.height, self.bounds.width * self.value / 100)
    self.color.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
  }
}

@MainActor
private final class DashboardButton: NSButton {
  private let handler: () -> Void

  init(symbol: String, toolTip: String, action: @escaping () -> Void) {
    self.handler = action
    super.init(frame: .zero)
    self.title = ""
    self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
    self.contentTintColor = DashboardPalette.muted
    self.toolTip = toolTip
    self.isBordered = false
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.surfaceRaised.cgColor
    self.layer?.borderColor = DashboardPalette.border.cgColor
    self.layer?.borderWidth = 1
    self.layer?.cornerRadius = 8
    self.target = self
    self.action = #selector(self.performAction)
    self.widthAnchor.constraint(equalToConstant: 30).isActive = true
    self.heightAnchor.constraint(equalToConstant: 28).isActive = true
  }

  required init?(coder: NSCoder) { nil }
  @objc private func performAction() { self.handler() }
}

@MainActor
private final class DashboardTextButton: NSButton {
  private let handler: () -> Void

  init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
    self.handler = action
    super.init(frame: .zero)
    self.title = title
    self.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
    self.imagePosition = symbol == nil ? .noImage : .imageLeading
    self.font = .systemFont(ofSize: 10.5, weight: .medium)
    self.contentTintColor = DashboardPalette.muted
    self.isBordered = false
    self.target = self
    self.action = #selector(self.performAction)
  }

  required init?(coder: NSCoder) { nil }
  @objc private func performAction() { self.handler() }
}

@MainActor
private final class DashboardLabel: NSTextField {
  init(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    super.init(frame: .zero)
    self.stringValue = text
    self.isEditable = false
    self.isSelectable = false
    self.isBezeled = false
    self.drawsBackground = false
    self.font = .systemFont(ofSize: size, weight: weight)
    self.textColor = color
    self.lineBreakMode = .byTruncatingTail
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

private enum DashboardMetrics {
  static let width: CGFloat = 444
  static let height: CGFloat = 700
  static let contentWidth: CGFloat = 400
  static let cardContentWidth: CGFloat = 368
}

private enum DashboardPalette {
  static let background = NSColor(calibratedRed: 0.105, green: 0.078, blue: 0.070, alpha: 1)
  static let surface = NSColor(calibratedRed: 0.145, green: 0.108, blue: 0.095, alpha: 1)
  static let surfaceRaised = NSColor(calibratedRed: 0.195, green: 0.140, blue: 0.116, alpha: 1)
  static let card = NSColor(calibratedRed: 0.128, green: 0.094, blue: 0.083, alpha: 1)
  static let border = NSColor(calibratedRed: 0.315, green: 0.226, blue: 0.188, alpha: 0.72)
  static let track = NSColor(calibratedRed: 0.245, green: 0.174, blue: 0.145, alpha: 0.72)
  static let text = NSColor(calibratedWhite: 0.96, alpha: 1)
  static let muted = NSColor(calibratedWhite: 0.63, alpha: 1)
  static let subtle = NSColor(calibratedWhite: 0.45, alpha: 1)
  static let success = NSColor(calibratedRed: 0.46, green: 0.78, blue: 0.60, alpha: 1)
  static let warning = NSColor(calibratedRed: 0.92, green: 0.57, blue: 0.33, alpha: 1)
}

extension ProviderID {
  fileprivate var accent: NSColor {
    switch self {
    case .openAI: NSColor(calibratedWhite: 0.92, alpha: 1)
    case .anthropic: NSColor(calibratedRed: 0.91, green: 0.39, blue: 0.22, alpha: 1)
    case .grok: NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.91, alpha: 1)
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .openAI: "circle.hexagongrid.fill"
    case .anthropic: "sun.max.fill"
    case .grok: "xmark"
    }
  }
}

private enum DashboardFormat {
  static func reset(_ window: UsageWindow, now: Date) -> String {
    guard let date = window.resetsAt else { return "Reset time unavailable" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, h:mm a"
    let absolute = formatter.string(from: date)
    return "Resets \(self.compactCountdown(to: date, now: now)) · \(absolute)"
  }

  static func compactReset(_ window: UsageWindow, now: Date) -> String {
    guard let date = window.resetsAt else { return "Reset unavailable" }
    return "Resets \(self.compactCountdown(to: date, now: now))"
  }

  static func compactCountdown(to date: Date, now: Date) -> String {
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return "due" }
    let minutes = max(1, Int(seconds / 60))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let remainder = minutes % 60
    if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
    if hours > 0 { return remainder > 0 ? "in \(hours)h \(remainder)m" : "in \(hours)h" }
    return "in \(remainder)m"
  }

  static func summaryCountdown(to date: Date, now: Date) -> String {
    self.compactCountdown(to: date, now: now).replacingOccurrences(of: "in ", with: "")
  }

  static func updated(_ date: Date, now: Date) -> String {
    "updated \(self.age(date, now: now))"
  }

  static func age(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
    return "\(Int(seconds / 86400))d ago"
  }

  static func windowDuration(_ minutes: Int?) -> String {
    guard let minutes else { return "Rolling limit" }
    if minutes % 10080 == 0 { return "\(minutes / 10080)w window" }
    if minutes % 1440 == 0 { return "\(minutes / 1440)d window" }
    if minutes % 60 == 0 { return "\(minutes / 60)h window" }
    return "\(minutes)m window"
  }

  static func money(_ minorUnits: Int, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.maximumFractionDigits = minorUnits % 100 == 0 ? 0 : 2
    return formatter.string(from: NSNumber(value: Double(minorUnits) / 100)) ?? "—"
  }
}
