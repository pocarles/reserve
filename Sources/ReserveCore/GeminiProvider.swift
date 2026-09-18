import Foundation

/// Reads Google AI Pro, Ultra and free individual plan limits through the
/// Antigravity CLI (`agy`), which replaced Gemini CLI for those plans on
/// 2026-06-18.
///
/// Reserve only runs agy's own read-only usage command:
///
///     agy -p /usage --output-format json
///
/// Google's headless docs (antigravity.google/docs/cli/headless) document
/// `-p` and `--output-format json`; the agy 1.1.11 release notes add
/// print-mode answers for read-only slash commands "without starting an agent
/// turn, spending quota, or leaving a conversation behind". Reserve never reads
/// agy's Google token, never calls Google's quota endpoints itself and never
/// talks to agy's local language server.
///
/// The report shape follows what agy 1.2.x prints, as recorded by HarnessDesk
/// (PR #769, `packages/server/test/usage/agy-meter.test.ts`, agy 1.2.6),
/// CodexBar (`AntigravityQuotaSummaryParser.swift`,
/// `AntigravityCLIUsageReportTests.swift`) and google-antigravity/antigravity-cli
/// issue #1045: `command.data.groups[].buckets[]` with `window`,
/// `remaining_fraction` and `reset_time`. The camelCase names of Google's
/// underlying `retrieveUserQuotaSummary` response and of the community
/// `agy-cli-usage` snapshot (`remainingFraction`, `resetTime`/`resetAt`,
/// `resetsInSeconds`) are read too, in case a release switches spelling.
public struct GeminiProvider: UsageProvider {
  public let id: ProviderID = .gemini
  public static let executable = "agy"
  static let usageArguments = ["-p", "/usage", "--output-format", "json"]
  /// Before 1.1.11 print mode could send `/usage` to the model as a prompt and
  /// spend quota, so Reserve never asks an older or unidentified agy.
  static let minimumVersion = SemanticVersion(1, 1, 11)
  /// Each agy run writes a ~20 KB log. `--log-file` was measured on 1.2.5 and
  /// 1.2.6 (HarnessDesk PR #769); it is not passed to releases where it is
  /// unconfirmed, because an unknown flag would fail every check.
  static let logFileFlagVersion = SemanticVersion(1, 2, 5)
  static let usageTimeout: Duration = .seconds(30)
  static let versionTimeout: Duration = .seconds(5)
  static let maximumOutputBytes = 65_536
  static let maximumErrorBytes = 8_192
  static let updateMessage = "Update Antigravity CLI to 1.1.11 or later to show Gemini usage."
  static let signInMessage = "Sign in to Antigravity CLI: run agy in Terminal and sign in with Google."

  typealias Runner = @Sendable (
    _ executable: String, _ arguments: [String], _ environment: [String: String], _ timeout: Duration
  ) async throws -> ProcessRunner.Result

