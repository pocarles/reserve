import CoreServices
import Foundation
import Testing
@testable import ReserveCore

@Suite
struct IncrementalHistoryTests {
  @Test func eventsDuringAFullScanKeepTheProviderDirty() throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let tracker = LocalHistoryChangeTracker()
    tracker.simulate = true
    tracker.synchronize(roots: [.openAI: fixture.codex])
    tracker.inject(provider: .openAI, overflow: true)
    let instant = ContinuousClock.now
    let planned = try #require(
      tracker.plan(
        providers: [.openAI], now: instant, fullDiscoveryInterval: .seconds(60)
      ).first)
    tracker.inject(
      provider: .openAI, changed: [fixture.codex.appendingPathComponent("late.jsonl")])
    tracker.acknowledge(provider: .openAI, token: planned.token, full: true, now: instant)
    let after = try #require(
      tracker.plan(
        providers: [.openAI], now: instant, fullDiscoveryInterval: .seconds(60)
      ).first)
    #expect(after.token > planned.token)
    if case .skip = after.visit {
      Issue.record("an event that arrived during a full scan was acknowledged as clean")
    }
  }

  @Test func periodicFallbackPreemptsAContinuousSparseStream() throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let tracker = LocalHistoryChangeTracker()
    tracker.simulate = true
    tracker.synchronize(roots: [.openAI: fixture.codex])
    let instant = ContinuousClock.now
    let baseline = try #require(
      tracker.plan(
        providers: [.openAI], now: instant, fullDiscoveryInterval: .seconds(60)
      ).first)
    tracker.acknowledge(provider: .openAI, token: baseline.token, full: true, now: instant)
    tracker.inject(
      provider: .openAI, changed: [fixture.codex.appendingPathComponent("changed.jsonl")])
    let due = try #require(
      tracker.plan(
        providers: [.openAI], now: instant.advanced(by: .seconds(61)),
        fullDiscoveryInterval: .seconds(60)
      ).first)
    #expect(due.visit == .full(.interval))
  }

  @Test func globalDroppedEventInvalidatesAllRootsEvenWithAnUnrelatedPath() throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let tracker = LocalHistoryChangeTracker()
    tracker.simulate = true
    tracker.synchronize(roots: [.openAI: fixture.codex, .anthropic: fixture.claude])
    let instant = ContinuousClock.now
    for plan in tracker.plan(
      providers: [.openAI, .anthropic], now: instant, fullDiscoveryInterval: .seconds(60))
    {
      tracker.acknowledge(provider: plan.provider, token: plan.token, full: true, now: instant)
    }
    tracker.handle(
      paths: ["/unrelated/event"],
      flags: [UInt32(kFSEventStreamEventFlagKernelDropped)])
    let plans = tracker.plan(
      providers: [.openAI, .anthropic], now: instant,
      fullDiscoveryInterval: .seconds(60))
    #expect(plans.allSatisfy { $0.visit == .full(.overflow) })
  }

  @Test func replacingAWatchedRootRecreatesItsBaseline() throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let tracker = LocalHistoryChangeTracker()
    defer { tracker.stopAll() }
    tracker.synchronize(roots: [.openAI: fixture.codex])
    let instant = ContinuousClock.now
    let baseline = try #require(
      tracker.plan(
        providers: [.openAI], now: instant, fullDiscoveryInterval: .seconds(60)
      ).first)
    tracker.acknowledge(provider: .openAI, token: baseline.token, full: true, now: instant)
    try FileManager.default.removeItem(at: fixture.codex)
    try FileManager.default.createDirectory(at: fixture.codex, withIntermediateDirectories: true)
    tracker.synchronize(roots: [.openAI: fixture.codex])
    let replacement = try #require(
      tracker.plan(
        providers: [.openAI], now: instant, fullDiscoveryInterval: .seconds(60)
      ).first)
    #expect(replacement.visit == .full(.baseline))
    #expect(tracker.isWatching(.openAI))
  }

  @Test func rootChangedWhileStreamStartsIsNotInstalledAsCurrent() throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let tracker = LocalHistoryChangeTracker()
    defer { tracker.stopAll() }
    tracker.testingBeforeInstallingStreams = {
      try! FileManager.default.removeItem(at: fixture.codex)
      try! FileManager.default.createDirectory(
        at: fixture.codex, withIntermediateDirectories: true)
    }
    tracker.synchronize(roots: [.openAI: fixture.codex])
    #expect(tracker.isWatching(.openAI) == false)
    tracker.testingBeforeInstallingStreams = nil
    tracker.synchronize(roots: [.openAI: fixture.codex])
    #expect(tracker.isWatching(.openAI))
    let plan = try #require(
      tracker.plan(
        providers: [.openAI], now: .now, fullDiscoveryInterval: .seconds(60)
      ).first)
    #expect(plan.visit == .full(.baseline))
  }

  @Test func coldScanReusesDecodedIndexForCachedHistory() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 10, output: 2, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    let summary = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    #expect(summary[.openAI]?.totalTokens == 12)
    let decoded = await scanner.scanMetrics.indexDecodes
    let history = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    #expect(history[.openAI]?.days.contains { $0.tokens == 12 } == true)
    #expect(await scanner.scanMetrics.indexDecodes == decoded)
    #expect(await scanner.scanMetrics.indexReuses >= 1)
    let cache = try String(decoding: Data(contentsOf: fixture.cache), as: UTF8.self)
    #expect(!cache.contains(fixture.root.path))
  }

  @Test func warmUnchangedScanDoesNotDecodeOrWalk() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 6, output: 1, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(now: now, providers: [.openAI])
    let before = await scanner.scanMetrics
    let again = try await scanner.scan(now: now.addingTimeInterval(30), providers: [.openAI])
    let after = await scanner.scanMetrics
    #expect(again[.openAI]?.totalTokens == 7)
    #expect(again[.openAI]?.fetchedAt == now)
    #expect(after.indexDecodes == before.indexDecodes)
    #expect(after.treeWalks == before.treeWalks)
    #expect(after.filesParsed == before.filesParsed)
    #expect(after.warmSkips >= 1)
  }

  @Test func defaultScannerStillWalksWhenWatchingIsOff() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 3, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: false)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(await scanner.scanMetrics.treeWalks >= 2)
    #expect(await scanner.testingIsWatching(.openAI) == false)
  }

  @Test func sparseEditParsesOnlyTheChangedFile() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let first = try fixture.writeCodex("a.jsonl", input: 1, output: 0, at: now)
    let second = try fixture.writeCodex("nested/b.jsonl", input: 2, output: 0, at: now)
    _ = try fixture.writeCodex("c.jsonl", input: 4, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    let initial = try await scanner.scan(now: now, providers: [.openAI])
    #expect(initial[.openAI]?.totalTokens == 7)
    let before = await scanner.scanMetrics
    try fixture.writeCodex("nested/b.jsonl", input: 8, output: 0, at: now, url: second)
    await scanner.testingInject(provider: .openAI, changed: [second])
    let updated = try await scanner.scan(now: now.addingTimeInterval(5), providers: [.openAI])
    let after = await scanner.scanMetrics
    #expect(updated[.openAI]?.totalTokens == 13)
    #expect(after.filesParsed == before.filesParsed + 1)
    #expect(after.treeWalks == before.treeWalks)
    #expect(after.sparseVisits >= 1)
    _ = first
  }

  @Test func sameLengthRewriteAndReplacementIgnoreRestoredModificationTime() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let file = try fixture.writeCodex("same.jsonl", input: 11, output: 0, at: now)
    let originalDate = try #require(
      FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    let initial = try await scanner.scan(now: now, providers: [.openAI])
    #expect(initial[.openAI]?.totalTokens == 11)

    let rewritten = fixture.codexData(input: 22, output: 0, at: now)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: rewritten)
    try handle.close()
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: file.path)
    await scanner.testingInject(provider: .openAI, changed: [file])
    let afterRewrite = try await scanner.scan(
      now: now.addingTimeInterval(1), providers: [.openAI])
    #expect(afterRewrite[.openAI]?.totalTokens == 22)

    let replacement = fixture.codex.appendingPathComponent("replacement.jsonl")
    try fixture.codexData(input: 33, output: 0, at: now).write(to: replacement)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: replacement.path)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: replacement, to: file)
    await scanner.testingInject(provider: .openAI, changed: [file])
    let afterReplacement = try await scanner.scan(
      now: now.addingTimeInterval(2), providers: [.openAI])
    #expect(afterReplacement[.openAI]?.totalTokens == 33)
  }

  @Test func rotationAndTruncationReplaceTotals() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let codex = try fixture.writeCodex("turn.jsonl", input: 10, output: 0, at: now)
    let claude = try fixture.writeClaude("session.jsonl", input: 30, output: 5, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    let initial = try await scanner.scan(now: now, providers: [.openAI, .anthropic])
    #expect(initial[.openAI]?.totalTokens == 10)
    #expect(initial[.anthropic]?.totalTokens == 35)
    try fixture.writeCodex("turn.jsonl", input: 4, output: 0, at: now, url: codex)
    await scanner.testingInject(provider: .openAI, changed: [codex])
    let rotated = try await scanner.scan(now: now.addingTimeInterval(2), providers: [.openAI])
    #expect(rotated[.openAI]?.totalTokens == 4)
    try Data((fixture.claudeLine(
      input: 2, output: 1, at: now, message: "m2", request: "r2") + "\n").utf8)
      .write(to: claude)
    await scanner.testingInject(provider: .anthropic, changed: [claude])
    let truncated = try await scanner.scan(now: now.addingTimeInterval(3), providers: [.anthropic])
    #expect(truncated[.anthropic]?.totalTokens == 3)
  }

  @Test func droppedEventsAndRenamesFallBackToFullDiscovery() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 5, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(now: now, providers: [.openAI])
    let walked = await scanner.scanMetrics.treeWalks
    await scanner.testingInject(provider: .openAI, overflow: true)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(await scanner.scanMetrics.overflowFallbacks >= 1)
    #expect(await scanner.scanMetrics.treeWalks == walked + 1)
    await scanner.testingInject(provider: .openAI, renamed: true)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(await scanner.scanMetrics.treeWalks == walked + 2)
  }

  @Test func disablingAProviderStopsItsWatchAndReenableWalks() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 3, output: 0, at: now)
    let claude = try fixture.writeClaude("session.jsonl", input: 10, output: 1, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(now: now, providers: [.openAI, .anthropic])
    #expect(await scanner.testingIsWatching(.openAI))
    #expect(await scanner.testingIsWatching(.anthropic))
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(await scanner.testingIsWatching(.openAI))
    #expect(await scanner.testingIsWatching(.anthropic) == false)
    try Data((fixture.claudeLine(
      input: 4, output: 1, at: now, message: "m2", request: "r2") + "\n").utf8)
      .write(to: claude)
    let walks = await scanner.scanMetrics.treeWalks
    let restored = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(await scanner.testingIsWatching(.anthropic))
    #expect(restored[.anthropic]?.totalTokens == 5)
    #expect(await scanner.scanMetrics.treeWalks > walks)
  }

  @Test func externalReplacementAndCorruptionInvalidateTheResidentIndex() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 11, output: 2, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    let legacy = """
    {"records":{"fixture":{"days":{"2026-09-01":{"cacheWrite":0,"cached":0,"costUSD":1.25,"estimated":false,"input":4,"output":1}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":0,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let history = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    #expect(history[.openAI]?.days.contains { $0.day == "2026-09-01" && $0.tokens == 5 } == true)
    #expect(history[.openAI]?.days.contains { $0.tokens == 13 } == false)
    try Data("not-json".utf8).write(to: fixture.cache)
    let broken = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    #expect(broken[.openAI]?.days.isEmpty == true)
    try Data(legacy.utf8).write(to: fixture.cache)
    let restored = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    #expect(restored[.openAI]?.days.contains { $0.tokens == 5 } == true)
  }

  @Test func deletedOrCorruptIndexForcesImmediateRediscovery() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 11, output: 2, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(now: now, providers: [.openAI])
    let firstWalks = await scanner.scanMetrics.treeWalks
    try FileManager.default.removeItem(at: fixture.cache)
    let afterDeletion = try await scanner.scan(
      now: now.addingTimeInterval(1), providers: [.openAI])
    #expect(afterDeletion[.openAI]?.totalTokens == 13)
    #expect(await scanner.scanMetrics.treeWalks == firstWalks + 1)
    try Data("broken".utf8).write(to: fixture.cache)
    let afterCorruption = try await scanner.scan(
      now: now.addingTimeInterval(2), providers: [.openAI])
    #expect(afterCorruption[.openAI]?.totalTokens == 13)
    #expect(await scanner.scanMetrics.treeWalks == firstWalks + 2)
  }

  @Test func externalIndexReplacementDuringScanIsNeverOverwritten() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let calendar = Calendar(identifier: .gregorian)
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12)))
    let file = try fixture.writeCodex("one.jsonl", input: 4, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(now: now, providers: [.openAI])
    try fixture.writeCodex("one.jsonl", input: 9, output: 0, at: now, url: file)
    await scanner.testingInject(provider: .openAI, changed: [file])
    let external = Data(
      #"{"records":{"external":{"days":{"2026-09-22":{"cacheWrite":0,"cached":0,"costUSD":0,"estimated":false,"input":5,"output":0}},"modifiedAt":0,"offset":0,"provider":"anthropic","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":1,"version":1}"#.utf8)
    await scanner.testingSetBeforePublish {
      try! external.write(to: fixture.cache)
    }
    await #expect(throws: UsageProviderError.invalidResponse(
      "local usage index changed during scan")) {
      try await scanner.scan(now: now.addingTimeInterval(1), providers: [.openAI])
    }
    #expect(try Data(contentsOf: fixture.cache) == external)

    let recovered = try await scanner.scan(
      now: now.addingTimeInterval(2), providers: [.openAI])
    #expect(recovered[.openAI]?.totalTokens == 9)
    let history = await scanner.cachedHistory(
      periodDays: 30, now: now, providers: [.anthropic])
    #expect(history[.anthropic]?.days.first { $0.day == "2026-09-22" }?.tokens == 5)
  }

  @Test func replacingTheIndexDropsAStaleCheckpoint() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let file = try fixture.writeCodex("one.jsonl", input: 7, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: false)
    _ = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    try fixture.writeCodex("one.jsonl", input: 8, output: 0, at: now, url: file)
    await scanner.testingSetBudget(commitLimit: 1)
    await #expect(throws: UsageProviderError.timedOut("local usage scan")) {
      try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    }
    #expect(await scanner.scanIncomplete)
    let legacy = """
    {"records":{"fixture":{"days":{"2026-09-01":{"cacheWrite":0,"cached":0,"costUSD":0,"estimated":false,"input":1,"output":0}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":1,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let finished = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    #expect(finished[.openAI]?.totalTokens == 8)
    #expect(await scanner.scanIncomplete == false)
  }

  @Test func cancellationLeavesSavedDataAndDoesNotDoubleCount() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let file = try fixture.writeCodex("one.jsonl", input: 4, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: false)
    _ = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    let saved = try Data(contentsOf: fixture.cache)
    try fixture.writeCodex("one.jsonl", input: 9, output: 0, at: now, url: file)
    await scanner.testingSetBudget(cancelAfterParsedFiles: 1)
    await #expect(throws: CancellationError.self) {
      try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    }
    #expect(try Data(contentsOf: fixture.cache) == saved)
    #expect(await scanner.testingCheckpointExists() == false)
    let history = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    #expect(history[.openAI]?.days.contains { $0.tokens == 4 } == true)
    #expect(history[.openAI]?.days.contains { $0.tokens == 9 } == false)
    let finished = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    #expect(finished[.openAI]?.totalTokens == 9)
  }

  @Test func boundedResumptionKeepsOlderHistoryWithoutDoubleCounting() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 15))!
    let older = now.addingTimeInterval(-40 * 24 * 60 * 60)
    let oldFile = try fixture.writeCodex(
      "old.jsonl", input: 4, output: 0, at: now, stamp: "2026-08-01T15:00:00Z")
    try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: oldFile.path)
    let scanner = fixture.scanner(watchChanges: false)
    _ = try await scanner.scan(periodDays: 90, now: now, providers: [.openAI])
    let published = try Data(contentsOf: fixture.cache)
    let newFile = try fixture.writeCodex(
      "new.jsonl", input: 10, output: 0, at: now, stamp: "2026-09-19T15:00:00Z")
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newFile.path)
    await scanner.testingSetBudget(commitLimit: 1)
    await #expect(throws: UsageProviderError.timedOut("local usage scan")) {
      try await scanner.scan(periodDays: 90, now: now, providers: [.openAI])
    }
    #expect(await scanner.scanIncomplete)
    #expect(try Data(contentsOf: fixture.cache) == published)
    #expect(await scanner.testingCheckpointExists())
    let partialHistory = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    let partialTokens = partialHistory[.openAI]?.days.compactMap(\.tokens) ?? []
    #expect(partialTokens.contains(4))
    #expect(!partialTokens.contains(10))
    let checkpoint = try Data(contentsOf: fixture.checkpoint)
    #expect(!String(decoding: checkpoint, as: UTF8.self).contains(fixture.root.path))
    try fixture.writeCodex(
      "new.jsonl", input: 10, output: 0, at: now, stamp: "2026-09-19T15:00:00Z", url: newFile)
    await scanner.testingSetBudget(cancelAfterParsedFiles: 1)
    await #expect(throws: CancellationError.self) {
      try await scanner.scan(periodDays: 90, now: now, providers: [.openAI])
    }
    #expect(try Data(contentsOf: fixture.cache) == published)
    #expect(try Data(contentsOf: fixture.checkpoint) == checkpoint)
    let parsed = await scanner.scanMetrics.filesParsed
    let finished = try await scanner.scan(periodDays: 90, now: now, providers: [.openAI])
    #expect(finished[.openAI]?.totalTokens == 14)
    #expect(await scanner.scanIncomplete == false)
    #expect(await scanner.scanMetrics.resumes >= 1)
    let finishedParsed = await scanner.scanMetrics.filesParsed
    // The file was touched after the checkpoint. Re-reading it is required;
    // correctness is proved by the totals below, not by trusting stale stamps.
    #expect(finishedParsed >= parsed)
    let history = await scanner.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    let tokens = history[.openAI]?.days.compactMap(\.tokens).sorted() ?? []
    #expect(tokens.contains(4))
    #expect(tokens.contains(10))
    #expect(!tokens.contains(20))
    #expect(!tokens.contains(24))
  }

  @Test func finalizationCheckpointRevalidatesFilesAfterRestart() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let file = try fixture.writeCodex("one.jsonl", input: 4, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: false)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    let published = try Data(contentsOf: fixture.cache)
    try fixture.writeCodex("one.jsonl", input: 9, output: 0, at: now, url: file)
    await scanner.testingSetBudget(stopBeforePublish: true)
    await #expect(throws: UsageProviderError.timedOut("local usage scan")) {
      try await scanner.scan(now: now.addingTimeInterval(1), providers: [.openAI])
    }
    #expect(try Data(contentsOf: fixture.cache) == published)
    #expect(await scanner.testingCheckpointExists())

    try fixture.writeCodex("one.jsonl", input: 13, output: 0, at: now, url: file)
    let restarted = fixture.scanner(watchChanges: false)
    let recovered = try await restarted.scan(
      now: now.addingTimeInterval(2), providers: [.openAI])
    #expect(recovered[.openAI]?.totalTokens == 13)
    #expect(await restarted.scanIncomplete == false)
    #expect(await restarted.testingCheckpointExists() == false)
  }

  @Test func zeroDurationAndTinyByteBudgetDoNotPublishPartialTotals() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 6, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: false)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    let saved = try Data(contentsOf: fixture.cache)
    await scanner.testingSetBudget(maximumDuration: .zero)
    await #expect(throws: UsageProviderError.timedOut("local usage scan")) {
      try await scanner.scan(now: now, providers: [.openAI])
    }
    #expect(await scanner.scanIncomplete)
    #expect(try Data(contentsOf: fixture.cache) == saved)
    try fixture.writeCodex("two.jsonl", input: 3, output: 0, at: now)
    await scanner.testingSetBudget(maximumBytes: 1)
    await #expect(throws: UsageProviderError.timedOut("local usage scan")) {
      try await scanner.scan(now: now, providers: [.openAI])
    }
    #expect(try Data(contentsOf: fixture.cache) == saved)
    await scanner.testingSetBudget()
    let finished = try await scanner.scan(now: now, providers: [.openAI])
    #expect(finished[.openAI]?.totalTokens == 9)
    #expect(await scanner.scanIncomplete == false)
  }

  @Test func missingWatchedRootDoesNotDeleteSavedHistory() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 5, output: 1, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    _ = try await scanner.scan(now: now, providers: [.openAI])
    let saved = try Data(contentsOf: fixture.cache)
    let missing = fixture.root.appendingPathComponent("missing-codex")
    let parked = fixture.scanner(watchChanges: true, codex: missing)
    await parked.testingSimulateWatch()
    let summary = try await parked.scan(now: now, providers: [.openAI])
    #expect(summary[.openAI]?.totalTokens == 6)
    #expect(try Data(contentsOf: fixture.cache) == saved)
  }

  @Test func periodicFallbackWalksAgain() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 2, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    await scanner.testingSetFullDiscoveryInterval(.zero)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(await scanner.scanMetrics.treeWalks >= 2)
    #expect(await scanner.scanMetrics.fullDiscoveries >= 2)
  }

  @Test func nativeWatchStartsAndStopsWithTheSelectedRoots() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    try fixture.writeCodex("one.jsonl", input: 1, output: 0, at: now)
    try fixture.writeClaude("session.jsonl", input: 1, output: 0, at: now)
    let scanner = fixture.scanner(watchChanges: true)
    _ = try await scanner.scan(now: now, providers: [.openAI, .anthropic])
    #expect(await scanner.testingIsWatching(.openAI))
    #expect(await scanner.testingIsWatching(.anthropic))
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(await scanner.testingIsWatching(.openAI))
    #expect(await scanner.testingIsWatching(.anthropic) == false)
    await scanner.stopWatching()
    #expect(await scanner.testingIsWatching(.openAI) == false)
  }

  @Test func syntheticBenchmarkColdWarmAndSparseStayBounded() async throws {
    let fixture = try HistoryBench()
    defer { fixture.remove() }
    let now = Date()
    let count = 24
    var urls: [URL] = []
    for index in 0..<count {
      urls.append(try fixture.writeCodex("bench/session-\(index).jsonl", input: index + 1, output: 0, at: now))
    }
    let scanner = fixture.scanner(watchChanges: true)
    await scanner.testingSimulateWatch()
    let cold = try await scanner.scan(now: now, providers: [.openAI])
    let coldMetrics = await scanner.scanMetrics
    #expect(cold[.openAI]?.totalTokens == Int64((count * (count + 1)) / 2))
    #expect(coldMetrics.filesParsed == count)
    #expect(coldMetrics.treeWalks == 1)
    #expect(coldMetrics.indexDecodes == 0)
    let warm = try await scanner.scan(now: now.addingTimeInterval(5), providers: [.openAI])
    let warmMetrics = await scanner.scanMetrics
    #expect(warm[.openAI]?.totalTokens == cold[.openAI]?.totalTokens)
    #expect(warmMetrics.filesParsed == coldMetrics.filesParsed)
    #expect(warmMetrics.treeWalks == coldMetrics.treeWalks)
    #expect(warmMetrics.indexDecodes == coldMetrics.indexDecodes)
    #expect(warmMetrics.warmSkips >= 1)
    let edited = urls[3]
    try fixture.writeCodex("bench/session-3.jsonl", input: 100, output: 0, at: now, url: edited)
    await scanner.testingInject(provider: .openAI, changed: [edited])
    let sparse = try await scanner.scan(now: now.addingTimeInterval(10), providers: [.openAI])
    let sparseMetrics = await scanner.scanMetrics
    let expected = Int64((count * (count + 1)) / 2) - 4 + 100
    #expect(sparse[.openAI]?.totalTokens == expected)
    #expect(sparseMetrics.filesParsed == coldMetrics.filesParsed + 1)
    #expect(sparseMetrics.treeWalks == coldMetrics.treeWalks)
    _ = await scanner.cachedHistory(now: now, providers: [.openAI])
    #expect(await scanner.scanMetrics.indexDecodes == coldMetrics.indexDecodes)
  }
}

