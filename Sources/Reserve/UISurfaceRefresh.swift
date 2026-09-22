import Foundation

/// Collapses a burst of UI invalidations into one pass on the next main-run-loop
/// turn. The scheduled pass always runs, and it reads current model state when
/// it runs, so a burst cannot leave a stale frame waiting for a later event.
@MainActor
final class UISurfaceRefresh {
  private var scheduled = false
  private var work: (() -> Void)?

  func coalesce(_ work: @escaping () -> Void) {
    self.work = work
    guard !self.scheduled else { return }
    self.scheduled = true
    // Common run-loop modes also deliver during AppKit tracking and modal
    // loops, where main-dispatch work can otherwise wait until interaction ends.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated { self?.flush() }
    }
  }

  /// Runs a waiting pass immediately. Used when a surface becomes visible or
  /// editing ends, so the latest state is applied without another model event.
  func flush() {
    self.scheduled = false
    let work = self.work
    self.work = nil
    work?()
  }
}

/// Upper bounds for the developer stress gate. They leave room for allocator
/// noise and a slow CI machine. They are not a measure of drawing speed.
enum UIPerformanceBudget {
  static let sustainedFootprintGrowthBytes: UInt64 = 40 * 1_048_576
  static let openCloseCycles = 30
  static let cachedContentIterations = 8
  /// One cached dashboard update past this is treated as a hitch.
  static let cachedUpdateHitchSeconds: TimeInterval = 1.5
}
