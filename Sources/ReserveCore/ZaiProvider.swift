import Foundation

/// Reads the GLM Coding Plan limits of a Z.ai account with a pasted API key.
///
/// The endpoint is unofficial: it is the one Z.ai's own subscription page uses
/// and it is undocumented, so its shape may change. Reserve reads it the way
/// these open-source clients do (checked September 2026):
/// - CodexBar `Sources/CodexBarCore/Resources/Plugins/zai.js` and `docs/zai.md`
///   (limit types, unit codes, percentage/count precedence, 5-hour reset guard)
/// - guyinwonder168/opencode-glm-quota `src/api/client.ts` (raw-key header)
/// - robinebers/openusage `docs/providers/zai.md` (key and plan pages)
///
/// Only the international host `api.z.ai` is supported. China-mainland keys
/// belong to `open.bigmodel.cn`, which is a separate account system; those
/// keys are not sent anywhere else.
public struct ZaiProvider: UsageProvider {
  public let id: ProviderID = .zai
  public static let endpointHost = "api.z.ai"
  static let quotaPath = "/api/monitor/usage/quota/limit"

  private let loadKey: @Sendable () throws -> String
  private let transport: APIKeyPlanTransport
  private let now: @Sendable () -> Date

  /// Reads the key from Reserve's Keychain item at fetch time; nothing is retained.
  public init(session: URLSession? = nil) {
    self.loadKey = { try PlanKeyKeychain.load(for: .zai) }
    self.transport = APIKeyPlanTransport(provider: .zai, host: Self.endpointHost, session: session)
    self.now = Date.init
  }

  init(
    apiKey: String,
    requestHandler: @escaping APIKeyPlanTransport.RequestHandler,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.loadKey = { apiKey }
    self.transport = APIKeyPlanTransport(
      provider: .zai, host: Self.endpointHost, requestHandler: requestHandler)
    self.now = now
  }

  public func fetch() async throws -> UsageSnapshot {
    let key = try PlanKeyKeychain.normalized(try self.loadKey(), for: .zai)
    // Z.ai's own coding-plan tooling sends the key without a scheme. The
    // server also accepts "Bearer <key>" (CodexBar uses that form); the raw
    // form is kept because it is what Z.ai's clients send.
    let data = try await self.transport.get(path: Self.quotaPath, authorization: key)
    return try Self.decode(data, now: self.now())
  }

  // MARK: Decoding

  /// Z.ai's unit codes, as minutes per unit. 5 is used both for minutes and,
  /// on the tool quota, as a monthly marker, so it is read only on plan limits.
  private static let minutesPerUnit: [Int: Int] = [1: 24 * 60, 3: 60, 5: 1, 6: 7 * 24 * 60]

  static func decode(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
    guard data.count <= APIKeyPlanTransport.maximumResponseBytes,
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw UsageProviderError.invalidResponse("Z.ai usage data was not recognized.") }

    // Z.ai reports failures inside an HTTP 200 body. A rejected key comes back
    // as code 401 ("token expired or incorrect") or 1000–1004 (missing or
    // invalid authentication), verified against the live endpoint.
    let code = APIKeyPlanTransport.integer(root["code"])
    guard root["success"] as? Bool == true, code == 200 else {
      switch code {
      case 401, 1000, 1001, 1002, 1003, 1004:
        throw UsageProviderError.unauthorized(
          "Z.ai did not accept this API key. Replace it in Settings > Providers.")
      case 429, 1302, 1303:
        throw UsageProviderError.rateLimited(retryAt: nil)
      default:
        // The message is not echoed; it is free text Reserve cannot vouch for.
        throw UsageProviderError.invalidResponse("Z.ai could not report usage for this key.")
      }
    }
    guard let payload = root["data"] as? [String: Any],
      let rawLimits = payload["limits"] as? [Any], rawLimits.count <= 64
    else { throw UsageProviderError.invalidResponse("Z.ai usage data was not recognized.") }

