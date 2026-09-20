import Carbon.HIToolbox
import Foundation

/// A persisted global shortcut that opens the Reserve dashboard.
///
/// Off is a real choice. The other choices are a small fixed set so Reserve
/// never records an arbitrary key combination or intercepts every keystroke.
public enum DashboardHotKeyChoice: String, Codable, CaseIterable, Sendable {
  case off
  case commandShiftR
  case commandOptionR
  case controlOptionR
  case commandShiftU
  case commandOptionU

  public var title: String {
    switch self {
    case .off: "Off"
    case .commandShiftR: "⌘⇧R"
    case .commandOptionR: "⌘⌥R"
    case .controlOptionR: "⌃⌥R"
    case .commandShiftU: "⌘⇧U"
    case .commandOptionU: "⌘⌥U"
    }
  }

  /// Carbon modifiers for `RegisterEventHotKey`. Nil when the shortcut is off.
  public var carbonModifiers: UInt32? {
    switch self {
    case .off: nil
    case .commandShiftR: UInt32(cmdKey | shiftKey)
    case .commandOptionR: UInt32(cmdKey | optionKey)
    case .controlOptionR: UInt32(controlKey | optionKey)
    case .commandShiftU: UInt32(cmdKey | shiftKey)
    case .commandOptionU: UInt32(cmdKey | optionKey)
    }
  }

  /// Carbon virtual key code. Nil when the shortcut is off.
  public var carbonKeyCode: UInt32? {
    switch self {
    case .off: nil
    case .commandShiftR, .commandOptionR, .controlOptionR: UInt32(kVK_ANSI_R)
    case .commandShiftU, .commandOptionU: UInt32(kVK_ANSI_U)
    }
  }

  public static func persisted(_ raw: String?) -> DashboardHotKeyChoice {
    guard let raw, let choice = DashboardHotKeyChoice(rawValue: raw) else { return .off }
    return choice
  }
}

/// What registration may say. A conflict is only `eventHotKeyExistsErr`.
/// Other OSStatus values stay distinct so a bug is not reported as "already used".
public enum DashboardHotKeyRegistration: Equatable, Sendable {
  case inactive
  case registered
  case conflict
  case failed(Int32)

  public var statusText: String {
    switch self {
    case .inactive: "Off"
    case .registered: "Registered"
    case .conflict: "Already used by another app"
    case .failed: "Could not register"
    }
  }

  public static func from(status: OSStatus) -> DashboardHotKeyRegistration {
    if status == noErr { return .registered }
    // Carbon.h: eventHotKeyExistsErr = -9878. Another registration owns it.
    if status == -9878 { return .conflict }
    return .failed(status)
  }
}

/// Testable mapping from a persisted choice to the Carbon arguments Reserve
/// would register. Off produces no registration.
public enum DashboardHotKeyMapping {
  public static func carbonArguments(
    for choice: DashboardHotKeyChoice
  ) -> (keyCode: UInt32, modifiers: UInt32)? {
    guard let keyCode = choice.carbonKeyCode, let modifiers = choice.carbonModifiers else {
      return nil
    }
    return (keyCode, modifiers)
  }
}
