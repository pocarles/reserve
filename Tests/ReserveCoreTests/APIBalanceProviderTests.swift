import Foundation
import Testing
@testable import ReserveCore

/// DeepSeek and Moonshot report a remaining balance, not spend. These read that
/// balance from each provider's own host and keep it out of every spend field.
@Suite("API balance providers")
struct APIBalanceProviderTests {
  private static let now = Date(timeIntervalSince1970: 1_758_067_200)

  private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    func add(_ request: URLRequest) { self.lock.withLock { self.stored.append(request) } }
    var requests: [URLRequest] { self.lock.withLock { self.stored } }
  }

  private func client(
    status: Int = 200, _ body: String, recording sent: Sent = Sent()
  ) -> APIConsumptionClient {
    APIConsumptionClient(
      requestHandler: { request in
        sent.add(request)
        return (
          Data(body.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
      },
      now: { Self.now })
  }

  private func byLabel(_ snapshot: APIConsumptionSnapshot) -> [String: String] {
    Dictionary(uniqueKeysWithValues: snapshot.details.map { ($0.label, $0.value) })
  }

  // MARK: DeepSeek

  @Test func deepSeekReadsTheDocumentedBalanceFromItsOwnHost() async throws {
    let sent = Sent()
    let snapshot = try await self.client(
      #"""
      {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00",
      "granted_balance":"10.00","topped_up_balance":"100.00"}]}
      """#, recording: sent
    ).fetch(.deepSeek, apiKey: "sk-deepseek-test-key")

    let request = try #require(sent.requests.first)
    #expect(sent.requests.count == 1)
    #expect(request.url?.scheme == "https")
    #expect(request.url?.host == "api.deepseek.com")
    #expect(request.url?.path == "/user/balance")
    #expect(request.url?.query == nil)
    #expect(request.httpMethod == "GET" || request.httpMethod == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-deepseek-test-key")

    // A balance is not spend: it must not sit in a field formatted as spend.
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.primary == nil)
    #expect(snapshot.source == "DeepSeek Balance API")
    #expect(snapshot.note?.headline == "¥110")
    #expect(snapshot.note?.detail == "¥10.00 granted · ¥100 topped up")
    let details = self.byLabel(snapshot)
    #expect(details["Balance"] == "¥110")
    #expect(details["Granted"] == "¥10.00")
    #expect(details["Topped up"] == "¥100")
    #expect(details["Can make calls"] == "Yes")
    #expect(details["Other balance"] == nil)
  }

  @Test func deepSeekPrefersUSDAndNamesTheOtherCurrency() async throws {
    let snapshot = try await self.client(
      #"""
      {"is_available":true,"balance_infos":[
        {"currency":"CNY","total_balance":"72.50","granted_balance":"0.00","topped_up_balance":"72.50"},
        {"currency":"USD","total_balance":"12.34","granted_balance":"2.34","topped_up_balance":"10.00"}]}
      """#
    ).fetch(.deepSeek, apiKey: "sk-deepseek-test-key")
    #expect(snapshot.note?.headline == "$12.34")
    #expect(snapshot.note?.detail == "$2.34 granted · $10.00 topped up · also ¥72.50")
    #expect(self.byLabel(snapshot)["Other balance"] == "¥72.50")
  }

  /// Decimal strings are parsed as decimals: a value that has no exact binary
  /// form, and half a cent, both land on the right cent.
  @Test func deepSeekParsesDecimalStringsExactly() {
    #expect(APIConsumptionClient.minorUnits(fromDecimalAmount: "0.29") == 29)
    #expect(APIConsumptionClient.minorUnits(fromDecimalAmount: "1.005") == 101)
    #expect(APIConsumptionClient.minorUnits(fromDecimalAmount: " 110.00 ") == 11_000)
    #expect(APIConsumptionClient.minorUnits(fromDecimalAmount: "-3.50") == -350)
    #expect(APIConsumptionClient.minorUnits(fromDecimalAmount: "not a number") == 0)
    #expect(APIConsumptionClient.minorUnits(fromDecimalAmount: nil) == 0)
  }

  @Test func deepSeekSaysWhenTheBalanceCannotPayForCalls() async throws {
    let snapshot = try await self.client(
      #"""
      {"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00",
      "granted_balance":"0.00","topped_up_balance":"0.00"}]}
      """#
    ).fetch(.deepSeek, apiKey: "sk-deepseek-test-key")
    #expect(snapshot.note?.headline == "$0.00")
    #expect(snapshot.note?.detail?.hasPrefix("balance too low to make calls") == true)
    #expect(self.byLabel(snapshot)["Can make calls"] == "No, balance too low")
  }

  @Test func deepSeekWithoutABalanceIsNotAZeroReading() async {
    await #expect(throws: UsageProviderError.self) {
      _ = try await self.client(#"{"is_available":true,"balance_infos":[]}"#)
        .fetch(.deepSeek, apiKey: "sk-deepseek-test-key")
    }
  }

  // MARK: Moonshot

  @Test func moonshotReadsTheDocumentedBalanceFromTheInternationalHost() async throws {
    let sent = Sent()
    let snapshot = try await self.client(
      #"""
      {"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,
      "cash_balance":3.00001},"scode":"0x0","status":true}
      """#, recording: sent
    ).fetch(.moonshot, apiKey: "sk-moonshot-test-key")

    let request = try #require(sent.requests.first)
    #expect(sent.requests.count == 1)
    #expect(request.url?.scheme == "https")
    #expect(request.url?.host == "api.moonshot.ai")
    #expect(request.url?.path == "/v1/users/me/balance")
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-moonshot-test-key")

    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.primary == nil)
    #expect(snapshot.source == "Moonshot Balance API")
    #expect(snapshot.note?.headline == "$49.59")
    #expect(snapshot.note?.detail == "$46.59 voucher · $3.00 cash")
    let details = self.byLabel(snapshot)
    #expect(details["Balance"] == "$49.59")
    #expect(details["Vouchers"] == "$46.59")
    #expect(details["Cash"] == "$3.00")
    #expect(details["Can make calls"] == "Yes")
  }

  /// Cash can go negative, and at zero available balance Moonshot refuses calls.
  @Test func moonshotKeepsANegativeCashBalanceAndSaysCallsStop() async throws {
    let snapshot = try await self.client(
      #"""
      {"code":0,"data":{"available_balance":0,"voucher_balance":0,"cash_balance":-1.25},
      "scode":"0x0","status":true}
      """#
    ).fetch(.moonshot, apiKey: "sk-moonshot-test-key")
    #expect(snapshot.note?.headline == "$0.00")
    #expect(snapshot.note?.detail == "balance too low to make calls · $0.00 voucher · -$1.25 cash")
    #expect(self.byLabel(snapshot)["Cash"] == "-$1.25")
    #expect(self.byLabel(snapshot)["Can make calls"] == "No, balance too low")
  }

  @Test func moonshotFailureEnvelopeIsNotAZeroReading() async {
    await #expect(throws: UsageProviderError.self) {
      _ = try await self.client(#"{"code":1,"data":null,"scode":"0x1","status":false}"#)
        .fetch(.moonshot, apiKey: "sk-moonshot-test-key")
    }
  }

  // MARK: Shared

  @Test(arguments: [APIConsumptionProvider.deepSeek, .moonshot])
  func aRefusedKeyIsUnauthorized(_ provider: APIConsumptionProvider) async {
    do {
      _ = try await self.client(status: 401, #"{"error":{"message":"invalid key"}}"#)
        .fetch(provider, apiKey: "sk-rejected-test-key")
      Issue.record("a refused key was treated as a successful balance read")
    } catch let error as UsageProviderError {
      guard case .unauthorized(let message) = error else {
        Issue.record("expected unauthorized, got \(error)")
        return
      }
      #expect(message == "\(provider.displayName) refused this api key.")
      // The key never appears in what the app shows.
      #expect(!message.contains("sk-rejected-test-key"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func balanceProvidersUseHonestKeyCopy() {
    for provider in [APIConsumptionProvider.deepSeek, .moonshot] {
      #expect(provider.keyKind == "API key")
      #expect(provider.keyHint == "sk-…")
      #expect(provider.keySettingsURL.scheme == "https")
    }
    #expect(APIConsumptionProvider.deepSeek.keySettingsURL.host == "platform.deepseek.com")
    #expect(APIConsumptionProvider.moonshot.keySettingsURL.host == "platform.kimi.ai")
    #expect(APIConsumptionProvider.moonshot.displayName == "Moonshot")
  }

  @Test func balancesFormatInTheirOwnCurrency() {
    #expect(APIConsumptionClient.money(1_234, currency: "USD") == "$12.34")
    #expect(APIConsumptionClient.money(1_234, currency: "cny") == "¥12.34")
    #expect(APIConsumptionClient.money(-125, currency: "USD") == "-$1.25")
    #expect(APIConsumptionClient.money(50_000, currency: "EUR") == "EUR 500")
  }
}