  private let environment: [String: String]
  private let locator: @Sendable ([String: String]) -> String?
  private let runner: Runner
  private let now: @Sendable () -> Date

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.init(environment: environment, locator: nil, runner: nil)
  }

  /// The lookup, process and clock hooks exist so tests never launch agy.
  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    locator: (@Sendable ([String: String]) -> String?)?,
    runner: Runner?,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.environment = environment
    self.locator = locator ?? { BinaryLocator.find(Self.executable, environment: $0) }
    self.runner = runner ?? Self.runInPrivateDirectory
    self.now = now
  }

  public func fetch() async throws -> UsageSnapshot {
    guard let executable = self.locator(self.environment) else {
      throw UsageProviderError.executableNotFound("Antigravity CLI")
    }
    let environment = Self.childEnvironment(self.environment)
    let versionOutput = try await self.run(
      executable, ["--version"], environment, Self.versionTimeout)
    let version = try Self.version(from: versionOutput)
    var arguments = Self.usageArguments
    if version >= Self.logFileFlagVersion { arguments += ["--log-file", "/dev/null"] }
    let output = try await self.run(executable, arguments, environment, Self.usageTimeout)
    return try Self.interpret(output, now: self.now())
  }

  private func run(
    _ executable: String, _ arguments: [String], _ environment: [String: String], _ timeout: Duration
  ) async throws -> ProcessRunner.Result {
    do {
      let output = try await self.runner(executable, arguments, environment, timeout)
      try Task.checkCancellation()
      return output
    } catch UsageProviderError.timedOut {
      throw UsageProviderError.timedOut("Antigravity CLI usage check")
    }
  }

  /// Reserve runs agy on its own initiative, so it gets an allowlisted
  /// environment: no unrelated API keys (including a `GEMINI_API_KEY` that
  /// would switch agy away from the Google sign-in whose plan limits are wanted).
  /// Auto-update is off because a background usage check must not replace the
  /// person's installed CLI; agy reads the word `true`, not `1` (HarnessDesk
  /// PR #769, measured on 1.2.6).
  static func childEnvironment(_ environment: [String: String]) -> [String: String] {
    var result = BinaryLocator.minimalChildEnvironment(from: environment)
    result["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
    result["NO_COLOR"] = "1"
    return result
  }

  /// No TTY and no stdin, so agy can never wait on a prompt, and a private
  /// empty working directory, so it has no workspace to index.
  private static let runInPrivateDirectory: Runner = { executable, arguments, environment, timeout in
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("reserve-agy-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? fileManager.removeItem(at: directory) }
    return try await ProcessRunner.run(
      executable: executable, arguments: arguments, environment: environment,
      standardInput: FileHandle.nullDevice, currentDirectory: directory, timeout: timeout,
      maximumStdoutBytes: Self.maximumOutputBytes, maximumStderrBytes: Self.maximumErrorBytes)
  }

  static func version(from output: ProcessRunner.Result) throws -> SemanticVersion {
    let text = String(decoding: output.stdout.prefix(1_024), as: UTF8.self)
    guard output.status == 0, let version = SemanticVersion.first(in: text) else {
      throw UsageProviderError.unavailable(
        "Reserve could not confirm the Antigravity CLI version, so it did not ask for usage.")
    }
    guard version >= Self.minimumVersion else {
      throw UsageProviderError.updateRequired(Self.updateMessage)
    }
    return version
  }

  // MARK: Interpreting a run

  /// agy's own words for a missing or lapsed sign-in. Google's headless docs
  /// promise an `authentication required` error; the other phrases are the
  /// CLI's for a lapsed session (HarnessDesk PR #769) and the 1.2.4 scope
  /// error, which asks for `/logout` and `/login`. A message that merely
  /// mentions authentication (a timeout, a 503) is not treated as signed out.
  static func signInError(in text: String) -> UsageProviderError? {
    let lowered = text.lowercased()
    if lowered.contains("stored credentials are expired or revoked")
      || (lowered.contains("/logout") && lowered.contains("/login"))
    {
      return .unauthorized(Self.signInMessage)
    }
    let signedOut = [
      "authentication required", "not logged into antigravity", "you are not logged in",
      "not signed in", "you are currently not signed in",
    ]
    return signedOut.contains(where: lowered.contains) ? .credentialsNotFound(Self.signInMessage) : nil
  }

  static func interpret(_ output: ProcessRunner.Result, now: Date = Date()) throws -> UsageSnapshot {
    let stdout = String(decoding: output.stdout, as: UTF8.self)
    let stderr = String(decoding: output.stderr, as: UTF8.self)
    let report = Self.reportData(in: stdout)
    let reportError = report.flatMap(Self.reportErrorText) ?? ""
    // The telling line is on stderr, not in the JSON, so both are read. The
    // text is matched only; it is never shown or logged, since it can name
    // the account.
    if let error = Self.signInError(in: [reportError, stderr, report == nil ? stdout : ""]
      .joined(separator: "\n"))
    {
      throw error
    }
    guard !output.stdoutExceeded else {
      throw UsageProviderError.invalidResponse("Antigravity CLI output exceeded its size limit.")
    }
    guard let report else {
      if output.status != 0 {
        throw UsageProviderError.processFailed("Antigravity CLI exited with status \(output.status).")
      }
      throw UsageProviderError.invalidResponse("Antigravity CLI usage report was not recognized.")
    }
    return try Self.decode(report, now: now, exitStatus: output.status)
  }

  /// agy prints one JSON object. Anything before its first brace (an update
  /// notice, a banner) is ignored, as HarnessDesk does.
  static func reportData(in stdout: String) -> Data? {
    guard let start = stdout.firstIndex(of: "{") else { return nil }
    let data = Data(stdout[start...].utf8)
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
    return data
  }

  private static func reportErrorText(_ data: Data) -> String? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return root["error"] as? String
  }

  // MARK: Decoding

  static let fiveHourMinutes = 5 * 60
  static let dailyMinutes = 24 * 60
  static let weeklyMinutes = 7 * 24 * 60

  static func decode(_ data: Data, now: Date = Date(), exitStatus: Int32 = 0) throws -> UsageSnapshot {
    guard data.count <= Self.maximumOutputBytes,
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw Self.unrecognized }

    let summary: [String: Any]
    if let command = root["command"] {
      // Native print mode: {status, error, command: {name, data}}.
      guard let command = command as? [String: Any],
        Self.optionalString(command["name"]).map({ $0 == "usage" }) ?? true,
        let data = command["data"] as? [String: Any]
      else { throw Self.unrecognized }
      summary = data
    } else if root["groups"] != nil || root["buckets"] != nil {
      // The quota summary itself, or the community snapshot of it.
      summary = root
    } else if let status = root["status"] as? String, status != "SUCCESS" {
      throw UsageProviderError.unavailable("Antigravity CLI could not read your Gemini usage. Try again shortly.")
    } else {
      throw Self.unrecognized
    }
    if let status = root["status"] {
      // Do not echo agy's own error text: it can name the account.
      guard let status = status as? String else { throw Self.unrecognized }
      guard status == "SUCCESS" else {
        throw UsageProviderError.unavailable("Antigravity CLI could not read your Gemini usage. Try again shortly.")
      }
    } else if exitStatus != 0 {
      throw UsageProviderError.processFailed("Antigravity CLI exited with status \(exitStatus).")
    }

    let topBuckets = try Self.array(summary["buckets"])
    let groups = try Self.array(summary["groups"])
    guard topBuckets.count + groups.count <= UsageSnapshot.maximumWindows else { throw Self.unrecognized }

    var windows: [UsageWindow] = []
    var ids: Set<String> = []
    var details: [UsageDetail] = []
    func add(_ window: UsageWindow?) {
      guard let window, windows.count < UsageSnapshot.maximumWindows,
        ids.insert(window.id).inserted
      else { return }
      windows.append(window)
    }

    for (index, value) in topBuckets.enumerated() {
      guard let bucket = value as? [String: Any] else { throw Self.unrecognized }
      add(try Self.window(bucket, group: nil, index: index, now: now))
    }
    // The Gemini group leads with plain "Weekly" and "5 hours" labels: this
    // card is Gemini, and those are the limits a Gemini plan is known by.
    // Other groups (Claude and GPT) are labelled like Claude's model-scoped
    // limits, so they never stand in for the plan's own limit unless they
    // are the one running out. Account-wide buckets, if agy ever reports any,
    // take the plain labels instead.
    var parsedGroups: [(name: String, buckets: [[String: Any]])] = []
    for value in groups {
      guard let group = value as? [String: Any] else { throw Self.unrecognized }
      let name = try Self.string(group, ["name", "displayName", "display_name"]) ?? "Models"
      let buckets = try Self.array(group["buckets"]).map { value -> [String: Any] in
        guard let bucket = value as? [String: Any] else { throw Self.unrecognized }
        return bucket
      }
      parsedGroups.append((name, buckets))
      if let models = try Self.string(group, ["models", "description"]) {
        let list = models.replacingOccurrences(
          of: #"^\s*Models within this group:\s*"#, with: "", options: .regularExpression)
        if !list.isEmpty, list != models || group["models"] != nil {
          details.append(UsageDetail(name, list))
        }
      }
    }
    let homeIndex = topBuckets.isEmpty
      ? parsedGroups.firstIndex { $0.name.lowercased().hasPrefix("gemini") } : nil
    let ordered = parsedGroups.indices.sorted { lhs, rhs in
      if lhs == homeIndex { return rhs != homeIndex }
      if rhs == homeIndex { return false }
      return lhs < rhs
    }
    for groupIndex in ordered {
      let group = parsedGroups[groupIndex]
      for (index, bucket) in group.buckets.enumerated() {
        add(try Self.window(
          bucket, group: groupIndex == homeIndex ? nil : group.name, index: index, now: now,
          groupSlug: Self.slug(group.name)))
      }
    }
    guard !windows.isEmpty else {
      throw UsageProviderError.unavailable("Antigravity CLI reported no Gemini plan limits for this sign-in.")
    }

    let plan = try Self.string(root, ["tier", "plan"]) ?? Self.string(summary, ["tier", "plan"])
    if let account = try Self.string(root, ["account", "email"]) {
      details.insert(UsageDetail("Account", account, isPersonal: true), at: 0)
    }
    return UsageSnapshot(
      provider: .gemini, planName: plan, windows: windows, fetchedAt: now,
      source: "Antigravity CLI usage report", detailedUsageUnavailable: true, details: details)
  }

  private enum Period {
    case fiveHour, daily, weekly
    case other(String)

    var minutes: Int? {
      switch self {
      case .fiveHour: GeminiProvider.fiveHourMinutes
      case .daily: GeminiProvider.dailyMinutes
      case .weekly: GeminiProvider.weeklyMinutes
      case .other: nil
      }
    }

    var slug: String {
      switch self {
      case .fiveHour: "5h"
      case .daily: "daily"
      case .weekly: "weekly"
      case .other(let name): GeminiProvider.slug(name)
      }
    }
  }

  private static func period(window: String?, name: String?) -> Period? {
    let raw = (window ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    switch raw {
    case "weekly", "week", "7d", "seven_day", "seven-day": return .weekly
    case "5h", "five_hour", "five-hour", "5-hour", "fivehour", "5_hour": return .fiveHour
    case "daily", "day", "24h": return .daily
    default: break
    }
    let label = (name ?? "").lowercased()
    if label.contains("week") { return .weekly }
    if label.range(of: #"(5|five)[\s_-]?hour"#, options: .regularExpression) != nil { return .fiveHour }
    if label.contains("daily") { return .daily }
    if !raw.isEmpty { return .other(raw) }
    if !label.isEmpty { return .other(name!) }
    return nil
  }

  private static func window(
    _ bucket: [String: Any], group: String?, index: Int, now: Date, groupSlug: String = "account"
  ) throws -> UsageWindow? {
    // A bucket Google marks disabled is not a limit this account runs into.
    if let disabled = bucket["disabled"] {
      guard let flag = disabled as? Bool else { throw Self.unrecognized }
      if flag { return nil }
    }
    let name = try Self.string(bucket, ["name", "displayName", "display_name", "label"])
    let windowName = try Self.string(bucket, ["window", "kind"])
    guard let period = Self.period(window: windowName, name: name) else { throw Self.unrecognized }
    // Without a remaining fraction there is nothing to draw: never assume a
    // full or empty allowance. `remaining_amount` is a count with no total.
    guard let remaining = try Self.remainingFraction(bucket) else { return nil }
    // Float noise at the edges is clamped; anything clearly outside 0–1 is
    // not a fraction, so the whole report is refused rather than guessed at.
    guard remaining.isFinite, remaining >= -0.001, remaining <= 1.001 else {
      throw UsageProviderError.invalidResponse("Antigravity CLI returned an invalid remaining allowance.")
    }
    let fraction = min(1, max(0, remaining))

    var reset: Date?
    if let text = try Self.string(bucket, ["reset_time", "resetTime", "reset_at", "resetAt"]) {
      reset = UsageDateParser.iso8601(text)
    } else if let seconds = try Self.number(bucket, ["resets_in_seconds", "resetsInSeconds"]),
      seconds.isFinite, seconds >= 0, seconds <= Double(UsageWindow.maximumWindowMinutes) * 60
    {
      reset = now.addingTimeInterval(seconds)
    }
    // An untouched window has not started: Google answers "now plus a week"
    // and moves it on every read (HarnessDesk, three reads, three dates). A
    // full bucket therefore has no reset to count down to, and no pace.
    if fraction >= 1 || (reset.map { $0 <= now } ?? false) { reset = nil }

    let id = try Self.string(bucket, ["id", "bucketId", "bucket_id"])
      ?? "\(groupSlug)-\(period.slug)-\(index)"
    return UsageWindow(
      id: id, label: Self.label(period: period, name: name, group: group),
      usedPercent: (1 - fraction) * 100, windowMinutes: period.minutes, resetsAt: reset)
  }

  private static func label(period: Period, name: String?, group: String?) -> String {
    let own: String =
      switch period {
      case .weekly: "Weekly"
      case .fiveHour: "5 hours"
      case .daily: "Daily"
      case .other(let raw): (name ?? raw).capitalized
      }
    guard let group else { return own }
    let short = group.replacingOccurrences(
      of: #"\s+models\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
    let scope = short.isEmpty ? group : short
    if case .weekly = period { return "\(scope) weekly" }
    return "\(scope) · \(own)"
  }

  private static func remainingFraction(_ bucket: [String: Any]) throws -> Double? {
    if let value = try Self.number(bucket, ["remaining_fraction", "remainingFraction"]) { return value }
    // Google's proto JSON can wrap it: {"remaining": {"remainingFraction": x}}.
    guard let remaining = bucket["remaining"] else { return nil }
    guard let object = remaining as? [String: Any] else { throw Self.unrecognized }
    return try Self.number(object, ["remaining_fraction", "remainingFraction"])
  }

  private static let unrecognized = UsageProviderError.invalidResponse(
    "Antigravity CLI usage report was not recognized.")

  private static func array(_ value: Any?) throws -> [Any] {
    guard let value, !(value is NSNull) else { return [] }
    guard let array = value as? [Any] else { throw Self.unrecognized }
    return array
  }

  private static func optionalString(_ value: Any?) -> String? {
    value as? String
  }

  /// The first present key wins. A present key of the wrong type means the
  /// shape is not the one Reserve knows, so it fails instead of guessing.
  private static func string(_ object: [String: Any], _ keys: [String]) throws -> String? {
    for key in keys {
      guard let value = object[key], !(value is NSNull) else { continue }
      guard let text = value as? String else { throw Self.unrecognized }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  private static func number(_ object: [String: Any], _ keys: [String]) throws -> Double? {
    for key in keys {
      guard let value = object[key], !(value is NSNull) else { continue }
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw Self.unrecognized
      }
      return number.doubleValue
    }
    return nil
  }

  static func slug(_ value: String) -> String {
    let slug = value.lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "group" : slug
  }
}