private struct HistoryBench {
  let root: URL
  let codex: URL
  let claude: URL
  let grok: URL
  let cache: URL
  var checkpoint: URL { LocalHistoryCheckpoint.url(for: self.cache) }

  init() throws {
    self.root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-incremental-\(UUID().uuidString)", isDirectory: true)
    self.codex = self.root.appendingPathComponent("codex", isDirectory: true)
    self.claude = self.root.appendingPathComponent("claude", isDirectory: true)
    self.grok = self.root.appendingPathComponent("grok", isDirectory: true)
    self.cache = self.root.appendingPathComponent("index.json")
    for directory in [self.codex, self.claude, self.grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  func scanner(watchChanges: Bool, codex override: URL? = nil) -> LocalUsageScanner {
    LocalUsageScanner(
      roots: .init(codex: override ?? self.codex, claude: self.claude, grok: self.grok),
      cacheURL: self.cache,
      watchChanges: watchChanges)
  }

  @discardableResult
  func writeCodex(
    _ name: String, input: Int, output: Int, at date: Date, stamp: String? = nil, url: URL? = nil
  ) throws -> URL {
    let file = url ?? self.codex.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try self.codexData(input: input, output: output, at: date, stamp: stamp).write(to: file)
    return file
  }

  func codexData(input: Int, output: Int, at date: Date, stamp: String? = nil) -> Data {
    let timestamp = stamp ?? ISO8601DateFormatter().string(from: date)
    let line = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}}"#
    return Data((line + "\n").utf8)
  }

  func claudeLine(
    input: Int, output: Int, at date: Date, message: String = "m1", request: String = "r1"
  ) -> String {
    let timestamp = ISO8601DateFormatter().string(from: date)
    return #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"\#(request)","message":{"id":"\#(message)","model":"claude-opus-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
  }

  @discardableResult
  func writeClaude(_ name: String, input: Int, output: Int, at date: Date) throws -> URL {
    let file = self.claude.appendingPathComponent(name)
    try Data((self.claudeLine(input: input, output: output, at: date) + "\n").utf8).write(to: file)
    return file
  }

  func remove() {
    try? FileManager.default.removeItem(at: self.root)
  }
}
