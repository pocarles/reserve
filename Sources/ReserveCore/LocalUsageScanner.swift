import CryptoKit
import Darwin
import Foundation

/// One day of locally observed usage. The scanner already keeps these totals
/// per file; this is the roll-up the interface can chart.
public struct DailyUsage: Codable, Equatable, Sendable, Identifiable {
  /// yyyy-MM-dd, so days sort lexically.
  public let day: String
  public let tokens: Int64

  public var id: String { self.day }

  public init(day: String, tokens: Int64) {
    self.day = day
    self.tokens = max(0, tokens)
  }
}

public enum UsageInsightOrigin: String, Codable, Equatable, Sendable {
  case localDevice
  case providerAccount
}

public struct ModelUsageCost: Codable, Equatable, Sendable, Identifiable {
  public let model: String
  public let inputTokens: Int64
  public let cachedInputTokens: Int64
  public let cacheWriteInputTokens: Int64
  public let outputTokens: Int64
  public let costUSD: Double

  public var id: String { self.model }

  public init(
    model: String,
    inputTokens: Int64,
    cachedInputTokens: Int64,
    cacheWriteInputTokens: Int64,
    outputTokens: Int64,
    costUSD: Double
  ) {
    self.model = String(model.prefix(128))
    self.inputTokens = max(0, inputTokens)
    self.cachedInputTokens = max(0, cachedInputTokens)
    self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
    self.outputTokens = max(0, outputTokens)
    self.costUSD = costUSD.isFinite ? max(0, costUSD) : 0
  }
}

public struct LocalUsageSummary: Codable, Equatable, Sendable {
  public let provider: ProviderID
  public let periodDays: Int
  public let inputTokens: Int64
  public let cachedInputTokens: Int64
  public let cacheWriteInputTokens: Int64
  public let outputTokens: Int64
  public let apiEquivalentCostUSD: Double
  public let isCostEstimate: Bool
  public let todayTokens: Int64
  public let cycleTokens: Int64
  public let cycleAPIEquivalentCostUSD: Double
  public let cycleStartedAt: Date
  public let isCycleCostEstimate: Bool
  public let fetchedAt: Date
  public let source: String
  public let origin: UsageInsightOrigin
  public let modelCosts: [ModelUsageCost]
  /// Oldest first, one entry per day of the period including quiet days.
  public let dailyTokens: [DailyUsage]

  public init(
    provider: ProviderID,
    periodDays: Int,
    inputTokens: Int64,
    cachedInputTokens: Int64 = 0,
    cacheWriteInputTokens: Int64 = 0,
    outputTokens: Int64,
    apiEquivalentCostUSD: Double,
    isCostEstimate: Bool = false,
    todayTokens: Int64? = nil,
    cycleTokens: Int64? = nil,
    cycleAPIEquivalentCostUSD: Double? = nil,
    cycleStartedAt: Date? = nil,
    isCycleCostEstimate: Bool? = nil,
    fetchedAt: Date = Date(),
    source: String = "Local session logs",
    origin: UsageInsightOrigin = .localDevice,
    modelCosts: [ModelUsageCost] = [],
    dailyTokens: [DailyUsage] = []
  ) {
    let normalizedInput = max(0, inputTokens)
    let normalizedCached = max(0, cachedInputTokens)
    let normalizedCacheWrite = max(0, cacheWriteInputTokens)
    let normalizedOutput = max(0, outputTokens)
    let fallbackTokens = saturatingNonnegativeSum(
      normalizedInput, provider == .anthropic || provider == .cursor ? normalizedCached : 0,
      normalizedCacheWrite, normalizedOutput)
    self.provider = provider
    self.periodDays = periodDays
    self.inputTokens = normalizedInput
    self.cachedInputTokens = normalizedCached
    self.cacheWriteInputTokens = normalizedCacheWrite
    self.outputTokens = normalizedOutput
    self.apiEquivalentCostUSD = max(0, apiEquivalentCostUSD)
    self.isCostEstimate = isCostEstimate
    self.todayTokens = max(0, todayTokens ?? fallbackTokens)
    self.cycleTokens = max(0, cycleTokens ?? fallbackTokens)
    self.cycleAPIEquivalentCostUSD = max(0, cycleAPIEquivalentCostUSD ?? apiEquivalentCostUSD)
    self.cycleStartedAt = cycleStartedAt ?? fetchedAt
    self.isCycleCostEstimate = isCycleCostEstimate ?? isCostEstimate
    self.fetchedAt = fetchedAt
    self.dailyTokens = dailyTokens
    self.source = source
    self.origin = origin
    self.modelCosts = Array(modelCosts.prefix(128))
  }

  public var totalTokens: Int64 {
    self.totalTokensValue
  }

  private var totalTokensValue: Int64 {
    saturatingNonnegativeSum(
      self.inputTokens,
      self.provider == .anthropic || self.provider == .cursor ? self.cachedInputTokens : 0,
      self.cacheWriteInputTokens, self.outputTokens)
  }
}

private final class IndexBox {
  var index: UsageIndex
  init(_ index: UsageIndex) { self.index = index }
}

private enum LocalHistoryScannerInternalError: Error {
  case cacheChangedDuringScan
}

private final class ScanLedger {
  var parsedRecords: [String: CachedFile] = [:]
  var removedKeys: Set<String> = []
  var pendingRetained: Set<String> = []
  var retainedKeys: Set<String> = []
  var dirtyProviders: Set<ProviderID> = []
  var pruneProviders: Set<ProviderID> = []
  var tokens: [String: Int] = [:]
  var needsFinalize = false
  var retainedReady = false
  var indexChanged = false
}

private final class ScanBudget {
  let started: ContinuousClock.Instant
  let limit: Duration
  var commitsRemaining: Int?
  var cancelAfter: Int?
  var stopBeforePublish: Bool
  var parsed = 0
  var stopped = false
  var sharedBytes: Int?

  init(
    limit: Duration, bytes: Int?, commits: Int?, cancelAfter: Int?,
    stopBeforePublish: Bool
  ) {
    self.started = .now
    self.limit = limit
    self.sharedBytes = bytes
    self.commitsRemaining = commits
    self.cancelAfter = cancelAfter
    self.stopBeforePublish = stopBeforePublish
  }

  func providerBytes(defaultCap: Int) -> Int {
    if let shared = self.sharedBytes { return max(0, shared) }
    return defaultCap
  }

  func consume(_ count: Int, remaining: inout Int) {
    remaining -= count
    guard var shared = self.sharedBytes else { return }
    shared -= count
    self.sharedBytes = shared
    if shared <= 0 { self.stopped = true }
  }

  func markStarved() { self.stopped = true }

  func ensureTime() throws {
    try Task.checkCancellation()
    if self.stopped || self.started.duration(to: .now) >= self.limit {
      throw UsageProviderError.timedOut("local usage scan")
    }
  }

  func noteFileCommitted() throws {
    self.parsed += 1
    if let cancelAfter = self.cancelAfter, self.parsed >= cancelAfter {
      throw CancellationError()
    }
    if var remaining = self.commitsRemaining {
      remaining -= 1
      self.commitsRemaining = remaining
      if remaining <= 0 { self.stopped = true }
    }
    try self.ensureTime()
  }
}

private struct LocalHistoryFileStamp: Equatable {
  var size: Int64
  var modifiedAt: TimeInterval
  var device: UInt64
  var inode: UInt64
  var changedAt: TimeInterval

  var date: Date { Date(timeIntervalSince1970: self.modifiedAt) }

  init(_ info: stat) {
    self.size = Int64(info.st_size)
    self.modifiedAt =
      TimeInterval(info.st_mtimespec.tv_sec)
      + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    self.device = UInt64(truncatingIfNeeded: info.st_dev)
    self.inode = UInt64(info.st_ino)
    self.changedAt =
      TimeInterval(info.st_ctimespec.tv_sec)
      + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000
  }

  func matches(_ record: CachedFile?) -> Bool {
    guard let record else { return false }
    return record.size == self.size
      && record.modifiedAt == self.modifiedAt
      && record.device == self.device
      && record.inode == self.inode
      && record.changedAt == self.changedAt
  }

  func sameFile(as record: CachedFile?) -> Bool {
    guard let record else { return false }
    return record.device == self.device && record.inode == self.inode
  }
}

/// Counters for one scanner. Performance tests read these instead of timing
/// short deadlines. Values only increase for the life of the actor.
public struct LocalUsageScanMetrics: Sendable, Equatable {
  public var indexDecodes = 0
  public var indexReuses = 0
  public var treeWalks = 0
  public var filesParsed = 0
  public var sparseVisits = 0
  public var fullDiscoveries = 0
  public var warmSkips = 0
  public var checkpoints = 0
  public var resumes = 0
  public var overflowFallbacks = 0

  public init() {}
}