    var planWindows: [(window: UsageWindow, counts: (used: Double, limit: Double)?, kind: String)] = []
    var details: [UsageDetail] = []
    for raw in rawLimits {
      guard let limit = raw as? [String: Any],
        let type = limit["type"] as? String,
        let unit = APIKeyPlanTransport.integer(limit["unit"]),
        let number = APIKeyPlanTransport.integer(limit["number"]),
        let percentage = APIKeyPlanTransport.number(limit["percentage"])
      else { throw UsageProviderError.invalidResponse("Z.ai returned a limit Reserve could not read.") }

      let total = APIKeyPlanTransport.number(limit["usage"])
      let current = APIKeyPlanTransport.number(limit["currentValue"])
      let remaining = APIKeyPlanTransport.number(limit["remaining"])
      // Counts are more precise than the rounded percentage when both exist.
      var used: Double?
      if let total, total > 0 {
        if let current, current >= 0 { used = current }
        else if let remaining, (0...total).contains(remaining) { used = total - remaining }
      }
      let usedPercent = used.flatMap { value in total.map { value / $0 * 100 } } ?? percentage
      guard usedPercent.isFinite, usedPercent >= 0 else {
        throw UsageProviderError.invalidResponse("Z.ai returned an invalid limit.")
      }

      switch type {
      case "TOKENS_LIMIT", "CREDIT_LIMIT":
        // An unfamiliar unit code keeps the reading but claims no window
        // length, so no pace is derived from a guessed period.
        let minutes: Int? = Self.minutesPerUnit[unit].flatMap { perUnit in
          guard number > 0 else { return nil }
          let (value, overflow) = number.multipliedReportingOverflow(by: perUnit)
          return overflow ? nil : value
        }
        var reset = APIKeyPlanTransport.number(limit["nextResetTime"])
          .map { Date(timeIntervalSince1970: $0 / 1_000) }
        // A five-hour window cannot reset more than five hours away. Some
        // responses have carried a shifted time zone; drop the reset rather
        // than guess a correction, and keep the reading.
        if let value = reset, minutes == 5 * 60,
          value.timeIntervalSince(now) > 5 * 60 * 60 + 60
        { reset = nil }
        if let value = reset, value <= now { reset = nil }
        planWindows.append((
          UsageWindow(
            id: "\(type.lowercased())-\(minutes.map(String.init) ?? "unit\(unit)x\(number)")",
            label: minutes.map(Self.label(minutes:)) ?? "Coding limit",
            usedPercent: usedPercent, windowMinutes: minutes, resetsAt: reset),
          used.flatMap { value in total.map { (value, $0) } },
          type))
      case "TIME_LIMIT":
        // The web search / reader / Zread tool quota is a separate monthly
        // count, not the coding allowance, so it is a detail, not a meter.
        if let used, let total {
          details.append(UsageDetail(
            "Tool calls",
            "\(UsageDetailFormat.number(used)) of \(UsageDetailFormat.number(total)) this month"))
        } else {
          details.append(UsageDetail("Tool calls", "\(UsageDetailFormat.number(usedPercent))% used this month"))
        }
      default:
        continue  // Unknown future limit kinds are skipped, never shown as 0%.
      }
    }

    guard !planWindows.isEmpty else {
      // A valid key without a GLM Coding Plan has nothing to meter.
      throw UsageProviderError.unavailable("Z.ai reported no GLM Coding Plan limits for this key.")
    }
    planWindows.sort { ($0.window.windowMinutes ?? .max) < ($1.window.windowMinutes ?? .max) }
    var seen: Set<String> = []
    let windows = planWindows.map(\.window).filter { seen.insert($0.id).inserted }
    for entry in planWindows {
      guard let counts = entry.counts else { continue }
      let noun = entry.kind == "CREDIT_LIMIT" ? "credits" : "tokens"
      details.append(UsageDetail(
        "\(AllowanceLabel.detail(minutes: entry.window.windowMinutes)) \(noun)",
        "\(UsageDetailFormat.number(counts.used)) of \(UsageDetailFormat.number(counts.limit)) used"))
    }

    let planKeys = ["planName", "plan", "plan_type", "packageName", "level"]
    let plan = planKeys.lazy.compactMap { (payload[$0] as? String)?.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
    return UsageSnapshot(
      provider: .zai, planName: plan.map(Self.planName), windows: windows, fetchedAt: now,
      source: "Z.ai quota API (unofficial)", detailedUsageUnavailable: true,
      details: details)
  }

  /// "lite" → "GLM Coding Lite"; a name that already says more is kept.
  static func planName(_ raw: String) -> String {
    let name = raw.count <= 12 && raw == raw.lowercased() ? raw.capitalized : raw
    return name.localizedCaseInsensitiveContains("GLM") ? name : "GLM Coding \(name)"
  }

  static func label(minutes: Int) -> String { AllowanceLabel.window(minutes: minutes) }
}

/// Window names shared by the API-key plans, matching the labels the rest of
/// Reserve already titles ("5 hours" → "5-hour window", "Weekly" → "Weekly limit").
enum AllowanceLabel {
  static func window(minutes: Int) -> String {
    switch minutes {
    case 5 * 60: "5 hours"
    case 7 * 24 * 60: "Weekly"
    case 24 * 60: "Daily"
    default:
      if minutes % (24 * 60) == 0 { "\(minutes / (24 * 60)) days" }
      else if minutes % 60 == 0 { "\(minutes / 60) hours" }
      else { "\(minutes) minutes" }
    }
  }

  static func detail(minutes: Int?) -> String {
    switch minutes {
    case 5 * 60: "5-hour"
    case 7 * 24 * 60: "Weekly"
    case .some(let value): Self.window(minutes: value)
    case nil: "Plan"
    }
  }
}
