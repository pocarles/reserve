import CoreServices
import Darwin
import Foundation

/// Why the next scan has to walk a provider instead of trusting the last one.
enum LocalHistoryFullReason: Equatable, Sendable {
  case baseline
  case interval
  case overflow
  case renamed
  case rootUnavailable
  case ambiguous
  case unwatched
}

enum LocalHistoryVisit: Equatable, Sendable {
  case skip
  case full(LocalHistoryFullReason)
  case sparse(changed: [URL], removed: [URL])
}

struct LocalHistoryVisitPlan: Equatable, Sendable {
  var provider: ProviderID
  var visit: LocalHistoryVisit
  /// Watcher generation at plan time. A later acknowledge is ignored when the
  /// generation moved, so events that arrive during the scan stay dirty.
  var token: Int
}

/// Dirty set for selected session roots.
///
/// FSEvents delivers nested file changes. There is no poll timer and no
/// provider process. The 0.25s value is the kernel's batching latency, which
/// `FSEventStreamCreate` requires; this type never schedules its own timer.
/// Paths stay in memory, capped, and are never logged. Past the cap, or when
/// an event is ambiguous, the provider falls back to a full walk.
final class LocalHistoryChangeTracker: @unchecked Sendable {
  fileprivate final class CallbackContext {
    weak var owner: LocalHistoryChangeTracker?

    init(owner: LocalHistoryChangeTracker) { self.owner = owner }
  }

  private final class StreamReleaseBatch: @unchecked Sendable {
    let streams: [FSEventStreamRef]

    init(_ streams: [FSEventStreamRef]) { self.streams = streams }
  }

