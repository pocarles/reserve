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
    dailyTokens: [DailyUsage] = []
  ) {
    let normalizedInput = max(0, inputTokens)
    let normalizedCached = max(0, cachedInputTokens)
    let normalizedCacheWrite = max(0, cacheWriteInputTokens)
    let normalizedOutput = max(0, outputTokens)
    let fallbackTokens = saturatingNonnegativeSum(
      normalizedInput, provider == .anthropic ? normalizedCached : 0,
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
  }

  public var totalTokens: Int64 {
    self.totalTokensValue
  }

  private var totalTokensValue: Int64 {
    saturatingNonnegativeSum(
      self.inputTokens, self.provider == .anthropic ? self.cachedInputTokens : 0,
      self.cacheWriteInputTokens, self.outputTokens)
  }
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
  private var fileKeys: [ProviderID: [String: String]] = [:]

  public init(
    roots: Roots = .defaults(),
    cacheURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.roots = roots
    self.fileManager = fileManager
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
    now: Date = Date()
  ) throws -> [ProviderID: LocalUsageSummary] {
    let deadline = Date().addingTimeInterval(self.maximumScanDuration)
    let days = min(90, max(1, periodDays))
    let cutoff = Calendar.current.date(byAdding: .day, value: -days + 1, to: now) ?? now
    let cutoffKey = Self.dayKey(cutoff)
    var index = self.loadIndex()
    try Self.checkDeadline(deadline)
    var retainedKeys: Set<String> = []
    var indexChanged = false

    let codex = try self.scanCodex(
      cutoff: cutoff, cutoffKey: cutoffKey, index: &index, retainedKeys: &retainedKeys,
      indexChanged: &indexChanged, deadline: deadline)
    let claude = try self.scanClaude(
      cutoff: cutoff, cutoffKey: cutoffKey, index: &index, retainedKeys: &retainedKeys,
      indexChanged: &indexChanged, deadline: deadline)
    let grok = try self.scanGrok(
      cutoff: cutoff, cutoffKey: cutoffKey, index: &index, retainedKeys: &retainedKeys,
      indexChanged: &indexChanged, deadline: deadline)

    try Self.checkDeadline(deadline)
    let previousRecordCount = index.records.count
    index.records = index.records.filter { retainedKeys.contains($0.key) }
    try Self.checkDeadline(deadline)
    if index.records.count != previousRecordCount { indexChanged = true }
    if indexChanged {
      index.updatedAt = now
      try self.saveIndex(index, deadline: deadline)
    }

    let todayKey = Self.dayKey(now)
    let series = try Self.dailySeries(index: index, days: days, now: now, deadline: deadline)
    func summary(_ provider: ProviderID, fallback: UsageTotals) throws -> LocalUsageSummary {
      try Self.checkDeadline(deadline)
      let cycleStart = cycleStarts[provider] ?? cutoff
      let today = try Self.aggregate(
        provider: provider, since: todayKey, index: index, deadline: deadline)
      let cycle = try Self.aggregate(
        provider: provider, since: Self.dayKey(cycleStart), index: index, deadline: deadline)
      return fallback.summary(
        provider: provider,
        periodDays: days,
        today: today,
        cycle: cycle,
        cycleStartedAt: cycleStart,
        now: now,
        dailyTokens: series[provider] ?? [])
    }
    return [
      .openAI: try summary(.openAI, fallback: codex),
      .anthropic: try summary(.anthropic, fallback: claude),
      .grok: try summary(.grok, fallback: grok),
    ]
  }

  /// Continuous daily series for every provider, quiet days included so a chart
  /// has an even axis. One pass over the index, bounded to the period.
  private static func dailySeries(
    index: UsageIndex,
    days: Int,
    now: Date,
    deadline: Date
  ) throws -> [ProviderID: [DailyUsage]] {
    let calendar = Calendar.current
    let keys: [String] = (0..<days).reversed().compactMap { offset in
      calendar.date(byAdding: .day, value: -offset, to: now).map(Self.dayKey)
    }
    guard let cutoffKey = keys.first else { return [:] }

    var totals: [ProviderID: [String: UsageTotals]] = [:]
    for (recordIndex, record) in index.records.values.enumerated() {
      if recordIndex.isMultiple(of: 128) { try Self.checkDeadline(deadline) }
      for (day, value) in record.days where day >= cutoffKey {
        totals[record.provider, default: [:]][day, default: UsageTotals()].add(value)
      }
    }
    try Self.checkDeadline(deadline)
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
    deadline: Date
  ) throws -> UsageTotals {
    var result = UsageTotals()
    for (recordIndex, record) in index.records.values.enumerated() {
      if recordIndex.isMultiple(of: 128) { try Self.checkDeadline(deadline) }
      guard record.provider == provider else { continue }
      result.add(record.totals(since: cutoffKey))
    }
    return result
  }

  private static func checkDeadline(_ deadline: Date) throws {
    guard Date() <= deadline else { throw UsageProviderError.timedOut("local usage scan") }
  }

  private func scanCodex(
    cutoff: Date,
    cutoffKey: String,
    index: inout UsageIndex,
    retainedKeys: inout Set<String>,
    indexChanged: inout Bool,
    deadline: Date
  ) throws -> UsageTotals {
    var total = UsageTotals()
    var remainingBytes = self.maximumBytesPerScan
    for file in try self.recentFiles(
      root: self.roots.codex, named: nil, extension: "jsonl", cutoff: cutoff,
      deadline: deadline)
    {
      try Task.checkCancellation()
      try Self.checkDeadline(deadline)
      let fileTotals = try autoreleasepool {
        let metadata = try self.metadata(file)
        let key = self.fileKey(provider: .openAI, url: file)
        retainedKeys.insert(key)
        guard index.records[key] != nil || index.records.count < Self.maximumScannedFiles else {
          return UsageTotals()
        }
        var record = index.records[key]
        if record?.size != metadata.size || record?.modifiedAt != metadata.modifiedAt {
          let requiredBytes = min(self.codexTailBytes, max(0, Int(clamping: metadata.size)))
          if requiredBytes <= remainingBytes {
            let parsed = try self.parseCodexTail(
              file, deadline: deadline, remainingBytes: &remainingBytes)
            record = CachedFile(
              provider: .openAI,
              size: metadata.size,
              modifiedAt: metadata.modifiedAt,
              offset: metadata.size,
              days: parsed.map { [Self.dayKey($0.timestamp): $0.totals] } ?? [:],
              recentRows: [:],
              recentOrder: [])
            index.records[key] = record
            indexChanged = true
          }
        }
        return record?.totals(since: cutoffKey) ?? UsageTotals()
      }
      total.add(fileTotals)
      try Self.checkDeadline(deadline)
    }
    return total
  }

  private func scanClaude(
    cutoff: Date,
    cutoffKey: String,
    index: inout UsageIndex,
    retainedKeys: inout Set<String>,
    indexChanged: inout Bool,
    deadline: Date
  ) throws -> UsageTotals {
    var total = UsageTotals()
    var remainingBytes = self.maximumBytesPerScan
    for file in try self.recentFiles(
      root: self.roots.claude, named: nil, extension: "jsonl", cutoff: cutoff,
      deadline: deadline)
    {
      try Task.checkCancellation()
      try Self.checkDeadline(deadline)
      let fileTotals = try autoreleasepool {
        let metadata = try self.metadata(file)
        let key = self.fileKey(provider: .anthropic, url: file)
        retainedKeys.insert(key)
        guard index.records[key] != nil || index.records.count < Self.maximumScannedFiles else {
          return UsageTotals()
        }
        var record = index.records[key]
        if record?.provider != .anthropic || metadata.size < (record?.offset ?? 0) {
          record = CachedFile(
            provider: .anthropic, size: 0, modifiedAt: 0, offset: 0,
            days: [:], recentRows: [:], recentOrder: [])
        }
        if (record?.size != metadata.size || record?.modifiedAt != metadata.modifiedAt
          || (record?.offset ?? 0) < metadata.size
        ), remainingBytes > 0 {
          var updated = record!
          let scanResult = try self.scanLines(
            file, from: updated.offset,
            discardingOversizedLine: updated.discardingOversizedLine ?? false,
            deadline: deadline, remainingBytes: &remainingBytes
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
          updated.days = updated.days.filter { $0.key >= cutoffKey }
          record = updated
          index.records[key] = updated
          indexChanged = true
        }
        return record?.totals(since: cutoffKey) ?? UsageTotals()
      }
      total.add(fileTotals)
      try Self.checkDeadline(deadline)
    }
    return total
  }

  private func scanGrok(
    cutoff: Date,
    cutoffKey: String,
    index: inout UsageIndex,
    retainedKeys: inout Set<String>,
    indexChanged: inout Bool,
    deadline: Date
  ) throws -> UsageTotals {
    var total = UsageTotals()
    var remainingBytes = self.maximumBytesPerScan
    for file in try self.recentFiles(
      root: self.roots.grok, named: "signals.json", extension: nil, cutoff: cutoff,
      deadline: deadline)
    {
      try Task.checkCancellation()
      try Self.checkDeadline(deadline)
      let metadata = try self.metadata(file)
      let key = self.fileKey(provider: .grok, url: file)
      retainedKeys.insert(key)
      guard index.records[key] != nil || index.records.count < Self.maximumScannedFiles else {
        continue
      }
      var record = index.records[key]
      if record?.size != metadata.size || record?.modifiedAt != metadata.modifiedAt {
        let readableBytes = max(0, Int(clamping: metadata.size))
        if readableBytes > 256 * 1_024 {
          record = CachedFile(
            provider: .grok, size: metadata.size, modifiedAt: metadata.modifiedAt,
            offset: metadata.size, days: [:], recentRows: [:], recentOrder: [])
          index.records[key] = record
          indexChanged = true
        } else if readableBytes <= remainingBytes {
          let data = BoundedFileReader.read(file, maximumBytes: 256 * 1024)
          remainingBytes -= data?.count ?? 0
          let parsed = data.flatMap(Self.parseGrokSignal)
          record = CachedFile(
            provider: .grok,
            size: metadata.size,
            modifiedAt: metadata.modifiedAt,
            offset: metadata.size,
            days: parsed.map { [Self.dayKey(metadata.date): $0] } ?? [:],
            recentRows: [:],
            recentOrder: [])
          index.records[key] = record
          indexChanged = true
        }
      }
      total.add(record?.totals(since: cutoffKey) ?? UsageTotals())
      try Self.checkDeadline(deadline)
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
      try Task.checkCancellation()
      guard Date() <= deadline else { throw UsageProviderError.timedOut("local usage scan") }
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
    try Self.checkDeadline(deadline)
    files.sort { $0.modified > $1.modified }
    try Self.checkDeadline(deadline)
    return files.map(\.url)
  }

  /// A ceiling on how much of a tree one scan will walk.
  private static let maximumScannedFiles = 5_000
  private static let maximumEnumeratedEntries = 20_000

  private func metadata(_ file: URL) throws -> (size: Int64, modifiedAt: TimeInterval, date: Date) {
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let date = values.contentModificationDate ?? .distantPast
    return (Int64(values.fileSize ?? 0), date.timeIntervalSince1970, date)
  }

  private func parseCodexTail(
    _ file: URL,
    deadline: Date,
    remainingBytes: inout Int
  ) throws -> (timestamp: Date, totals: UsageTotals)? {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    var start = size
    var data = Data()
    while start > 0, data.count < self.codexTailBytes, remainingBytes > 0 {
      try Self.checkDeadline(deadline)
      let step = min(UInt64(self.codexTailStepBytes), start, UInt64(remainingBytes))
      start -= step
      try handle.seek(toOffset: start)
      var expanded = try handle.read(upToCount: Int(step)) ?? Data()
      remainingBytes -= expanded.count
      expanded.append(data)
      data = expanded

      let hasUsage = data.range(of: Data(#""token_count""#.utf8)) != nil
      let hasModel = data.range(of: Data(#""turn_context""#.utf8)) != nil
      if hasUsage, hasModel { break }
    }
    if start > 0, let newline = data.firstIndex(of: 0x0A) {
      data.removeSubrange(data.startIndex...newline)
    }
    return try Self.parseCodexTailData(data, deadline: deadline)
  }

  static func parseCodexTailData(_ data: Data) -> (timestamp: Date, totals: UsageTotals)? {
    try? Self.parseCodexTailData(data, deadline: nil)
  }

  private static func parseCodexTailData(
    _ data: Data,
    deadline: Date?
  ) throws -> (timestamp: Date, totals: UsageTotals)? {
    var currentModel: String?
    var latest: (Date, UsageTotals)?
    for (lineIndex, line) in data.split(separator: 0x0A).prefix(100_000).enumerated()
    where line.count <= 1024 * 1024
    {
      if lineIndex.isMultiple(of: 256), let deadline { try Self.checkDeadline(deadline) }
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
    _ file: URL,
    from offset: Int64,
    discardingOversizedLine: Bool,
    deadline: Date,
    remainingBytes: inout Int,
    visit: (Data) -> Void
  ) throws -> (offset: Int64, discardingOversizedLine: Bool) {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
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
      try Task.checkCancellation()
      guard Date() <= deadline else { throw UsageProviderError.timedOut("local usage scan") }
      let allowance = min(64 * 1_024, remainingBytes, fileBytesRemaining)
      guard let chunk = try handle.read(upToCount: allowance), !chunk.isEmpty else { break }
      remainingBytes -= chunk.count
      fileBytesRemaining -= chunk.count
      let result = buffer.append(
        chunk, maximumLines: self.maximumLinesPerFile - lineCount)
      consumedBytes += result.consumedBytes
      for data in result.lines {
        lineCount += 1
        autoreleasepool { visit(data) }
      }
    }
    try Self.checkDeadline(deadline)
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
    guard let data = BoundedFileReader.read(self.cacheURL, maximumBytes: self.maximumCacheBytes),
      let index = try? JSONDecoder().decode(UsageIndex.self, from: data),
      index.version == 1,
      index.records.count <= Self.maximumScannedFiles,
      index.records.values.allSatisfy({ record in
        record.days.count <= 100 && record.recentRows.count <= 128
          && record.recentOrder.count <= 128
      })
    else { return UsageIndex() }
    return index
  }

  private func saveIndex(_ index: UsageIndex, deadline: Date) throws {
    try Self.checkDeadline(deadline)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(index)
    try Self.checkDeadline(deadline)
    guard data.count <= self.maximumCacheBytes else {
      throw UsageProviderError.invalidResponse("local usage index exceeded 12 MB")
    }
    try BoundedFileReader.writeRestricted(data, to: self.cacheURL, fileManager: self.fileManager)
    try Self.checkDeadline(deadline)
  }

  private func fileKey(provider: ProviderID, url: URL) -> String {
    let path = url.standardizedFileURL.path
    if let cached = self.fileKeys[provider]?[path] { return cached }
    let digest = SHA256.hash(data: Data(path.utf8))
    let key = provider.rawValue + ":" + digest.map { String(format: "%02x", $0) }.joined()
    if self.fileKeys.values.reduce(0, { $0 + $1.count }) >= Self.maximumScannedFiles {
      self.fileKeys.removeAll(keepingCapacity: true)
    }
    self.fileKeys[provider, default: [:]][path] = key
    return key
  }

  private static func dayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static func parseDate(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }

  private static func int64(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) ?? 0 }
    return 0
  }
}

private struct UsageIndex: Codable {
  var version = 1
  var updatedAt = Date.distantPast
  var records: [String: CachedFile] = [:]
}

private struct CachedFile: Codable {
  let provider: ProviderID
  var size: Int64
  var modifiedAt: TimeInterval
  var offset: Int64
  var days: [String: UsageTotals]
  var recentRows: [String: CachedRow]
  var recentOrder: [String]
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
    }
  }
}
