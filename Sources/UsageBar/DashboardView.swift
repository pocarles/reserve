import AppKit
import UsageBarCore

@MainActor
struct DashboardActions {
  let refreshAll: () -> Void
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

  override func loadView() { self.update() }

  func update() {
    self.view = UsageDashboardView(
      states: self.store.orderedStates.filter { self.store.isEnabled($0.provider) },
      isRefreshing: self.store.isRefreshingAll || self.store.isScanningLocalUsage,
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
    isRefreshing: Bool,
    now: Date,
    actions: DashboardActions
  ) {
    super.init(frame: NSRect(origin: .zero, size: DashboardMetrics.size))
    self.identifier = NSUserInterfaceItemIdentifier("usage-dashboard")
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.background.cgColor

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: self.bottomAnchor, constant: -14),
    ])

    stack.addArrangedSubview(
      DashboardHeaderView(
        states: states, isRefreshing: isRefreshing, now: now, refresh: actions.refreshAll))
    stack.addArrangedSubview(DashboardSummaryView(states: states))

    for state in states {
      let card = ProviderDashboardCard(state: state, now: now, isScanning: isRefreshing)
      card.identifier = NSUserInterfaceItemIdentifier("provider-card-\(state.provider.rawValue)")
      stack.addArrangedSubview(card)
    }
    if states.isEmpty {
      stack.addArrangedSubview(EmptyProvidersView(openSettings: actions.openSettings))
    }
    stack.addArrangedSubview(DashboardFooterView(actions: actions))
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
      size: 10.5,
      color: DashboardPalette.muted)
    let copy = NSStackView(views: [title, subtitle])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 2
    let button = DashboardButton(symbol: "arrow.clockwise", toolTip: "Refresh all", action: refresh)
    button.identifier = NSUserInterfaceItemIdentifier("refresh-all")
    for view in [copy, button] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      copy.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      copy.topAnchor.constraint(equalTo: self.topAnchor),
      copy.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      button.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      button.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 48),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static func subtitle(states: [ProviderViewState], isRefreshing: Bool, now: Date) -> String
  {
    if isRefreshing { return "Refreshing limits and 30-day local usage…" }
    let dates = states.flatMap { state in
      [state.snapshot?.fetchedAt, state.localUsage?.fetchedAt].compactMap { $0 }
    }
    guard let latest = dates.max() else { return "30-day local usage · waiting for first refresh" }
    return "30-day local usage · \(DashboardFormat.updated(latest, now: now))"
  }
}

@MainActor
private final class DashboardSummaryView: NSView {
  init(states: [ProviderViewState]) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.surface.cgColor
    self.layer?.borderColor = DashboardPalette.border.cgColor
    self.layer?.borderWidth = 1
    self.layer?.cornerRadius = 13

    let usage = states.compactMap(\.localUsage)
    let tokens = usage.reduce(Int64(0)) { $0 + $1.totalTokens }
    let apiValue = usage.reduce(0.0) { $0 + $1.apiEquivalentCostUSD }
    let subscriptions = states.reduce(0.0) { $0 + $1.subscriptionCostUSD }
    let saved = apiValue - subscriptions
    let row = NSStackView(views: [
      DashboardMetric(label: "PROVIDERS", value: "\(states.count)", detail: "tracked"),
      DashboardMetric(
        label: "TOKENS", value: DashboardFormat.tokens(tokens), detail: "last 30 days"),
      DashboardMetric(
        label: "API VALUE", value: DashboardFormat.money(apiValue), detail: "equivalent"),
      DashboardMetric(label: "SAVED", value: DashboardFormat.savings(saved), detail: "vs plans"),
    ])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fillEqually
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 4),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -4),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 70),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardMetric: NSView {
  init(label: String, value: String, detail: String) {
    super.init(frame: .zero)
    let heading = DashboardLabel(label, size: 8, weight: .medium, color: DashboardPalette.subtle)
    let value = DashboardLabel(value, size: 16, weight: .medium, color: DashboardPalette.text)
    value.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
    let detail = DashboardLabel(detail, size: 8.5, color: DashboardPalette.muted)
    for label in [heading, value, detail] {
      label.alignment = .center
      label.lineBreakMode = .byClipping
      label.widthAnchor.constraint(equalToConstant: 88).isActive = true
    }
    let stack = NSStackView(views: [heading, value, detail])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ProviderDashboardCard: NSView {
  init(state: ProviderViewState, now: Date, isScanning: Bool) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = DashboardPalette.card.cgColor
    self.layer?.borderColor = state.provider.accent.withAlphaComponent(0.30).cgColor
    self.layer?.borderWidth = 1
    self.layer?.cornerRadius = 14

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -11),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])

    stack.addArrangedSubview(Self.header(state: state))
    stack.addArrangedSubview(EconomicsRow(state: state, isScanning: isScanning))
    stack.addArrangedSubview(QuotaRow(state: state, now: now))
  }

  required init?(coder: NSCoder) { nil }

  private static func header(state: ProviderViewState) -> NSView {
    let logo = ProviderLogo(provider: state.provider)
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
    let stateLabel = DashboardLabel("●  \(status)", size: 9, weight: .medium, color: statusColor)
    let identity = NSStackView(views: [name, stateLabel])
    identity.orientation = .vertical
    identity.alignment = .leading
    identity.spacing = 1
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [logo, identity, spacer])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    if let plan = state.snapshot?.planName, !plan.isEmpty {
      row.addArrangedSubview(PillLabel(text: plan.uppercased()))
    }
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }
}

