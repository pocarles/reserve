import Darwin
import Foundation
import Testing
@testable import ReserveCore

/// The path is resolved once, by `open(2)`; type, owner, size and bytes all
/// come from that descriptor. These cases pin the refusals and prove a swap
/// after open cannot change what is read.
@Suite
struct DescriptorBoundReadTests {
  @Test
  func regularFileReadsFully() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("plain.json")
    try Data("hello".utf8).write(to: file)

    #expect(BoundedFileReader.read(file, maximumBytes: 5) == Data("hello".utf8))
    let opened = try #require(DescriptorBoundFile.open(file, maximumBytes: 5))
    defer { opened.close() }
    #expect(opened.metadata.size == 5)
    #expect(opened.readToEnd(maximumBytes: 5) == Data("hello".utf8))
  }

  @Test
  func openStampMatchesPathStampForUntouchedFile() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("stamp.jsonl")
    try Data("{}\n".utf8).write(to: file)

    let opened = try #require(DescriptorBoundFile.open(file))
    defer { opened.close() }
    #expect(try DescriptorBoundFile.linkMetadata(file) == opened.metadata)
  }

  @Test
  func symlinkToRegularFileIsRejected() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target.json")
    try Data("secret".utf8).write(to: target)
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(DescriptorBoundFile.open(link) == nil)
    #expect(BoundedFileReader.read(link, maximumBytes: 1_024) == nil)
  }

  @Test
  func fifoIsRejectedWithoutBlocking() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appendingPathComponent("pipe.jsonl")
    #expect(mkfifo(fifo.path, 0o600) == 0)

    // Run the open off-thread and give it ten seconds. A blocking FIFO open
    // never returns at all, so a generous bound still catches it while a busy
    // CI runner that is slow to schedule the thread does not fail the test. If
    // it ever blocks, fail and unblock it by opening the write end.
    let finished = DispatchSemaphore(value: 0)
    let outcome = OpenOutcome()
    DispatchQueue.global().async {
      outcome.set(
        helper: DescriptorBoundFile.open(fifo) == nil,
        reader: BoundedFileReader.read(fifo, maximumBytes: 1_024) == nil)
      finished.signal()
    }
    let started = Date()
    if finished.wait(timeout: .now() + 10) == .timedOut {
      Issue.record("Opening a FIFO blocked")
      let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
      if writer >= 0 { close(writer) }
      finished.wait()
    }
    #expect(Date().timeIntervalSince(started) < 10)
    #expect(outcome.helperRejected)
    #expect(outcome.readerRejected)
  }

  @Test
  func directoryIsRejected() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("folder.jsonl", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(DescriptorBoundFile.open(directory) == nil)
    #expect(BoundedFileReader.read(directory, maximumBytes: 1_024) == nil)
  }

  @Test
  func deviceIsRejected() {
    #expect(DescriptorBoundFile.open(URL(fileURLWithPath: "/dev/null"), expectedOwner: 0) == nil)
    #expect(BoundedFileReader.read(URL(fileURLWithPath: "/dev/zero"), maximumBytes: 16) == nil)
  }

  @Test
  func fileOwnedBySomeoneElseIsRejected() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("owned.json")
    try Data("{}".utf8).write(to: file)

    #expect(DescriptorBoundFile.open(file, expectedOwner: getuid() &+ 1) == nil)
    let opened = DescriptorBoundFile.open(file, expectedOwner: getuid())
    #expect(opened != nil)
    opened?.close()
  }

  @Test
  func oversizeFileIsRejected() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("large.json")
    try Data(repeating: 0x41, count: 11).write(to: file)

    #expect(DescriptorBoundFile.open(file, maximumBytes: 10) == nil)
    #expect(BoundedFileReader.read(file, maximumBytes: 10) == nil)
    #expect(BoundedFileReader.read(file, maximumBytes: 11)?.count == 11)
  }

  @Test
  func fileThatGrowsAfterOpenIsBounded() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("growing.json")
    try Data(repeating: 0x41, count: 5).write(to: file)

    let opened = try #require(DescriptorBoundFile.open(file, maximumBytes: 10))
    defer { opened.close() }
    let writer = try FileHandle(forWritingTo: file)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data(repeating: 0x42, count: 20))
    try writer.close()

    // fstat said 5 bytes, but 25 are there now: the budget is enforced on what
    // is actually read, not on the size seen at open.
    #expect(opened.metadata.size == 5)
    #expect(opened.readToEnd(maximumBytes: 10) == nil)
  }

  @Test
  func readFollowsTheOpenedDescriptorAfterThePathIsReplaced() throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("session.jsonl")
    try Data("original\n".utf8).write(to: path)
    let replacement = root.appendingPathComponent("replacement.jsonl")
    try Data("replacement content\n".utf8).write(to: replacement)

    let opened = try #require(DescriptorBoundFile.open(path))
    defer { opened.close() }
    #expect(rename(replacement.path, path.path) == 0)

    #expect(opened.metadata.size == 9)
    #expect(opened.readToEnd(maximumBytes: 1_024) == Data("original\n".utf8))
    // The path itself now names the other file; a fresh open sees that one.
    #expect(BoundedFileReader.read(path, maximumBytes: 1_024) == Data("replacement content\n".utf8))
  }

  @Test
  func scannerSkipsPlantedFifoAndSymlinkAndKeepsTheRest() async throws {
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex")
    let claude = root.appendingPathComponent("claude")
    let grok = root.appendingPathComponent("grok")
    let outside = root.appendingPathComponent("outside")
    for directory in [codex, claude, grok, outside] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    let healthy =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":30,"output_tokens":5}}}"#
    try Data((healthy + "\n").utf8).write(to: claude.appendingPathComponent("session.jsonl"))
    let foreign =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"r2","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":9000,"output_tokens":9000}}}"#
    let outsideFile = outside.appendingPathComponent("other.jsonl")
    try Data((foreign + "\n").utf8).write(to: outsideFile)
    try FileManager.default.createSymbolicLink(
      at: claude.appendingPathComponent("link.jsonl"), withDestinationURL: outsideFile)
    #expect(mkfifo(claude.appendingPathComponent("pipe.jsonl").path, 0o600) == 0)
    #expect(mkfifo(codex.appendingPathComponent("pipe.jsonl").path, 0o600) == 0)
    #expect(mkfifo(grok.appendingPathComponent("signals.json").path, 0o600) == 0)

    let scanner = LocalUsageScanner(
      roots: .init(codex: codex, claude: claude, grok: grok),
      cacheURL: root.appendingPathComponent("index.json"))
    let started = Date()
    let usage = try await scanner.scan(now: now)
    let repeated = try await scanner.scan(now: now)

    #expect(Date().timeIntervalSince(started) < 10)
    #expect(usage[.anthropic]?.totalTokens == 35)
    #expect(usage[.openAI]?.totalTokens == 0)
    #expect(repeated == usage)
  }

  private static func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("DescriptorBoundReadTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private final class OpenOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var helper = false
  private var reader = false

  func set(helper: Bool, reader: Bool) {
    self.lock.withLock {
      self.helper = helper
      self.reader = reader
    }
  }

  var helperRejected: Bool { self.lock.withLock { self.helper } }
  var readerRejected: Bool { self.lock.withLock { self.reader } }
}
