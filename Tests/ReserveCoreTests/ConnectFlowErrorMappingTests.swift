import Foundation
import Testing
@testable import ReserveCore

/// Errors that decide which action the Connect window offers. A signed-out
/// helper must lead to sign-in, and a problem only a Reserve update can fix
/// must not ask the person to update the provider's helper.
@Suite struct ConnectFlowErrorMappingTests {
  @Test func codexSignedOutMessagesAskForSignIn() {
    for message in [
      "codex account authentication required to read rate limits",
      "Authentication required",
      "You are not signed in",
      "not logged in to ChatGPT",
      "Login required",
    ] {
      #expect(OpenAIProvider.signInError(in: message)
        == .credentialsNotFound(OpenAIProvider.signInMessage), "\(message)")
    }
    #expect(OpenAIProvider.signInError(in: "account/rateLimits/read timed out") == nil)
    #expect(OpenAIProvider.signInError(in: "authentication service unavailable") == nil)
  }

  /// The real request path: the helper answers the limit read with a JSON-RPC
  /// error, which `JSONRPCProcess` reports as a process failure.
  @Test func codexRateLimitReadMapsSignedOutErrorToCredentials() async throws {
    let script = #"read line; printf '{"id":1,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}\n'; sleep 2"#
    let rpc = try JSONRPCProcess(
      executable: "/bin/sh", arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment)
    defer { rpc.shutdown() }
    do {
      _ = try await OpenAIProvider.readRateLimits(using: rpc)
      Issue.record("a signed-out Codex returned rate limits")
    } catch let error as UsageProviderError {
      #expect(error == .credentialsNotFound(OpenAIProvider.signInMessage))
      #expect(error.requiresConnection)
    }
  }

  @Test func codexOtherRPCFailuresStayProcessFailures() async throws {
    let script = #"read line; printf '{"id":1,"error":{"message":"internal error"}}\n'; sleep 2"#
    let rpc = try JSONRPCProcess(
      executable: "/bin/sh", arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment)
    defer { rpc.shutdown() }
    do {
      _ = try await OpenAIProvider.readRateLimits(using: rpc)
      Issue.record("a failed limit read returned rate limits")
    } catch let error as UsageProviderError {
      #expect(error == .processFailed("internal error"))
      #expect(!error.requiresConnection)
    }
  }

  @Test func copilotProtocolVersionPicksTheRemedyThatWorks() {
    #expect(CopilotQuotaProcess.unsupportedProtocolError(NSNumber(value: 4))
      == .unavailable(CopilotProvider.newerThanSupportedMessage))
    for older: Any? in [NSNumber(value: 2), nil, "3", NSNumber(value: true)] {
      guard case .updateRequired = CopilotQuotaProcess.unsupportedProtocolError(older) else {
        Issue.record("an older or unreadable Copilot protocol did not ask for a Copilot update")
        continue
      }
    }
  }
}
