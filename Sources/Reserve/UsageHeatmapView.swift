import AppKit
import ReserveCore

/// One row of daily cells for the selected Insights range.
///
/// A missing day is an outlined gap, not a zero-height bar. Zero is a flat
/// filled cell. The row names the oldest and newest dates. Hovering a cell
/// names that day, its tokens, and its cost, or says they are unknown.
@MainActor
final class UsageHeatmapView: NSView {
  private let series: InsightHistorySeries
  private var trackedCell: Int?

  init(series: InsightHistorySeries) {
    self.series = series
    super.init(frame: .zero)
    self.wantsLayer = true
    self.identifier = NSUserInterfaceItemIdentifier("insights-heatmap-\(series.provider.rawValue)")
    self.setAccessibilityElement(true)
    self.setAccessibilityLabel(Self.spoken(series))
    self.toolTip = Self.rangeCaption(series)
    self.translatesAutoresizingMaskIntoConstraints = false
    self.heightAnchor.constraint(equalToConstant: 28).isActive = true
    self.addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.activeAlways, .mouseMoved, .inVisibleRect],
      owner: self,
      userInfo: nil))
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    let days = self.series.days
    guard !days.isEmpty else { return }
    let layout = Self.layout(dayCount: days.count, width: self.bounds.width)
    let peak = days.compactMap(\.tokens).max() ?? 0
    for (index, day) in days.enumerated() {
      let rect = Self.cellRect(index: index, layout: layout, height: self.bounds.height)
      guard rect.maxX <= self.bounds.width + 0.5 else { continue }
      let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
      if let tokens = day.tokens {
        let fraction = peak > 0 ? CGFloat(tokens) / CGFloat(peak) : 0
        let alpha = tokens == 0 ? 0.18 : 0.25 + 0.75 * min(1, fraction)
        ReserveColor.chartPrimary.withAlphaComponent(alpha).setFill()
        path.fill()
      } else {
        ReserveColor.subtle.setStroke()
        path.lineWidth = 1
        path.stroke()
      }
    }
  }

  override func mouseMoved(with event: NSEvent) {
    let point = self.convert(event.locationInWindow, from: nil)
    let index = Self.cellIndex(at: point.x, dayCount: self.series.days.count, width: self.bounds.width)
    guard index != self.trackedCell else { return }
    self.trackedCell = index
    if let index, self.series.days.indices.contains(index) {
      let day = self.series.days[index]
      self.toolTip = Self.dayCaption(day)
      self.setAccessibilityLabel("\(Self.spoken(self.series)) \(Self.dayCaption(day))")
    } else {
      self.toolTip = Self.rangeCaption(self.series)
      self.setAccessibilityLabel(Self.spoken(self.series))
    }
  }

  /// Test hook. Production hover uses the same caption.
  func dayCaptionForTesting(at index: Int) -> String? {
    guard self.series.days.indices.contains(index) else { return nil }
    return Self.dayCaption(self.series.days[index])
  }

  static func cellIndex(at x: CGFloat, dayCount: Int, width: CGFloat) -> Int? {
    guard dayCount > 0, width > 0 else { return nil }
    let layout = Self.layout(dayCount: dayCount, width: width)
    let stride = layout.cell + layout.gap
    guard stride > 0 else { return nil }
    let index = Int(x / stride)
    guard index >= 0, index < dayCount else { return nil }
    let origin = CGFloat(index) * stride
    guard x <= origin + layout.cell + 0.5 else { return nil }
    return index
  }

  static func layout(dayCount: Int, width: CGFloat) -> (cell: CGFloat, gap: CGFloat) {
    guard dayCount > 0 else { return (0, 0) }
    let gap: CGFloat = dayCount > 40 ? 1 : 2
    let available = max(0, width - gap * CGFloat(max(0, dayCount - 1)))
    let cell = min(8, max(2, available / CGFloat(dayCount)))
    return (cell, gap)
  }

  private static func cellRect(
    index: Int, layout: (cell: CGFloat, gap: CGFloat), height: CGFloat
  ) -> NSRect {
    let x = CGFloat(index) * (layout.cell + layout.gap)
    return NSRect(x: x, y: 4, width: layout.cell, height: min(18, max(8, height - 8)))
  }

  static func rangeCaption(_ series: InsightHistorySeries) -> String {
    guard let first = series.days.first?.day, let last = series.days.last?.day else {
      return Self.spoken(series)
    }
    return "\(Self.spoken(series)) Oldest \(first), newest \(last)."
  }

  static func dayCaption(_ day: InsightHistoryDay) -> String {
    let tokens: String
    if let value = day.tokens {
      tokens = "\(DashboardFormat.tokens(value)) tokens"
    } else {
      tokens = "tokens unknown"
    }
    let cost: String
    if let value = day.costUSD, value.isFinite {
      cost = "≈ \(DashboardFormat.money(value))"
    } else {
      cost = "cost unknown"
    }
    let kind = day.tokens == nil ? "missing day, not zero" : (day.tokens == 0 ? "zero" : "cached day")
    return "\(day.day), \(kind), \(tokens), \(cost)"
  }

  static func spoken(_ series: InsightHistorySeries) -> String {
    if !series.available {
      return "\(series.provider.displayName) daily history unavailable"
    }
    let missing = series.requestedDays - series.coveredDays
    let dates: String
    if let first = series.days.first?.day, let last = series.days.last?.day {
      dates = " From \(first) to \(last)."
    } else {
      dates = ""
    }
    return "\(series.provider.displayName), \(series.coveredDays) of \(series.requestedDays) days cached, \(missing) missing. A missing day is not zero.\(dates)"
  }
}