@MainActor
private final class EconomicsRow: NSView {
  init(state: ProviderViewState, isScanning: Bool) {
    super.init(frame: .zero)
    let usage = state.localUsage
    let api = usage.map {
      DashboardFormat.money($0.apiEquivalentCostUSD, approximate: $0.isCostEstimate)
    }
    let plan = DashboardFormat.money(state.subscriptionCostUSD)
    let saved = usage.map {
      DashboardFormat.savings($0.apiEquivalentCostUSD - state.subscriptionCostUSD)
    }
    let row = NSStackView(views: [
      EconomicsMetric(
        label: "TOKENS",
        value: usage.map { DashboardFormat.tokens($0.totalTokens) } ?? (isScanning ? "…" : "—")),
      EconomicsMetric(label: "API VALUE", value: api ?? (isScanning ? "…" : "—")),
      EconomicsMetric(label: "PLAN", value: plan),
      EconomicsMetric(label: "SAVED", value: saved ?? "—", highlight: true),
    ])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fillEqually
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: self.topAnchor),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
      self.heightAnchor.constraint(equalToConstant: 40),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class EconomicsMetric: NSView {
  init(label: String, value: String, highlight: Bool = false) {
    super.init(frame: .zero)
    let heading = DashboardLabel(label, size: 7.5, weight: .medium, color: DashboardPalette.subtle)
    let value = DashboardLabel(
      value, size: 11.5, weight: .semibold,
      color: highlight ? DashboardPalette.success : DashboardPalette.text)
    value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    for label in [heading, value] {
      label.alignment = .center
      label.lineBreakMode = .byClipping
      label.widthAnchor.constraint(equalToConstant: 88).isActive = true
    }
    let stack = NSStackView(views: [heading, value])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class QuotaRow: NSView {
  init(state: ProviderViewState, now: Date) {
    super.init(frame: .zero)
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = DashboardPalette.border.cgColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(divider)

    let windows = state.snapshot?.windows ?? []
    let highest = windows.max(by: { $0.usedPercent < $1.usedPercent })
    let resetDates = windows.compactMap(\.resetsAt).filter { $0 > now }
    let next = resetDates.min()
    let title: String
    let detail: String
    if let highest {
      title = "\(highest.label)  ·  \(String(format: "%.0f%%", highest.usedPercent)) used"
      let count = resetDates.count
      let noun = count == 1 ? "reset window" : "reset windows"
      detail =
        next.map {
          "\(count) \(noun) · next \(DashboardFormat.countdown(to: $0, now: now)) · \(DashboardFormat.shortDate($0))"
        } ?? "\(count) \(noun) · next reset unavailable"
    } else {
      title = "Quota unavailable"
      detail = state.error ?? "Connect this provider to read reset windows."
    }
    let heading = DashboardLabel(title, size: 9.5, weight: .medium, color: DashboardPalette.text)
    let detailLabel = DashboardLabel(
      detail, size: 8.5,
      color: state.error == nil ? DashboardPalette.muted : DashboardPalette.warning)
    detailLabel.lineBreakMode = .byTruncatingTail
    let labels = NSStackView(views: [heading, detailLabel])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 2
    labels.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(labels)

    let bar = RoundedProgressView(value: highest?.usedPercent ?? 0, color: state.provider.accent)
    bar.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(bar)
    NSLayoutConstraint.activate([
      divider.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      divider.topAnchor.constraint(equalTo: self.topAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),
      labels.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      labels.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      labels.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 7),
      bar.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      bar.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 5),
      bar.heightAnchor.constraint(equalToConstant: 5),
      bar.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
      self.heightAnchor.constraint(equalToConstant: 47),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ProviderLogo: NSView {
  init(provider: ProviderID) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("provider-logo-\(provider.rawValue)")
    self.wantsLayer = true
    self.layer?.backgroundColor = provider.accent.withAlphaComponent(0.13).cgColor
    self.layer?.cornerRadius = 9
    let image = NSImageView(image: Self.image(provider: provider))
    image.contentTintColor = provider.accent
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: 32),
      self.heightAnchor.constraint(equalToConstant: 32),
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
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 100),
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
    for view in [line, row] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      line.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      line.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      line.topAnchor.constraint(equalTo: self.topAnchor),
      line.heightAnchor.constraint(equalToConstant: 1),
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 28),
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
    self.font = .systemFont(ofSize: 8, weight: .medium)
    self.alignment = .center
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    let measured = (text as NSString).size(withAttributes: [.font: self.font as Any]).width
    self.widthAnchor.constraint(equalToConstant: min(118, max(38, measured + 18))).isActive = true
    self.heightAnchor.constraint(equalToConstant: 21).isActive = true
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
    self.font = .systemFont(ofSize: 10, weight: .medium)
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

private enum DashboardMetrics {
  static let width: CGFloat = 444
  static let height: CGFloat = 748
  static let contentWidth: CGFloat = 404
  static let cardContentWidth: CGFloat = 376
  static let size = NSSize(width: width, height: height)
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

  fileprivate var resourceName: String {
    switch self {
    case .openAI: "openai"
    case .anthropic: "anthropic"
    case .grok: "grok"
    }
  }
}

private enum DashboardFormat {
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