public actor LocalUsageScanner {
  public struct Roots: Sendable {
    public let codex: URL
    public let claude: URL
    public let grok: URL

    public init(codex: URL, claude: URL, grok: URL) {
      self.codex = codex
      self.claude = claude
      self.grok = grok
    }

    public static func defaults(
      home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Roots {
      Roots(
        codex: home.appendingPathComponent(".codex/sessions", isDirectory: true),
        claude: home.appendingPathComponent(".claude/projects", isDirectory: true),
        grok: home.appendingPathComponent(".grok/sessions", isDirectory: true))
    }
  }

  private let roots: Roots
  private let cacheURL: URL
  private let fileManager: FileManager
  private let maximumCacheBytes = 12 * 1024 * 1024
  private let maximumLineBytes = 1024 * 1024
  private let codexTailBytes = 2 * 1024 * 1024
  private let codexTailStepBytes = 256 * 1024
  private let maximumBytesPerScan = 64 * 1024 * 1024
  private let maximumBytesPerFileScan = 8 * 1024 * 1024
  private let maximumLinesPerFile = 100_000
  private let maximumScanDuration: TimeInterval = 8
  private let watchChanges: Bool
  private let changeTracker = LocalHistoryChangeTracker()
  private var fileKeys: [ProviderID: [String: String]] = [:]
  private var lastScanDates: [ProviderID: Date] = [:]
  private var residentAnchor: LocalHistoryFileAnchor?
  private var residentIndex: UsageIndex?
  private var memoryCheckpoint: LocalHistoryCheckpoint?
  private var durationOverride: Duration?
  private var byteOverride: Int?
  private var commitLimit: Int?
  private var cancelAfterParsedFiles: Int?
  private var stopBeforePublish = false
  private var beforePublishHook: (@Sendable () -> Void)?
  /// Safety net for a dropped filesystem event. Longer than the app's usual
  /// history refresh so an unchanged tree is not walked on every pass.
  private var fullDiscoveryInterval: Duration = .seconds(6 * 60 * 60)
  /// True after a time- or byte-limited pass saved a checkpoint instead of a
  /// finished snapshot. `cachedHistory` keeps returning the last finalized
  /// index. Cancellation does not set this and does not discard that snapshot.
  public private(set) var scanIncomplete = false
  public private(set) var scanMetrics = LocalUsageScanMetrics()

  /// `watchChanges` defaults to false. Existing callers keep a full walk
  /// whenever `dirtyProviders` is nil. Pass true from the long-lived store so
  /// later scans follow filesystem events instead of every selected root.
  public init(
    roots: Roots = .defaults(),
    cacheURL: URL? = nil,
    fileManager: FileManager = .default,
    watchChanges: Bool = false
  ) {
    self.roots = roots
    self.fileManager = fileManager
    self.watchChanges = watchChanges
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    self.cacheURL =
      cacheURL
      ?? support.appendingPathComponent("Reserve", isDirectory: true)
      .appendingPathComponent("local-usage-index.json")
  }

  public func scan(
    periodDays: Int = 30,
    cycleStarts: [ProviderID: Date] = [:],
    now: Date = Date(),
    providers: Set<ProviderID> = [.openAI, .anthropic, .grok],
    dirtyProviders: Set<ProviderID>? = nil
  ) throws -> [ProviderID: LocalUsageSummary] {
    let selected = providers.intersection([.openAI, .anthropic, .grok])
    if self.watchChanges {
      self.changeTracker.synchronize(roots: self.watchRoots(selected))
    }
    guard !selected.isEmpty else {
      self.releaseResidentIndex()
      return [:]
    }
    try Task.checkCancellation()
    let budget = self.makeBudget()
    let published = self.loadPublishedIndex()
    let box = IndexBox(published.index)
    let ledger = ScanLedger()
    defer { self.fileKeys.removeAll(keepingCapacity: false) }
    do {
      return try self.performScan(
        box: box, ledger: ledger, anchor: published.anchor, budget: budget,
        selected: selected, dirtyProviders: dirtyProviders, periodDays: periodDays,
        cycleStarts: cycleStarts, now: now)
    } catch is CancellationError {
      throw CancellationError()
    } catch LocalHistoryScannerInternalError.cacheChangedDuringScan {
      throw UsageProviderError.invalidResponse("local usage index changed during scan")
    } catch {
      // Cancellation leaves the published index and any earlier checkpoint
      // untouched. A budget failure keeps the records that finished.
      if !Task.isCancelled {
        self.preserveCheckpoint(ledger, anchor: published.anchor)
      }
      throw error
    }
  }

  /// Updates the native watches without scanning. The store calls this when
  /// local history or a provider is disabled so unused roots stop immediately.
  public func updateWatchedProviders(_ providers: Set<ProviderID>) {
    guard self.watchChanges else { return }
    let selected = providers.intersection([.openAI, .anthropic, .grok])
    self.changeTracker.synchronize(roots: self.watchRoots(selected))
    if selected.isEmpty { self.releaseResidentIndex() }
  }

  public func stopWatching() {
    guard self.watchChanges else { return }
    self.changeTracker.synchronize(roots: [:])
    self.releaseResidentIndex()
  }

  private func releaseResidentIndex() {
    self.residentIndex = nil
    self.residentAnchor = nil
    self.memoryCheckpoint = nil
    self.fileKeys.removeAll(keepingCapacity: false)
  }

  /// Reads the on-disk index only. Does not open session roots, enumerate files,
  /// scan, or write. Archived days win; legacy `record.days` fill days the
  /// archive does not already name. Missing days stay missing — a cached file
  /// does not prove the other days in a 30-day window were zero.
  public func cachedHistory(
    periodDays: Int = 90,
    now: Date = Date(),
    providers: Set<ProviderID> = [.openAI, .anthropic, .grok]
  ) -> [ProviderID: CachedUsageHistory] {
    let selected = providers.intersection([.openAI, .anthropic, .grok])
    guard !selected.isEmpty else { return [:] }
    let index = self.loadIndex()
    let count = min(CachedUsageHistory.retentionDays, max(1, periodDays))
    // Sum every file's totals for a day. Dictionary order must not drop a file.
    var merged = Self.observedDays(index: index, providers: selected, now: index.updatedAt)
    for (provider, days) in index.dailyHistory where selected.contains(provider) {
      var byDay = merged[provider] ?? [:]
      for (key, day) in days where Self.isArchiveDayKey(key) {
        byDay[key] = day
      }
      merged[provider] = byDay
    }
    let calendar = CachedUsageHistory.civilCalendar(.current)
    let today = CachedUsageHistory.dayKey(for: now, calendar: calendar)
    let oldest = CachedUsageHistory.dayKey(daysBefore: count - 1, from: now, calendar: calendar)
    return selected.reduce(into: [:]) { result, provider in
      let rows = (merged[provider] ?? [:]).compactMap { key, day -> CachedUsageDay? in
        guard let oldest, key >= oldest, key <= today else { return nil }
        return CachedUsageDay(
          day: key, tokens: day.tokens, costUSD: day.costUSD, fetchedAt: day.fetchedAt)
      }
      result[provider] = CachedUsageHistory(provider: provider, days: rows)
    }
  }

  /// Continuous daily series for every provider, quiet days included so a chart
  /// has an even axis. One pass over the index, bounded to the period.
  private static func dailySeries(
    index: UsageIndex,
    days: Int,
    now: Date,
    deadline: Date,
    budget: ScanBudget? = nil
  ) throws -> [ProviderID: [DailyUsage]] {
    let calendar = Calendar.current
    let keys: [String] = (0..<days).reversed().compactMap { offset in
      calendar.date(byAdding: .day, value: -offset, to: now).map(Self.dayKey)
    }
    guard let cutoffKey = keys.first else { return [:] }

    var totals: [ProviderID: [String: UsageTotals]] = [:]
    for (recordIndex, record) in index.records.values.enumerated() {
      if recordIndex.isMultiple(of: 128) { try Self.checkDeadline(deadline, budget: budget) }
      for (day, value) in record.days where day >= cutoffKey {
        totals[record.provider, default: [:]][day, default: UsageTotals()].add(value)
      }
    }
    try Self.checkDeadline(deadline, budget: budget)
    return ProviderID.allCases.reduce(into: [:]) { result, provider in
      let byDay = totals[provider] ?? [:]
      result[provider] = keys.map {
        DailyUsage(day: $0, tokens: byDay[$0]?.totalTokens(provider: provider) ?? 0)
      }
    }
  }

  private static func aggregate(
    provider: ProviderID,
    since cutoffKey: String,
    index: UsageIndex,
    deadline: Date,
    budget: ScanBudget? = nil
  ) throws -> UsageTotals {
    var result = UsageTotals()
    for (recordIndex, record) in index.records.values.enumerated() {
      if recordIndex.isMultiple(of: 128) { try Self.checkDeadline(deadline, budget: budget) }
      guard record.provider == provider else { continue }
      result.add(record.totals(since: cutoffKey))
    }
    return result
  }

  private static func checkDeadline(_ deadline: Date, budget: ScanBudget? = nil) throws {
    if let budget {
      try budget.ensureTime()
      return
    }
    try Task.checkCancellation()
    guard Date() <= deadline else { throw UsageProviderError.timedOut("local usage scan") }
  }

  private func scanCodex(
    cutoff: Date,
    cutoffKey: String,
    box: IndexBox,
    ledger: ScanLedger,
    budget: ScanBudget,
    retains: Bool,
    explicitFiles: [URL]?
  ) throws -> UsageTotals {
    var total = UsageTotals()
    var remainingBytes = budget.providerBytes(defaultCap: self.maximumBytesPerScan)
    let files = try self.sessionFiles(
      explicitFiles: explicitFiles, root: self.roots.codex, named: nil, extension: "jsonl",
      cutoff: cutoff, budget: budget)
    for file in files {
      try budget.ensureTime()
      let fileTotals = try autoreleasepool { () throws -> UsageTotals in
        let metadata = try self.metadata(file)
        let key = self.fileKey(provider: .openAI, url: file)
        if retains { ledger.pendingRetained.insert(key) }
        guard box.index.records[key] != nil || box.index.records.count < Self.maximumScannedFiles
        else { return UsageTotals() }
        var record = box.index.records[key]
        if !metadata.matches(record) {
          let requiredBytes = min(self.codexTailBytes, max(0, Int(clamping: metadata.size)))
          if requiredBytes > remainingBytes {
            budget.markStarved()
            try budget.ensureTime()
          }
          // The path check above is only a cheap "anything new?" filter. What
          // gets read, and the stamp recorded for it, come from the validated
          // descriptor; a path swapped for a link, FIFO or foreign file since
          // enumeration is skipped and its previous record left as it was.
          if requiredBytes <= remainingBytes, let opened = DescriptorBoundFile.open(file),
            let metadata = Self.metadata(opened)
          {
            defer { opened.close() }
            let parsed = try self.parseCodexTail(
              opened, deadline: .distantFuture, budget: budget, remainingBytes: &remainingBytes)
            record = CachedFile(
              provider: .openAI,
              size: metadata.size,
              modifiedAt: metadata.modifiedAt,
              offset: metadata.size,
              days: parsed.map { [Self.dayKey($0.timestamp): $0.totals] } ?? [:],
              recentRows: [:],
              recentOrder: [],
              device: metadata.device,
              inode: metadata.inode,
              changedAt: metadata.changedAt)
            try self.storeParsed(record!, key: key, box: box, ledger: ledger, budget: budget)
          }
        }
        return record?.totals(since: cutoffKey) ?? UsageTotals()
      }
      total.add(fileTotals)
      try budget.ensureTime()
    }
    return total
  }

  private func scanClaude(
    cutoff: Date,
    cutoffKey: String,
    box: IndexBox,
    ledger: ScanLedger,
    budget: ScanBudget,
    retains: Bool,
    explicitFiles: [URL]?
  ) throws -> UsageTotals {
    var total = UsageTotals()
    var remainingBytes = budget.providerBytes(defaultCap: self.maximumBytesPerScan)
    let files = try self.sessionFiles(
      explicitFiles: explicitFiles, root: self.roots.claude, named: nil, extension: "jsonl",
      cutoff: cutoff, budget: budget)
    for file in files {
      try budget.ensureTime()
      let fileTotals = try autoreleasepool { () throws -> UsageTotals in
        let metadata = try self.metadata(file)
        let key = self.fileKey(provider: .anthropic, url: file)
        if retains { ledger.pendingRetained.insert(key) }
        guard box.index.records[key] != nil || box.index.records.count < Self.maximumScannedFiles
        else { return UsageTotals() }
        var record = box.index.records[key]
        if record?.provider != .anthropic || !metadata.sameFile(as: record)
          || metadata.size < (record?.offset ?? 0)
          || (metadata.size == (record?.offset ?? 0) && !metadata.matches(record))
        {
          record = CachedFile(
            provider: .anthropic, size: 0, modifiedAt: 0, offset: 0,
            days: [:], recentRows: [:], recentOrder: [])
        }
        let needsUpdate = !metadata.matches(record) || (record?.offset ?? 0) < metadata.size
        if needsUpdate, remainingBytes <= 0 {
          budget.markStarved()
          try budget.ensureTime()
        }
        if needsUpdate, remainingBytes > 0,
          // Skipped, like a vanished file, if the path is no longer a regular
          // file this user owns; the reads and the new stamp below all come from
          // this one descriptor.
          let opened = DescriptorBoundFile.open(file),
          let metadata = Self.metadata(opened)
        {
          defer { opened.close() }
          if !metadata.sameFile(as: record) || metadata.size < (record?.offset ?? 0)
            || (metadata.size == (record?.offset ?? 0) && !metadata.matches(record))
          {
            record = CachedFile(
              provider: .anthropic, size: 0, modifiedAt: 0, offset: 0,
              days: [:], recentRows: [:], recentOrder: [])
          }
          var updated = record!
          let scanResult = try self.scanLines(
            opened, from: updated.offset,
            discardingOversizedLine: updated.discardingOversizedLine ?? false,
            deadline: .distantFuture, budget: budget, remainingBytes: &remainingBytes
          ) { data in
            guard let row = Self.parseClaudeLine(data), row.dayKey >= cutoffKey else { return }
            if let rowKey = row.key, let previous = updated.recentRows[rowKey] {
              updated.days[previous.dayKey, default: UsageTotals()].subtract(previous.totals)
            }
            updated.days[row.dayKey, default: UsageTotals()].add(row.totals)
            if let rowKey = row.key {
              updated.recentRows[rowKey] = row
              updated.recentOrder.removeAll { $0 == rowKey }
              updated.recentOrder.append(rowKey)
              while updated.recentOrder.count > 128 {
                let evicted = updated.recentOrder.removeFirst()
                updated.recentRows.removeValue(forKey: evicted)
              }
            }
          }
          updated.size = metadata.size
          updated.offset = scanResult.offset
          updated.discardingOversizedLine = scanResult.discardingOversizedLine
          updated.modifiedAt = metadata.modifiedAt
          updated.device = metadata.device
          updated.inode = metadata.inode
          updated.changedAt = metadata.changedAt
          updated.days = updated.days.filter { $0.key >= cutoffKey }
          record = updated
          let incomplete = remainingBytes <= 0 && updated.offset < metadata.size
          try self.storeParsed(updated, key: key, box: box, ledger: ledger, budget: budget)
          if incomplete {
            budget.markStarved()
            try budget.ensureTime()
          }
        }
        return record?.totals(since: cutoffKey) ?? UsageTotals()
      }
      total.add(fileTotals)
      try budget.ensureTime()
    }
    return total
  }

  private func scanGrok(
    cutoff: Date,
    cutoffKey: String,
    box: IndexBox,
    ledger: ScanLedger,
    budget: ScanBudget,
    retains: Bool,
    explicitFiles: [URL]?
  ) throws -> UsageTotals {
    var total = UsageTotals()
    var remainingBytes = budget.providerBytes(defaultCap: self.maximumBytesPerScan)
    let files = try self.sessionFiles(
      explicitFiles: explicitFiles, root: self.roots.grok, named: "signals.json", extension: nil,
      cutoff: cutoff, budget: budget)
    for file in files {
      try budget.ensureTime()
      let metadata = try self.metadata(file)
      let key = self.fileKey(provider: .grok, url: file)
      if retains { ledger.pendingRetained.insert(key) }
      guard box.index.records[key] != nil || box.index.records.count < Self.maximumScannedFiles
      else { continue }
      var record = box.index.records[key]
      if !metadata.matches(record) {
        let readableBytes = max(0, Int(clamping: metadata.size))
        if readableBytes > 256 * 1_024 {
          record = CachedFile(
            provider: .grok, size: metadata.size, modifiedAt: metadata.modifiedAt,
            offset: metadata.size, days: [:], recentRows: [:], recentOrder: [],
            device: metadata.device, inode: metadata.inode, changedAt: metadata.changedAt)
          try self.storeParsed(record!, key: key, box: box, ledger: ledger, budget: budget)
        } else if readableBytes > remainingBytes {
          budget.markStarved()
          try budget.ensureTime()
        } else if let opened = DescriptorBoundFile.open(file, maximumBytes: 256 * 1_024),
          let metadata = Self.metadata(opened)
        {
          // Opened and validated once: the bytes and the stamp describe the same
          // file, and one that grew past the limit mid-read yields no data.
          defer { opened.close() }
          let data = opened.readToEnd(maximumBytes: 256 * 1_024)
          budget.consume(data?.count ?? 0, remaining: &remainingBytes)
          let parsed = data.flatMap(Self.parseGrokSignal)
          record = CachedFile(
            provider: .grok,
            size: metadata.size,
            modifiedAt: metadata.modifiedAt,
            offset: metadata.size,
            days: parsed.map { [Self.dayKey(metadata.date): $0] } ?? [:],
            recentRows: [:],
            recentOrder: [],
            device: metadata.device,
            inode: metadata.inode,
            changedAt: metadata.changedAt)
          try self.storeParsed(record!, key: key, box: box, ledger: ledger, budget: budget)
        }
      }
      total.add(record?.totals(since: cutoffKey) ?? UsageTotals())
      try budget.ensureTime()
    }
    return total
  }

  func recentFiles(
    root: URL,
    named: String?,
    extension fileExtension: String?,
    cutoff: Date,
    deadline: Date
  ) throws -> [URL] {
    try self.recentFiles(
      root: root, named: named, extension: fileExtension, cutoff: cutoff,
      deadline: deadline, budget: nil)
  }

  private func recentFiles(
    root: URL,
    named: String?,
    extension fileExtension: String?,
    cutoff: Date,
    deadline: Date,
    budget: ScanBudget?
  ) throws -> [URL] {
    self.scanMetrics.treeWalks += 1
    // These trees hold conversation transcripts. A symlink inside one would
    // otherwise point the scanner at any readable file on the machine — or at a
    // FIFO, which blocks the reader indefinitely — so links are refused outright
    // and every resolved path has to stay under the root it came from.
    let jail = root.resolvingSymlinksInPath().standardizedFileURL.path
    guard
      let enumerator = self.fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var files: [(url: URL, modified: Date)] = []
    var resolvedDirectories: [String: Bool] = [:]
    var visitedEntries = 0
    for case let file as URL in enumerator {
      try Self.checkDeadline(deadline, budget: budget)
      visitedEntries += 1
      guard visitedEntries <= Self.maximumEnumeratedEntries,
        files.count < Self.maximumScannedFiles
      else { break }
      if let named, file.lastPathComponent != named { continue }
      if let fileExtension, file.pathExtension != fileExtension { continue }
      guard
        let values = try? file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
        ]),
        values.isSymbolicLink != true,
        values.isRegularFile == true,
        let modified = values.contentModificationDate,
        let fileSize = values.fileSize, fileSize >= 0,
        modified >= cutoff
      else { continue }
      // The file itself is already known not to be a link. What still has to be
      // checked is its ancestry, and that is per *directory*, not per file —
      // resolving every one of several thousand files was pure syscall cost for
      // an answer shared by all the files in a folder.
      let parent = file.deletingLastPathComponent().path
      let inside: Bool
      if let known = resolvedDirectories[parent] {
        inside = known
      } else {
        let resolved = URL(fileURLWithPath: parent).resolvingSymlinksInPath()
          .standardizedFileURL.path
        inside = resolved == jail || resolved.hasPrefix(jail + "/")
        resolvedDirectories[parent] = inside
      }
      guard inside else { continue }
      files.append((file, modified))
    }
    try Self.checkDeadline(deadline, budget: budget)
    files.sort { $0.modified > $1.modified }
    try Self.checkDeadline(deadline, budget: budget)
    return files.map(\.url)
  }

  /// A ceiling on how much of a tree one scan will walk.
  private static let maximumScannedFiles = 5_000
  private static let maximumEnumeratedEntries = 20_000

  /// Path-level (`lstat`) size and modification time, used only to decide
  /// whether a file needs reading at all. It is converted exactly as the
  /// descriptor's `fstat` is when a file is read, so the stamp stored then
  /// compares equal here while the file is untouched.
  private func metadata(_ file: URL) throws -> LocalHistoryFileStamp {
    var info = stat()
    let result = file.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        errno = EINVAL
        return -1
      }
      return lstat(path, &info)
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return LocalHistoryFileStamp(info)
  }

  private static func metadata(_ file: DescriptorBoundFile) -> LocalHistoryFileStamp? {
    var info = stat()
    guard fstat(file.handle.fileDescriptor, &info) == 0 else { return nil }
    return LocalHistoryFileStamp(info)
  }

  private func parseCodexTail(
    _ file: DescriptorBoundFile,
    deadline: Date,
    budget: ScanBudget?,
    remainingBytes: inout Int
  ) throws -> (timestamp: Date, totals: UsageTotals)? {
    let handle = file.handle
    // The tail ends where the validated `fstat` said the file ended, the same
    // size the record is stamped with; anything appended since is picked up by
    // the next scan because the stamp will no longer match.
    var start = UInt64(max(0, file.metadata.size))
    var data = Data()
    while start > 0, data.count < self.codexTailBytes, remainingBytes > 0 {
      try Self.checkDeadline(deadline, budget: budget)
      let step = min(UInt64(self.codexTailStepBytes), start, UInt64(remainingBytes))
      start -= step
      try handle.seek(toOffset: start)
      var expanded = try handle.read(upToCount: Int(step)) ?? Data()
      if let budget {
        budget.consume(expanded.count, remaining: &remainingBytes)
      } else {
        remainingBytes -= expanded.count
      }
      expanded.append(data)
      data = expanded

      let hasUsage = data.range(of: Data(#""token_count""#.utf8)) != nil
      let hasModel = data.range(of: Data(#""turn_context""#.utf8)) != nil
      if hasUsage, hasModel { break }
    }
    if start > 0, let newline = data.firstIndex(of: 0x0A) {
      data.removeSubrange(data.startIndex...newline)
    }
    return try Self.parseCodexTailData(data, deadline: deadline, budget: budget)
  }

  static func parseCodexTailData(_ data: Data) -> (timestamp: Date, totals: UsageTotals)? {
    try? Self.parseCodexTailData(data, deadline: nil, budget: nil)
  }

  private static func parseCodexTailData(
    _ data: Data,
    deadline: Date?,
    budget: ScanBudget?
  ) throws -> (timestamp: Date, totals: UsageTotals)? {
    var currentModel: String?
    var latest: (Date, UsageTotals)?
    for (lineIndex, line) in data.split(separator: 0x0A).prefix(100_000).enumerated()
    where line.count <= 1024 * 1024
    {
      if lineIndex.isMultiple(of: 256), budget != nil || deadline != nil {
        try Self.checkDeadline(deadline ?? .distantFuture, budget: budget)
      }
      let lineData = Data(line)
      let mightBeModel = lineData.range(of: Data(#""turn_context""#.utf8)) != nil
      let mightBeUsage = lineData.range(of: Data(#""token_count""#.utf8)) != nil
      guard mightBeModel || mightBeUsage else { continue }
      autoreleasepool {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
          let type = object["type"] as? String,
          let payload = object["payload"] as? [String: Any]
        else { return }
        if type == "turn_context", let model = payload["model"] as? String {
          currentModel = model
          return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
          let info = payload["info"] as? [String: Any],
          let usage = info["total_token_usage"] as? [String: Any]
        else { return }
        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseDate) ?? Date()
        let input = Self.int64(usage["input_tokens"])
        let cached = Self.int64(usage["cached_input_tokens"])
        let cacheWrite = Self.int64(usage["cache_write_input_tokens"])
        let output = Self.int64(usage["output_tokens"])
        let model = currentModel ?? "gpt-5.6-sol"
        let cost = Pricing.apiCost(
          provider: .openAI, model: model, input: input, cached: cached,
          cacheWrite: cacheWrite, cacheWriteOneHour: 0, output: output)
        latest = (
          timestamp,
          UsageTotals(
            input: input, cached: cached, cacheWrite: cacheWrite, output: output,
            costUSD: cost ?? 0, estimated: cost == nil || currentModel == nil)
        )
      }
    }
    return latest
  }

  private func scanLines(
    _ file: DescriptorBoundFile,
    from offset: Int64,
    discardingOversizedLine: Bool,
    deadline: Date,
    budget: ScanBudget?,
    remainingBytes: inout Int,
    visit: (Data) -> Void
  ) throws -> (offset: Int64, discardingOversizedLine: Bool) {
    let handle = file.handle
    try handle.seek(toOffset: UInt64(max(0, offset)))
    let buffer = BoundedLineBuffer(
      maximumBytes: self.maximumLineBytes,
      discardingOversizedLine: discardingOversizedLine)
    var fileBytesRemaining = min(self.maximumBytesPerFileScan, remainingBytes)
    var consumedBytes = 0
    var lineCount = 0
    while fileBytesRemaining > 0, remainingBytes > 0,
      lineCount < self.maximumLinesPerFile
    {
      try Self.checkDeadline(deadline, budget: budget)
      let allowance = min(64 * 1_024, remainingBytes, fileBytesRemaining)
      guard let chunk = try handle.read(upToCount: allowance), !chunk.isEmpty else { break }
      if let budget {
        budget.consume(chunk.count, remaining: &remainingBytes)
      } else {
        remainingBytes -= chunk.count
      }
      fileBytesRemaining -= chunk.count
      let result = buffer.append(
        chunk, maximumLines: self.maximumLinesPerFile - lineCount)
      consumedBytes += result.consumedBytes
      for data in result.lines {
        lineCount += 1
        autoreleasepool { visit(data) }
      }
    }
    try Self.checkDeadline(deadline, budget: budget)
    let nextOffset = max(0, offset) + Int64(consumedBytes)
    let bufferState = buffer.append(Data(), maximumLines: 0)
    return (nextOffset, bufferState.discardingOversizedLine)
  }

  static func parseClaudeLine(_ data: Data) -> CachedRow? {
    guard data.range(of: Data(#""type":"assistant""#.utf8)) != nil,
      let usageData = Self.jsonObject(after: #""usage":"#, in: data),
      let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any],
      let timestampText = Self.jsonString(named: "timestamp", in: data),
      timestampText.count >= 10
    else { return nil }
    let model = Self.jsonString(named: "model", in: data) ?? "claude-opus-5"
    let input = Self.int64(usage["input_tokens"])
    let cached = Self.int64(usage["cache_read_input_tokens"])
    let cacheWrite = Self.int64(usage["cache_creation_input_tokens"])
    let output = Self.int64(usage["output_tokens"])
    let creation = usage["cache_creation"] as? [String: Any]
    let oneHour = min(cacheWrite, Self.int64(creation?["ephemeral_1h_input_tokens"]))
    guard saturatingNonnegativeSum(input, cached, cacheWrite, output) > 0 else { return nil }
    let cost = Pricing.apiCost(
      provider: .anthropic, model: model, input: input, cached: cached,
      cacheWrite: cacheWrite, cacheWriteOneHour: oneHour, output: output)
    let messageID = Self.jsonString(named: "id", in: data)
    let requestID = Self.jsonString(named: "requestId", in: data)
    let key = messageID.flatMap { message in requestID.map { "\(message):\($0)" } }
    return CachedRow(
      key: key,
      dayKey: String(timestampText.prefix(10)),
      totals: UsageTotals(
        input: input, cached: cached, cacheWrite: cacheWrite, output: output,
        costUSD: cost ?? 0, estimated: cost == nil))
  }

  private static func jsonObject(after marker: String, in data: Data) -> Data? {
    guard let markerRange = data.range(of: Data(marker.utf8)) else { return nil }
    var index = markerRange.upperBound
    while index < data.endIndex, data[index] != 0x7B { index += 1 }
    guard index < data.endIndex else { return nil }
    let start = index
    var depth = 0
    var insideString = false
    var escaped = false
    while index < data.endIndex {
      let byte = data[index]
      if insideString {
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          insideString = false
        }
      } else if byte == 0x22 {
        insideString = true
      } else if byte == 0x7B {
        depth += 1
      } else if byte == 0x7D {
        depth -= 1
        if depth == 0 { return Data(data[start...index]) }
      }
      index += 1
    }
    return nil
  }

  private static func jsonString(named name: String, in data: Data) -> String? {
    let marker = Data(#""\#(name)":""#.utf8)
    guard let markerRange = data.range(of: marker) else { return nil }
    var index = markerRange.upperBound
    let start = index
    var escaped = false
    while index < data.endIndex {
      let byte = data[index]
      if escaped {
        escaped = false
      } else if byte == 0x5C {
        escaped = true
      } else if byte == 0x22 {
        let quoted = Data([0x22]) + Data(data[start..<index]) + Data([0x22])
        return try? JSONDecoder().decode(String.self, from: quoted)
      }
      index += 1
    }
    return nil
  }

  static func parseGrokSignal(_ data: Data) -> UsageTotals? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let total = saturatingNonnegativeSum(
      Self.int64(object["totalTokensBeforeCompaction"]),
      Self.int64(object["contextTokensUsed"]))
    guard total > 0 else { return nil }
    let model =
      object["primaryModelId"] as? String
      ?? (object["modelsUsed"] as? [String])?.last
      ?? "grok-4.6"
    let cost = Pricing.apiCost(
      provider: .grok, model: model, input: total, cached: 0,
      cacheWrite: 0, cacheWriteOneHour: 0, output: 0)
    return UsageTotals(
      input: total, output: 0, costUSD: cost ?? 0, estimated: true)
  }

  private func loadIndex() -> UsageIndex {
    self.loadPublishedIndex().index
  }

  private func loadPublishedIndex() -> (index: UsageIndex, anchor: LocalHistoryFileAnchor?) {
    let anchor = LocalHistoryIndexFile.anchor(
      url: self.cacheURL, maximumBytes: self.maximumCacheBytes)
    if let residentIndex = self.residentIndex, self.residentAnchor == anchor {
      self.scanMetrics.indexReuses += 1
      return (residentIndex, anchor)
    }
    let externallyInvalidated = self.residentIndex != nil && self.residentAnchor != anchor
    if externallyInvalidated, self.watchChanges {
      // The cache may have been deleted, corrupted, or atomically replaced by
      // another process. A clean watcher only describes session-tree changes;
      // it cannot make an empty/replaced cache authoritative.
      self.changeTracker.invalidateAll(.ambiguous)
    }
    if self.memoryCheckpoint != nil, self.memoryCheckpoint?.anchor != anchor {
      self.memoryCheckpoint = nil
      self.scanIncomplete = false
      LocalHistoryCheckpointStore.discard(cacheURL: self.cacheURL)
    }
    guard let read = LocalHistoryIndexFile.contents(
      url: self.cacheURL, maximumBytes: self.maximumCacheBytes)
    else {
      let empty = UsageIndex()
      self.residentAnchor = nil
      self.residentIndex = empty
      return (empty, nil)
    }
    self.scanMetrics.indexDecodes += 1
    guard let index = try? JSONDecoder().decode(UsageIndex.self, from: read.data),
      self.indexIsValid(index)
    else {
      if self.watchChanges { self.changeTracker.invalidateAll(.ambiguous) }
      let empty = UsageIndex()
      self.residentAnchor = read.anchor
      self.residentIndex = empty
      return (empty, read.anchor)
    }
    self.residentAnchor = read.anchor
    self.residentIndex = index
    return (index, read.anchor)
  }

  private func indexIsValid(_ index: UsageIndex) -> Bool {
    index.version == 1 && index.records.count <= Self.maximumScannedFiles
      && index.records.values.allSatisfy(self.recordIsValid)
  }

  private func recordIsValid(_ record: CachedFile) -> Bool {
    record.days.count <= 100 && record.recentRows.count <= 128
      && record.recentOrder.count <= 128
  }

  private func saveIndex(
    _ index: UsageIndex,
    replacing expectedAnchor: LocalHistoryFileAnchor?,
    budget: ScanBudget
  ) throws {
    try budget.ensureTime()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(index)
    try budget.ensureTime()
    guard data.count <= self.maximumCacheBytes else {
      throw UsageProviderError.invalidResponse("local usage index exceeded 12 MB")
    }
    let hook = self.beforePublishHook
    self.beforePublishHook = nil
    hook?()
    try budget.ensureTime()
    let currentAnchor = LocalHistoryIndexFile.anchor(
      url: self.cacheURL, maximumBytes: self.maximumCacheBytes)
    guard currentAnchor == expectedAnchor else {
      // Another process or scanner replaced the shared index while this pass
      // was working. Keep that newer file, reload it, and force every active
      // root through discovery before a later publication can merge it.
      self.residentIndex = nil
      self.residentAnchor = nil
      self.memoryCheckpoint = nil
      self.scanIncomplete = false
      LocalHistoryCheckpointStore.discard(cacheURL: self.cacheURL)
      _ = self.loadPublishedIndex()
      if self.watchChanges { self.changeTracker.invalidateAll(.ambiguous) }
      throw LocalHistoryScannerInternalError.cacheChangedDuringScan
    }
    try BoundedFileReader.writeRestricted(data, to: self.cacheURL, fileManager: self.fileManager)
    if let anchor = LocalHistoryIndexFile.anchor(
      url: self.cacheURL, maximumBytes: self.maximumCacheBytes)
    {
      self.residentAnchor = anchor
      self.residentIndex = index
    } else {
      self.residentAnchor = nil
      self.residentIndex = index
    }
  }

  private func fileKey(provider: ProviderID, url: URL) -> String {
    // FSEvents reports canonical paths even when a configured root was a
    // symlink. Hash the same canonical spelling during discovery and sparse
    // updates so one file cannot acquire two records.
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    if let cached = self.fileKeys[provider]?[path] { return cached }
    let digest = SHA256.hash(data: Data(path.utf8))
    let key = provider.rawValue + ":" + digest.map { String(format: "%02x", $0) }.joined()
    if self.fileKeys.values.reduce(0, { $0 + $1.count }) >= Self.maximumScannedFiles {
      self.fileKeys.removeAll(keepingCapacity: true)
    }
    self.fileKeys[provider, default: [:]][path] = key
    return key
  }

  private static let dateParsers = ScannerDateParsers()

  private static func dayKey(_ date: Date) -> String {
    Self.dateParsers.dayKey(date)
  }

  private static func parseDate(_ text: String) -> Date? {
    Self.dateParsers.parse(text)
  }

  private static func int64(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) ?? 0 }
    return 0
  }

  static func isArchiveDayKey(_ key: String) -> Bool {
    CachedUsageHistory.isValidDayKey(key)
  }

  /// Sum of observed day keys across still-loaded records. Zero totals are kept
  /// only when the key was recorded. Days with no key stay absent.
  private static func observedDays(
    index: UsageIndex, providers: Set<ProviderID>, now: Date
  ) -> [ProviderID: [String: ArchivedUsageDay]] {
    // A parsed unknown price is stored as cost 0 with estimated true. Decide
    // that before summing, or a priced sibling file hides the missing price.
    var unpriced: [ProviderID: Set<String>] = [:]
    for record in index.records.values where providers.contains(record.provider) {
      for (key, value) in record.days where isArchiveDayKey(key) {
        guard value.estimated, value.totalTokens(provider: record.provider) > 0 else { continue }
        if value.costUSD == 0 || record.provider == .anthropic {
          unpriced[record.provider, default: []].insert(key)
        }
      }
    }
    var totals: [ProviderID: [String: UsageTotals]] = [:]
    for record in index.records.values where providers.contains(record.provider) {
      for (key, value) in record.days where isArchiveDayKey(key) {
        totals[record.provider, default: [:]][key, default: UsageTotals()].add(value)
      }
    }
    var archived: [ProviderID: [String: ArchivedUsageDay]] = [:]
    for (provider, days) in totals {
      let missingPrice = unpriced[provider] ?? []
      var rows: [String: ArchivedUsageDay] = [:]
      rows.reserveCapacity(days.count)
      for (key, value) in days {
        rows[key] = ArchivedUsageDay(
          tokens: value.totalTokens(provider: provider),
          costUSD: missingPrice.contains(key) ? nil : recordedCost(value.costUSD),
          fetchedAt: now)
      }
      archived[provider] = rows
    }
    return archived
  }

  private static func recordedCost(_ cost: Double) -> Double? {
    guard cost.isFinite, cost > 0 else { return cost == 0 ? 0 : nil }
    return cost
  }

  /// Replaces overlapping archive keys with this scan's observed totals.
  /// Older archive days outside the new observation stay, then retention drops
  /// anything older than 90 civil days or dated after `now`.
  @discardableResult
  private static func mergeDailyHistory(
    _ index: inout UsageIndex,
    observed: [ProviderID: [String: ArchivedUsageDay]],
    now: Date
  ) -> Bool {
    guard !observed.isEmpty else { return false }
    let calendar = CachedUsageHistory.civilCalendar(.current)
    let today = CachedUsageHistory.dayKey(for: now, calendar: calendar)
    let oldest = CachedUsageHistory.dayKey(
      daysBefore: CachedUsageHistory.retentionDays - 1, from: now, calendar: calendar)
    var changed = false
    for (provider, days) in observed {
      var stored = index.dailyHistory[provider] ?? [:]
      let before = stored
      for (key, day) in days where isArchiveDayKey(key) {
        stored[key] = day
      }
      if let oldest {
        stored = stored.filter { $0.key >= oldest && $0.key <= today && isArchiveDayKey($0.key) }
      }
      if stored.count > CachedUsageHistory.retentionDays {
        let keep = Set(stored.keys.sorted().suffix(CachedUsageHistory.retentionDays))
        stored = stored.filter { keep.contains($0.key) }
      }
      if stored != before {
        changed = true
        if stored.isEmpty {
          index.dailyHistory.removeValue(forKey: provider)
        } else {
          index.dailyHistory[provider] = stored
        }
      }
    }
    return changed
  }

  private func performScan(
    box: IndexBox,
    ledger: ScanLedger,
    anchor: LocalHistoryFileAnchor?,
    budget: ScanBudget,
    selected: Set<ProviderID>,
    dirtyProviders: Set<ProviderID>?,
    periodDays: Int,
    cycleStarts: [ProviderID: Date],
    now: Date
  ) throws -> [ProviderID: LocalUsageSummary] {
    let days = min(90, max(1, periodDays))
    let cutoff = Calendar.current.date(byAdding: .day, value: -days + 1, to: now) ?? now
    let plans = self.visitPlans(selected: selected, dirtyProviders: dirtyProviders)
    ledger.tokens = Dictionary(uniqueKeysWithValues: plans.map { ($0.provider.rawValue, $0.token) })
    for plan in plans {
      if case .skip = plan.visit {
        self.scanMetrics.warmSkips += 1
      } else {
        ledger.dirtyProviders.insert(plan.provider)
      }
    }
    // Claude drops day keys older than its file cutoff while updating a record.
    // Capture those aggregates before any overlay or rescan replaces them.
    let legacy = Self.observedDays(
      index: box.index, providers: ledger.dirtyProviders, now: box.index.updatedAt)
    if var checkpoint = self.checkpoint(matching: anchor) {
      if checkpoint.needsFinalize {
        checkpoint.needsFinalize = false
        checkpoint.retainedKeys = []
        checkpoint.pruneProviders = []
      }
      self.apply(checkpoint, to: box, ledger: ledger)
      self.scanMetrics.resumes += 1
    }
    try budget.ensureTime()
    let cutoffKey = Self.dayKey(cutoff)
    for plan in plans {
      try self.visit(
        plan, cutoff: cutoff, cutoffKey: cutoffKey, box: box, ledger: ledger, budget: budget)
    }
    return try self.finalize(
      box: box, ledger: ledger, expectedAnchor: anchor, legacy: legacy,
      selected: selected, days: days,
      cutoff: cutoff, cycleStarts: cycleStarts, now: now, budget: budget)
  }

  private func finalize(
    box: IndexBox,
    ledger: ScanLedger,
    expectedAnchor: LocalHistoryFileAnchor?,
    legacy: [ProviderID: [String: ArchivedUsageDay]],
    selected: Set<ProviderID>,
    days: Int,
    cutoff: Date,
    cycleStarts: [ProviderID: Date],
    now: Date,
    budget: ScanBudget
  ) throws -> [ProviderID: LocalUsageSummary] {
    if !ledger.retainedReady {
      ledger.retainedKeys = ledger.pendingRetained
      ledger.retainedReady = true
    }
    ledger.needsFinalize = true
    if budget.stopBeforePublish {
      budget.stopBeforePublish = false
      budget.markStarved()
    }
    try budget.ensureTime()
    var observed = legacy
    let fresh = Self.observedDays(index: box.index, providers: ledger.dirtyProviders, now: now)
    for (provider, days) in fresh {
      var stored = observed[provider] ?? [:]
      for (key, day) in days { stored[key] = day }
      observed[provider] = stored
    }
    try budget.ensureTime()
    let previousRecordCount = box.index.records.count
    let dirty = ledger.dirtyProviders
    let prune = ledger.pruneProviders
    let retained = ledger.retainedKeys
    box.index.records = box.index.records.filter { key, record in
      if !dirty.contains(record.provider) { return true }
      if !prune.contains(record.provider) { return true }
      return retained.contains(key)
    }
    if box.index.records.count != previousRecordCount { ledger.indexChanged = true }
    if Self.mergeDailyHistory(&box.index, observed: observed, now: now) {
      ledger.indexChanged = true
    }
    let cutoffKey = Self.dayKey(cutoff)
    let todayKey = Self.dayKey(now)
    var selectedIndex = box.index
    selectedIndex.records = box.index.records.filter { selected.contains($0.value.provider) }
    let series = try Self.dailySeries(
      index: selectedIndex, days: days, now: now, deadline: .distantFuture, budget: budget)
    var summaries: [ProviderID: LocalUsageSummary] = [:]
    for provider in selected {
      try budget.ensureTime()
      let totals = try Self.aggregate(
        provider: provider, since: cutoffKey, index: selectedIndex,
        deadline: .distantFuture, budget: budget)
      let cycleStart = cycleStarts[provider] ?? cutoff
      let today = try Self.aggregate(
        provider: provider, since: todayKey, index: box.index,
        deadline: .distantFuture, budget: budget)
      let cycle = try Self.aggregate(
        provider: provider, since: Self.dayKey(cycleStart), index: box.index,
        deadline: .distantFuture, budget: budget)
      // A provider is current only after its planned files were fully
      // revalidated. Missing roots are removed from dirtyProviders in visit(),
      // while a warm skip intentionally retains the last verified timestamp.
      let fetchedAt = ledger.dirtyProviders.contains(provider)
        ? now : (self.lastScanDates[provider] ?? box.index.updatedAt)
      summaries[provider] = totals.summary(
        provider: provider, periodDays: days, today: today, cycle: cycle,
        cycleStartedAt: cycleStart, now: fetchedAt, dailyTokens: series[provider] ?? [])
    }
    // Cancellation still happens before the publish. A timeout here keeps the
    // checkpoint (needsFinalize is already set) and leaves the previous file.
    try Task.checkCancellation()
    try budget.ensureTime()
    if ledger.indexChanged {
      box.index.updatedAt = now
      try self.saveIndex(box.index, replacing: expectedAnchor, budget: budget)
    }
    for provider in dirty { self.lastScanDates[provider] = now }
    self.acknowledge(selected: selected, ledger: ledger)
    let pending = Set((self.memoryCheckpoint?.dirtyProviders ?? []).compactMap(ProviderID.init(rawValue:)))
    if pending.isSubset(of: dirty) {
      self.memoryCheckpoint = nil
      LocalHistoryCheckpointStore.discard(cacheURL: self.cacheURL)
      self.scanIncomplete = false
    }
    return summaries
  }

  private func visit(
    _ plan: LocalHistoryVisitPlan,
    cutoff: Date,
    cutoffKey: String,
    box: IndexBox,
    ledger: ScanLedger,
    budget: ScanBudget
  ) throws {
    switch plan.visit {
    case .skip:
      return
    case .full(let reason):
      if reason == .overflow { self.scanMetrics.overflowFallbacks += 1 }
      let root = self.root(for: plan.provider)
      if self.watchChanges, !self.directoryExists(root) {
        self.changeTracker.noteUnavailable(plan.provider)
        ledger.dirtyProviders.remove(plan.provider)
        return
      }
      self.scanMetrics.fullDiscoveries += 1
      try self.scanProvider(
        plan.provider, explicitFiles: nil, retains: true, cutoff: cutoff,
        cutoffKey: cutoffKey, box: box, ledger: ledger, budget: budget)
    case .sparse(let changed, let removed):
      self.scanMetrics.sparseVisits += changed.count + removed.count
      for url in removed + changed where !self.fileManager.fileExists(atPath: url.path) {
        self.removeRecord(url, provider: plan.provider, box: box, ledger: ledger)
      }
      let existing = changed.filter { self.fileManager.fileExists(atPath: $0.path) }
      try self.scanProvider(
        plan.provider, explicitFiles: existing, retains: false, cutoff: cutoff,
        cutoffKey: cutoffKey, box: box, ledger: ledger, budget: budget)
    }
  }

  private func scanProvider(
    _ provider: ProviderID,
    explicitFiles: [URL]?,
    retains: Bool,
    cutoff: Date,
    cutoffKey: String,
    box: IndexBox,
    ledger: ScanLedger,
    budget: ScanBudget
  ) throws {
    switch provider {
    case .openAI:
      _ = try self.scanCodex(
        cutoff: cutoff, cutoffKey: cutoffKey, box: box, ledger: ledger, budget: budget,
        retains: retains, explicitFiles: explicitFiles)
    case .anthropic:
      _ = try self.scanClaude(
        cutoff: cutoff, cutoffKey: cutoffKey, box: box, ledger: ledger, budget: budget,
        retains: retains, explicitFiles: explicitFiles)
    case .grok:
      _ = try self.scanGrok(
        cutoff: cutoff, cutoffKey: cutoffKey, box: box, ledger: ledger, budget: budget,
        retains: retains, explicitFiles: explicitFiles)
    default:
      return
    }
    if retains { ledger.pruneProviders.insert(provider) }
  }

  private func sessionFiles(
    explicitFiles: [URL]?,
    root: URL,
    named: String?,
    extension fileExtension: String?,
    cutoff: Date,
    budget: ScanBudget
  ) throws -> [URL] {
    if let explicitFiles {
      return explicitFiles.filter {
        self.sessionFileAllowed(
          $0, root: root, named: named, extension: fileExtension, cutoff: cutoff)
      }
    }
    return try self.recentFiles(
      root: root, named: named, extension: fileExtension, cutoff: cutoff,
      deadline: .distantFuture, budget: budget)
  }

  private func sessionFileAllowed(
    _ file: URL,
    root: URL,
    named: String?,
    extension fileExtension: String?,
    cutoff: Date
  ) -> Bool {
    if let named, file.lastPathComponent != named { return false }
    if let fileExtension, file.pathExtension != fileExtension { return false }
    let jail = root.resolvingSymlinksInPath().standardizedFileURL.path
    let parent = file.deletingLastPathComponent().path
    let resolved = URL(fileURLWithPath: parent).resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved == jail || resolved.hasPrefix(jail + "/") else { return false }
    guard
      let values = try? file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
      ]),
      values.isSymbolicLink != true,
      values.isRegularFile == true,
      let modified = values.contentModificationDate,
      let fileSize = values.fileSize, fileSize >= 0,
      modified >= cutoff
    else { return false }
    return true
  }

  private func storeParsed(
    _ record: CachedFile,
    key: String,
    box: IndexBox,
    ledger: ScanLedger,
    budget: ScanBudget
  ) throws {
    box.index.records[key] = record
    ledger.parsedRecords[key] = record
    ledger.removedKeys.remove(key)
    ledger.indexChanged = true
    self.scanMetrics.filesParsed += 1
    try budget.noteFileCommitted()
  }

  private func removeRecord(
    _ url: URL, provider: ProviderID, box: IndexBox, ledger: ScanLedger
  ) {
    let key = self.fileKey(provider: provider, url: url)
    if box.index.records.removeValue(forKey: key) != nil { ledger.indexChanged = true }
    ledger.parsedRecords.removeValue(forKey: key)
    ledger.removedKeys.insert(key)
    ledger.pendingRetained.remove(key)
  }

  private func acknowledge(selected: Set<ProviderID>, ledger: ScanLedger) {
    guard self.watchChanges else { return }
    let ordered = Self.historyProviders.filter { selected.contains($0) }
    let current = self.changeTracker.plan(
      providers: ordered, now: .now, fullDiscoveryInterval: self.fullDiscoveryInterval)
    for plan in current where ledger.dirtyProviders.contains(plan.provider) {
      let expected = ledger.tokens[plan.provider.rawValue]
      guard expected == nil || expected == plan.token else { continue }
      self.changeTracker.acknowledge(
        provider: plan.provider, token: plan.token,
        full: ledger.pruneProviders.contains(plan.provider), now: .now)
    }
  }

  private func checkpoint(matching anchor: LocalHistoryFileAnchor?) -> LocalHistoryCheckpoint? {
    if let memory = self.memoryCheckpoint {
      guard memory.anchor == anchor else {
        self.memoryCheckpoint = nil
        self.scanIncomplete = false
        LocalHistoryCheckpointStore.discard(cacheURL: self.cacheURL)
        return nil
      }
      return memory
    }
    guard let loaded = LocalHistoryCheckpointStore.load(
      cacheURL: self.cacheURL, maximumBytes: self.maximumCacheBytes)
    else { return nil }
    guard loaded.anchor == anchor else {
      LocalHistoryCheckpointStore.discard(cacheURL: self.cacheURL)
      return nil
    }
    self.memoryCheckpoint = loaded
    return loaded
  }

  private func preserveCheckpoint(_ ledger: ScanLedger, anchor: LocalHistoryFileAnchor?) {
    self.scanIncomplete = true
    let hasProgress = !ledger.parsedRecords.isEmpty || !ledger.removedKeys.isEmpty
      || ledger.needsFinalize
    guard hasProgress else { return }
    guard let recordsJSON = try? self.encodeRecords(ledger.parsedRecords),
      recordsJSON.count <= self.maximumCacheBytes
    else { return }
    let checkpoint = LocalHistoryCheckpoint(
      version: 1,
      anchor: anchor,
      removedKeys: ledger.removedKeys.sorted(),
      needsFinalize: ledger.needsFinalize,
      retainedKeys: ledger.needsFinalize ? ledger.retainedKeys.sorted() : [],
      dirtyProviders: ledger.dirtyProviders.map(\.rawValue).sorted(),
      pruneProviders: ledger.needsFinalize ? ledger.pruneProviders.map(\.rawValue).sorted() : [],
      tokens: ledger.tokens,
      recordsJSON: recordsJSON)
    if checkpoint == self.memoryCheckpoint { return }
    self.memoryCheckpoint = checkpoint
    self.scanMetrics.checkpoints += 1
    _ = try? LocalHistoryCheckpointStore.save(
      checkpoint, cacheURL: self.cacheURL, maximumBytes: self.maximumCacheBytes,
      fileManager: self.fileManager)
  }

  private func apply(
    _ checkpoint: LocalHistoryCheckpoint, to box: IndexBox, ledger: ScanLedger
  ) {
    let allowed = checkpoint.needsFinalize
      ? Self.providerSet(checkpoint.dirtyProviders) : ledger.dirtyProviders
    let decoded = (try? JSONDecoder().decode(
      [String: CachedFile].self, from: checkpoint.recordsJSON)) ?? [:]
    guard decoded.count <= Self.maximumScannedFiles else { return }
    for (key, record) in decoded where allowed.contains(record.provider) && self.recordIsValid(record) {
      box.index.records[key] = record
      ledger.parsedRecords[key] = record
    }
    for key in checkpoint.removedKeys {
      guard let provider = Self.provider(ofKey: key), allowed.contains(provider) else { continue }
      box.index.records.removeValue(forKey: key)
      ledger.parsedRecords.removeValue(forKey: key)
      ledger.removedKeys.insert(key)
    }
    if checkpoint.needsFinalize {
      ledger.tokens = checkpoint.tokens
    }
    if checkpoint.needsFinalize {
      ledger.needsFinalize = true
      ledger.retainedReady = true
      ledger.retainedKeys = Set(checkpoint.retainedKeys)
      ledger.pruneProviders = Self.providerSet(checkpoint.pruneProviders)
      ledger.dirtyProviders = Self.providerSet(checkpoint.dirtyProviders)
    }
    ledger.indexChanged = !ledger.parsedRecords.isEmpty || !ledger.removedKeys.isEmpty
  }

  private func encodeRecords(_ records: [String: CachedFile]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(records)
  }

  private func makeBudget() -> ScanBudget {
    let budget = ScanBudget(
      limit: self.durationOverride ?? .seconds(self.maximumScanDuration),
      bytes: self.byteOverride,
      commits: self.commitLimit,
      cancelAfter: self.cancelAfterParsedFiles,
      stopBeforePublish: self.stopBeforePublish)
    self.commitLimit = nil
    self.cancelAfterParsedFiles = nil
    self.stopBeforePublish = false
    return budget
  }

  private func visitPlans(
    selected: Set<ProviderID>, dirtyProviders: Set<ProviderID>?
  ) -> [LocalHistoryVisitPlan] {
    let ordered = Self.historyProviders.filter { selected.contains($0) }
    if let dirtyProviders {
      let dirty = selected.intersection(dirtyProviders)
      let watched = self.watchChanges
        ? self.changeTracker.plan(
          providers: ordered, now: .now, fullDiscoveryInterval: self.fullDiscoveryInterval)
        : []
      return ordered.map { provider in
        let token = watched.first { $0.provider == provider }?.token ?? 0
        let visit: LocalHistoryVisit = dirty.contains(provider) ? .full(.baseline) : .skip
        return LocalHistoryVisitPlan(provider: provider, visit: visit, token: token)
      }
    }
    if self.watchChanges {
      return self.changeTracker.plan(
        providers: ordered, now: .now, fullDiscoveryInterval: self.fullDiscoveryInterval)
    }
    return ordered.map {
      LocalHistoryVisitPlan(provider: $0, visit: .full(.baseline), token: 0)
    }
  }

  private func watchRoots(_ providers: Set<ProviderID>) -> [ProviderID: URL] {
    var roots: [ProviderID: URL] = [:]
    if providers.contains(.openAI) { roots[.openAI] = self.roots.codex }
    if providers.contains(.anthropic) { roots[.anthropic] = self.roots.claude }
    if providers.contains(.grok) { roots[.grok] = self.roots.grok }
    return roots
  }

  private func root(for provider: ProviderID) -> URL {
    switch provider {
    case .openAI: self.roots.codex
    case .anthropic: self.roots.claude
    case .grok: self.roots.grok
    default: self.roots.codex
    }
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return self.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static let historyProviders: [ProviderID] = [.openAI, .anthropic, .grok]

  private static func providerSet(_ raw: [String]) -> Set<ProviderID> {
    Set(raw.compactMap(ProviderID.init(rawValue:)))
  }

  private static func provider(ofKey key: String) -> ProviderID? {
    guard let raw = key.split(separator: ":", maxSplits: 1).first else { return nil }
    return ProviderID(rawValue: String(raw))
  }

  func testingSetBudget(
    maximumDuration: Duration? = nil,
    maximumBytes: Int? = nil,
    commitLimit: Int? = nil,
    cancelAfterParsedFiles: Int? = nil,
    stopBeforePublish: Bool = false
  ) {
    self.durationOverride = maximumDuration
    self.byteOverride = maximumBytes
    self.commitLimit = commitLimit
    self.cancelAfterParsedFiles = cancelAfterParsedFiles
    self.stopBeforePublish = stopBeforePublish
  }

  func testingSetFullDiscoveryInterval(_ interval: Duration) {
    self.fullDiscoveryInterval = interval
  }

  func testingSetBeforePublish(_ hook: (@Sendable () -> Void)?) {
    self.beforePublishHook = hook
  }

  func testingSimulateWatch() {
    self.changeTracker.simulate = true
  }

  func testingInject(
    provider: ProviderID,
    changed: [URL] = [],
    removed: [URL] = [],
    overflow: Bool = false,
    renamed: Bool = false,
    rootUnavailable: Bool = false
  ) {
    guard self.watchChanges else { return }
    self.changeTracker.inject(
      provider: provider, changed: changed, removed: removed, overflow: overflow,
      renamed: renamed, rootUnavailable: rootUnavailable)
  }

  func testingIsWatching(_ provider: ProviderID) -> Bool {
    self.changeTracker.isWatching(provider)
  }

  func testingCheckpointExists() -> Bool {
    if self.memoryCheckpoint != nil { return true }
    return FileManager.default.fileExists(
      atPath: LocalHistoryCheckpoint.url(for: self.cacheURL).path)
  }
}

/// Static parse helpers are also used by tests outside the scanner actor.
/// Keep formatter reuse synchronized and follow time-zone changes.
private final class ScannerDateParsers: @unchecked Sendable {
  private let lock = NSLock()
  private let day = DateFormatter()
  private let fractional = ISO8601DateFormatter()
  private let standard = ISO8601DateFormatter()

  init() {
    self.day.calendar = Calendar(identifier: .gregorian)
    self.day.locale = Locale(identifier: "en_US_POSIX")
    self.day.dateFormat = "yyyy-MM-dd"
    self.fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  }

  func dayKey(_ date: Date) -> String {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.day.timeZone = .current
    return self.day.string(from: date)
  }

  func parse(_ text: String) -> Date? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.fractional.date(from: text) ?? self.standard.date(from: text)
  }
}

private struct ArchivedUsageDay: Codable, Equatable {
  var tokens: Int64
  var costUSD: Double?
  var fetchedAt: Date

  init(tokens: Int64, costUSD: Double?, fetchedAt: Date) {
    self.tokens = tokens < 0 ? 0 : tokens
    self.costUSD = costUSD.flatMap { $0.isFinite ? max(0, $0) : nil }
    self.fetchedAt = fetchedAt
  }
}

private struct UsageIndex: Codable {
  var version = 1
  var updatedAt = Date.distantPast
  var records: [String: CachedFile] = [:]
  /// Provider raw value to civil day. Optional so indexes written before this
  /// field still decode. Holds only day totals, never paths or account ids.
  var dailyHistory: [ProviderID: [String: ArchivedUsageDay]] = [:]

  private enum CodingKeys: String, CodingKey {
    case version, updatedAt, records, dailyHistory
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    self.records = try container.decodeIfPresent([String: CachedFile].self, forKey: .records) ?? [:]
    let history = try container.decodeIfPresent(
      [ProviderID: [String: ArchivedUsageDay]].self, forKey: .dailyHistory) ?? [:]
    self.dailyHistory = Self.bounded(history)
  }

  private static let maximumProviders = 8
  private static let maximumDaysPerProvider = CachedUsageHistory.retentionDays

  private static func bounded(
    _ history: [ProviderID: [String: ArchivedUsageDay]]
  ) -> [ProviderID: [String: ArchivedUsageDay]] {
    var kept: [ProviderID: [String: ArchivedUsageDay]] = [:]
    for provider in history.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(maximumProviders) {
      guard let days = history[provider] else { continue }
      var rows: [String: ArchivedUsageDay] = [:]
      for key in days.keys.filter(LocalUsageScanner.isArchiveDayKey).sorted().suffix(maximumDaysPerProvider) {
        if let day = days[key] { rows[key] = day }
      }
      if !rows.isEmpty { kept[provider] = rows }
    }
    return kept
  }
}

private struct CachedFile: Codable {
  let provider: ProviderID
  var size: Int64
  var modifiedAt: TimeInterval
  var offset: Int64
  var days: [String: UsageTotals]
  var recentRows: [String: CachedRow]
  var recentOrder: [String]
  /// Optional for schema compatibility. A missing identity forces one safe
  /// reparse, after which same-size rewrites and path replacements are visible.
  var device: UInt64? = nil
  var inode: UInt64? = nil
  var changedAt: TimeInterval? = nil
  /// Persists across the per-file byte budget so an oversized unterminated
  /// record cannot have its continuation parsed as a fresh record next time.
  var discardingOversizedLine: Bool? = nil

  func totals(since cutoffKey: String) -> UsageTotals {
    self.days.filter { $0.key >= cutoffKey }.values.reduce(into: UsageTotals()) { result, value in
      result.add(value)
    }
  }
}

struct CachedRow: Codable, Equatable {
  let key: String?
  let dayKey: String
  let totals: UsageTotals
}

struct UsageTotals: Codable, Equatable {
  var input: Int64 = 0
  var cached: Int64 = 0
  var cacheWrite: Int64 = 0
  var output: Int64 = 0
  var costUSD: Double = 0
  var estimated = false

  mutating func add(_ other: UsageTotals) {
    self.input = saturatingNonnegativeSum(self.input, other.input)
    self.cached = saturatingNonnegativeSum(self.cached, other.cached)
    self.cacheWrite = saturatingNonnegativeSum(self.cacheWrite, other.cacheWrite)
    self.output = saturatingNonnegativeSum(self.output, other.output)
    let nextCost = self.costUSD + max(0, other.costUSD)
    self.costUSD = nextCost.isFinite ? nextCost : Double.greatestFiniteMagnitude
    self.estimated = self.estimated || other.estimated
  }

  mutating func subtract(_ other: UsageTotals) {
    self.input = saturatingNonnegativeSubtract(self.input, other.input)
    self.cached = saturatingNonnegativeSubtract(self.cached, other.cached)
    self.cacheWrite = saturatingNonnegativeSubtract(self.cacheWrite, other.cacheWrite)
    self.output = saturatingNonnegativeSubtract(self.output, other.output)
    self.costUSD = max(0, self.costUSD - other.costUSD)
  }

  func totalTokens(provider: ProviderID) -> Int64 {
    saturatingNonnegativeSum(
      self.input, provider == .anthropic ? self.cached : 0, self.cacheWrite, self.output)
  }

  func summary(
    provider: ProviderID,
    periodDays: Int,
    today: UsageTotals,
    cycle: UsageTotals,
    cycleStartedAt: Date,
    now: Date,
    dailyTokens: [DailyUsage] = []
  ) -> LocalUsageSummary {
    LocalUsageSummary(
      provider: provider,
      periodDays: periodDays,
      inputTokens: self.input,
      cachedInputTokens: self.cached,
      cacheWriteInputTokens: self.cacheWrite,
      outputTokens: self.output,
      apiEquivalentCostUSD: self.costUSD,
      isCostEstimate: self.estimated,
      todayTokens: today.totalTokens(provider: provider),
      cycleTokens: cycle.totalTokens(provider: provider),
      cycleAPIEquivalentCostUSD: cycle.costUSD,
      cycleStartedAt: cycleStartedAt,
      isCycleCostEstimate: cycle.estimated,
      fetchedAt: now,
      dailyTokens: dailyTokens)
  }
}

private enum Pricing {
  private struct Rates {
    let input: Double
    let cached: Double
    let cacheWrite: Double
    let output: Double
  }

  static func apiCost(
    provider: ProviderID,
    model: String,
    input: Int64,
    cached: Int64,
    cacheWrite: Int64,
    cacheWriteOneHour: Int64,
    output: Int64
  ) -> Double? {
    guard let rates = self.rates(provider: provider, model: model.lowercased()) else { return nil }
    if provider == .openAI {
      let cachedSubset = min(max(0, cached), max(0, input))
      let remaining = max(0, input) - cachedSubset
      let writeSubset = min(max(0, cacheWrite), remaining)
      let uncached = remaining - writeSubset
      return
        (Double(uncached) * rates.input
        + Double(cachedSubset) * rates.cached
        + Double(writeSubset) * rates.cacheWrite
        + Double(max(0, output)) * rates.output) / 1_000_000
    }
    let oneHour = min(max(0, cacheWriteOneHour), max(0, cacheWrite))
    let standardWrite = max(0, cacheWrite) - oneHour
    return
      (Double(max(0, input)) * rates.input
      + Double(max(0, cached)) * rates.cached
      + Double(standardWrite) * rates.cacheWrite
      + Double(oneHour) * rates.input * 2
      + Double(max(0, output)) * rates.output) / 1_000_000
  }

  private static func rates(provider: ProviderID, model: String) -> Rates? {
    switch provider {
    // Copilot, Z.ai, Kimi and Gemini have no local session history to price.
    case .copilot, .zai, .kimi, .gemini: return nil
    case .openAI:
      if model.contains("5.6-sol") {
        return Rates(input: 5, cached: 0.5, cacheWrite: 6.25, output: 30)
      }
      if model.contains("5.6-terra") {
        return Rates(input: 2.5, cached: 0.25, cacheWrite: 3.125, output: 15)
      }
      if model.contains("5.6-luna") {
        return Rates(input: 1, cached: 0.1, cacheWrite: 1.25, output: 6)
      }
      if model.contains("5.5") { return Rates(input: 5, cached: 0.5, cacheWrite: 5, output: 30) }
      if model.contains("5.4-mini") {
        return Rates(input: 0.75, cached: 0.075, cacheWrite: 0.75, output: 4.5)
      }
      if model.contains("5.4") {
        return Rates(input: 2.5, cached: 0.25, cacheWrite: 2.5, output: 15)
      }
      if model.contains("5.3") || model.contains("5.2") {
        return Rates(input: 1.75, cached: 0.175, cacheWrite: 1.75, output: 14)
      }
      return nil
    case .anthropic:
      if model.contains("fable-5") {
        return Rates(input: 10, cached: 1, cacheWrite: 12.5, output: 50)
      }
      if model.contains("sonnet-5") {
        return Rates(input: 2, cached: 0.2, cacheWrite: 2.5, output: 10)
      }
      if model.contains("opus-5") || model.contains("opus-4-8") || model.contains("opus-4.8") {
        return Rates(input: 5, cached: 0.5, cacheWrite: 6.25, output: 25)
      }
      if model.contains("sonnet-4") {
        return Rates(input: 3, cached: 0.3, cacheWrite: 3.75, output: 15)
      }
      if model.contains("opus-4") {
        return Rates(input: 5, cached: 0.5, cacheWrite: 6.25, output: 25)
      }
      if model.contains("haiku") {
        return Rates(input: 1, cached: 0.1, cacheWrite: 1.25, output: 5)
      }
      return nil
    case .grok:
      if model.contains("build") { return Rates(input: 1, cached: 0.2, cacheWrite: 1, output: 2) }
      if model.contains("4.6") || model.contains("4.5") {
        return Rates(input: 2, cached: 0.5, cacheWrite: 2, output: 6)
      }
      if model.contains("4.3") || model.contains("4.20") {
        return Rates(input: 1.25, cached: 0.2, cacheWrite: 1.25, output: 2.5)
      }
      return nil
    case .cursor:
      // Cursor supplies provider-reported costs. Reserve never estimates them
      // from local transcripts.
      return nil
    }
  }
}