  private struct RootIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
  }

  private struct PendingStart {
    var provider: ProviderID
    var path: String
    var identity: RootIdentity
    var generation: Int
  }

  private struct MutableState {
    var roots: [ProviderID: String] = [:]
    var rootIdentities: [ProviderID: RootIdentity] = [:]
    var streams: [ProviderID: FSEventStreamRef] = [:]
    var modes: [ProviderID: Mode] = [:]
    var generation: [ProviderID: Int] = [:]
    var lastFull: [ProviderID: ContinuousClock.Instant] = [:]
    var baselined: Set<ProviderID> = []
    var watching: Set<ProviderID> = []
  }

  private enum Mode: Equatable {
    case needsBaseline
    case clean
    case sparse(changed: [String], removed: [String])
    case full(LocalHistoryFullReason)
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.pocarles.reserve.history-events", qos: .utility)
  private var state = MutableState()
  /// When true, plans run without a kernel stream so tests can inject events.
  var simulate = false
  var testingBeforeInstallingStreams: (() -> Void)?
  private let sparseCap = 256

  deinit { self.stopStreams() }

  func stopAll() { self.stopStreams() }

  /// Watch `roots` and stop every provider that is no longer selected.
  /// A removed provider is baselined again the next time it is selected;
  /// events that happened while it was stopped were not recorded.
  func synchronize(roots: [ProviderID: URL]) {
    let normalized = roots.mapValues { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    var stopList: [FSEventStreamRef] = []
    var toStart: [PendingStart] = []
    self.lock.lock()
    let removed = self.state.watching.subtracting(normalized.keys)
    for provider in removed {
      if let stream = self.state.streams.removeValue(forKey: provider) {
        stopList.append(stream)
      }
      self.state.watching.remove(provider)
      self.state.baselined.remove(provider)
      self.state.lastFull.removeValue(forKey: provider)
      self.state.roots.removeValue(forKey: provider)
      self.state.rootIdentities.removeValue(forKey: provider)
      self.state.modes[provider] = .needsBaseline
      self.bumpLocked(provider)
    }
    for (provider, path) in normalized {
      let identity = Self.rootIdentity(path)
      let rootChanged = self.state.roots[provider] != path
        || self.state.rootIdentities[provider] != identity
      self.state.roots[provider] = path
      self.state.rootIdentities[provider] = identity
      if rootChanged {
        if let stream = self.state.streams.removeValue(forKey: provider) {
          stopList.append(stream)
        }
        self.state.baselined.remove(provider)
        self.state.lastFull.removeValue(forKey: provider)
        self.state.modes[provider] = .needsBaseline
        self.bumpLocked(provider)
      }
      if self.simulate {
        self.state.watching.insert(provider)
        if self.state.modes[provider] == nil { self.state.modes[provider] = .needsBaseline }
        continue
      }
      if self.state.streams[provider] != nil {
        self.state.watching.insert(provider)
        continue
      }
      guard let identity else {
        self.state.watching.remove(provider)
        self.state.modes[provider] = .full(.rootUnavailable)
        self.bumpLocked(provider)
        continue
      }
      toStart.append(PendingStart(
        provider: provider,
        path: path,
        identity: identity,
        generation: self.state.generation[provider] ?? 0))
    }
    self.lock.unlock()

    Self.release(stopList)
    var started: [(PendingStart, FSEventStreamRef)] = []
    var failed: [PendingStart] = []
    for pending in toStart {
      if let stream = self.makeStream(path: pending.path) {
        started.append((pending, stream))
      } else {
        failed.append(pending)
      }
    }
    self.testingBeforeInstallingStreams?()

    var abandoned: [FSEventStreamRef] = []
    self.lock.lock()
    for (pending, stream) in started {
      guard self.state.roots[pending.provider] == pending.path,
        self.state.rootIdentities[pending.provider] == pending.identity,
        self.state.generation[pending.provider] == pending.generation,
        Self.rootIdentity(pending.path) == pending.identity
      else {
        abandoned.append(stream)
        continue
      }
      if let previous = self.state.streams.updateValue(stream, forKey: pending.provider) {
        abandoned.append(previous)
      }
      self.state.watching.insert(pending.provider)
      if self.state.modes[pending.provider] == nil {
        self.state.modes[pending.provider] = .needsBaseline
      }
    }
    for pending in failed {
      guard self.state.roots[pending.provider] == pending.path,
        self.state.rootIdentities[pending.provider] == pending.identity,
        self.state.generation[pending.provider] == pending.generation
      else { continue }
      self.state.watching.remove(pending.provider)
      self.state.modes[pending.provider] = .full(.unwatched)
      self.bumpLocked(pending.provider)
    }
    self.lock.unlock()
    Self.release(abandoned)
  }

  func isWatching(_ provider: ProviderID) -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    if self.simulate { return self.state.watching.contains(provider) }
    return self.state.streams[provider] != nil
  }

  func noteUnavailable(_ provider: ProviderID) {
    self.lock.lock()
    self.state.modes[provider] = .full(.rootUnavailable)
    self.bumpLocked(provider)
    self.lock.unlock()
  }

  func invalidateAll(_ reason: LocalHistoryFullReason = .ambiguous) {
    self.lock.lock()
    for provider in self.state.roots.keys {
      self.becomeFullLocked(provider, reason)
    }
    self.lock.unlock()
  }

  /// Test and fixture entry. Production scans do not call this.
  func inject(
    provider: ProviderID,
    changed: [URL] = [],
    removed: [URL] = [],
    overflow: Bool = false,
    renamed: Bool = false,
    rootUnavailable: Bool = false
  ) {
    self.lock.lock()
    defer { self.lock.unlock() }
    if rootUnavailable {
      self.becomeFullLocked(provider, .rootUnavailable)
      return
    }
    if overflow {
      self.becomeFullLocked(provider, .overflow)
      return
    }
    if renamed {
      self.becomeFullLocked(provider, .renamed)
      return
    }
    self.addFilesLocked(
      provider: provider,
      changed: changed.map { $0.standardizedFileURL.path },
      removed: removed.map { $0.standardizedFileURL.path })
  }

  func plan(
    providers: [ProviderID],
    now: ContinuousClock.Instant,
    fullDiscoveryInterval: Duration
  ) -> [LocalHistoryVisitPlan] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return providers.map { provider in
      let token = self.state.generation[provider] ?? 0
      let visit: LocalHistoryVisit
      let mode = self.state.modes[provider] ?? .needsBaseline
      let periodicFullIsDue = self.state.baselined.contains(provider)
        && self.state.lastFull[provider].map { $0.duration(to: now) >= fullDiscoveryInterval } == true
      if periodicFullIsDue {
        visit = .full(.interval)
      } else {
        switch mode {
      case .needsBaseline:
        visit = .full(.baseline)
      case .full(let reason):
        visit = .full(reason)
      case .sparse(let changed, let removed):
        visit = .sparse(
          changed: changed.map { URL(fileURLWithPath: $0) },
          removed: removed.map { URL(fileURLWithPath: $0) })
      case .clean:
        if self.state.baselined.contains(provider) {
          visit = .skip
        } else {
          visit = .full(.baseline)
        }
      }
      }
      return LocalHistoryVisitPlan(provider: provider, visit: visit, token: token)
    }
  }

  /// Clears the dirty bit only when `token` is still current and a stream (or
  /// a simulated watch) is actually running. A failed watch stays dirty so the
  /// next scan keeps walking.
  func acknowledge(
    provider: ProviderID,
    token: Int,
    full: Bool,
    now: ContinuousClock.Instant
  ) {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard self.state.generation[provider] == token else { return }
    guard self.state.watching.contains(provider) else { return }
    if full { self.state.lastFull[provider] = now }
    self.state.modes[provider] = .clean
    self.state.baselined.insert(provider)
  }

  func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
    self.lock.lock()
    var streamsToRelease: [FSEventStreamRef] = []
    let count = min(paths.count, flags.count)
    let globalLoss = UInt32(
      kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped)
    let invalidatesRoot = UInt32(
      kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount
        | kFSEventStreamEventFlagRootChanged)
    if flags.prefix(count).contains(where: { $0 & globalLoss != 0 }) {
      for provider in self.state.roots.keys {
        self.becomeFullLocked(provider, .overflow)
      }
    }
    if flags.prefix(count).contains(where: { $0 & invalidatesRoot != 0 }) {
      for provider in self.state.roots.keys {
        if let stream = self.state.streams.removeValue(forKey: provider) {
          streamsToRelease.append(stream)
        }
        self.state.watching.remove(provider)
        self.state.rootIdentities.removeValue(forKey: provider)
        self.becomeFullLocked(provider, .rootUnavailable)
      }
    }
    var perProvider:
      [ProviderID: (changed: [String], removed: [String], full: LocalHistoryFullReason?)] = [:]
    for index in 0..<count {
      let flag = flags[index]
      if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0, flag & ~UInt32(kFSEventStreamEventFlagHistoryDone) == 0 {
        continue
      }
      let path = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
      guard let provider = self.providerLocked(for: path) else { continue }
      var slot = perProvider[provider] ?? ([], [], nil)
      if let reason = self.fullReason(flag) {
        slot.full = reason
      } else if self.isDirectory(flag) {
        if self.isStructuralDirectory(flag) { slot.full = .ambiguous }
      } else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
        slot.removed.append(path)
      } else {
        slot.changed.append(path)
      }
      perProvider[provider] = slot
    }
    for (provider, update) in perProvider {
      if let reason = update.full {
        self.becomeFullLocked(provider, reason)
        continue
      }
      guard !update.changed.isEmpty || !update.removed.isEmpty else { continue }
      self.addFilesLocked(provider: provider, changed: update.changed, removed: update.removed)
    }
    self.lock.unlock()
    if !streamsToRelease.isEmpty {
      let batch = StreamReleaseBatch(streamsToRelease)
      self.queue.async { Self.release(batch.streams) }
    }
  }

  private func makeStream(path: String) -> FSEventStreamRef? {
    let callbackContext = Unmanaged.passRetained(CallbackContext(owner: self))
    var context = FSEventStreamContext(
      version: 0,
      info: callbackContext.toOpaque(),
      retain: { pointer in
        guard let pointer else { return nil }
        _ = Unmanaged<CallbackContext>.fromOpaque(pointer).retain()
        return UnsafeRawPointer(pointer)
      },
      release: { pointer in
        guard let pointer else { return }
        Unmanaged<CallbackContext>.fromOpaque(pointer).release()
      },
      copyDescription: nil)
    let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
          | kFSEventStreamCreateFlagFileEvents)
    let stream = FSEventStreamCreate(
      nil,
      localHistoryEventCallback,
      &context,
      [path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.25,
      flags)
    callbackContext.release()
    guard let stream else { return nil }
    FSEventStreamSetDispatchQueue(stream, self.queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    return stream
  }

  private func stopStreams() {
    self.lock.lock()
    let streams = Array(self.state.streams.values)
    self.state.streams.removeAll()
    self.state.watching.removeAll()
    self.lock.unlock()
    Self.release(streams)
  }

  private static func release(_ streams: [FSEventStreamRef]) {
    for stream in streams {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }

  private func providerLocked(for path: String) -> ProviderID? {
    var match: (ProviderID, Int)?
    for (provider, root) in self.state.roots {
      if path == root || path.hasPrefix(root + "/") {
        if match == nil || root.count > match!.1 { match = (provider, root.count) }
      }
    }
    return match?.0
  }

  private func fullReason(_ flag: FSEventStreamEventFlags) -> LocalHistoryFullReason? {
    let dropped = UInt32(
      kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount
        | kFSEventStreamEventFlagRootChanged)
    if flag & dropped != 0 { return .overflow }
    if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { return .renamed }
    if flag & UInt32(kFSEventStreamEventFlagItemIsSymlink) != 0 { return .ambiguous }
    return nil
  }

  private func isDirectory(_ flag: FSEventStreamEventFlags) -> Bool {
    flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
      && flag & UInt32(kFSEventStreamEventFlagItemIsFile) == 0
  }

  private func isStructuralDirectory(_ flag: FSEventStreamEventFlags) -> Bool {
    let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved)
    return flag & structural != 0
  }

  private func becomeFullLocked(_ provider: ProviderID, _ reason: LocalHistoryFullReason) {
    self.state.modes[provider] = .full(reason)
    self.bumpLocked(provider)
  }

  private func addFilesLocked(provider: ProviderID, changed: [String], removed: [String]) {
    if case .full = self.state.modes[provider] {
      self.bumpLocked(provider)
      return
    }
    guard self.state.baselined.contains(provider) else {
      self.becomeFullLocked(provider, .baseline)
      return
    }
    var nextChanged: [String] = []
    var nextRemoved: [String] = []
    if case .sparse(let existingChanged, let existingRemoved) = self.state.modes[provider] {
      nextChanged = existingChanged
      nextRemoved = existingRemoved
    }
    for path in changed {
      nextRemoved.removeAll { $0 == path }
      if !nextChanged.contains(path) { nextChanged.append(path) }
    }
    for path in removed {
      nextChanged.removeAll { $0 == path }
      if !nextRemoved.contains(path) { nextRemoved.append(path) }
    }
    if nextChanged.count + nextRemoved.count > self.sparseCap {
      self.becomeFullLocked(provider, .ambiguous)
      return
    }
    self.state.modes[provider] = .sparse(changed: nextChanged, removed: nextRemoved)
    self.bumpLocked(provider)
  }

  private func bumpLocked(_ provider: ProviderID) {
    self.state.generation[provider, default: 0] += 1
  }

  private static func rootIdentity(_ path: String) -> RootIdentity? {
    var info = stat()
    guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return RootIdentity(
      device: UInt64(truncatingIfNeeded: info.st_dev),
      inode: UInt64(info.st_ino))
  }
}

private let localHistoryEventCallback: FSEventStreamCallback = {
  _, info, numEvents, eventPaths, eventFlags, _ in
  guard let info, numEvents > 0 else { return }
  let context = Unmanaged<LocalHistoryChangeTracker.CallbackContext>
    .fromOpaque(info).takeUnretainedValue()
  let names = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
  var paths: [String] = []
  paths.reserveCapacity(names.count)
  for name in names {
    if let path = name as? String { paths.append(path) }
  }
  context.owner?.handle(
    paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: numEvents)))
}
