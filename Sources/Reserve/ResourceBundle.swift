import Foundation

/// Resources SwiftPM copies next to the binary: the provider marks.
///
/// SwiftPM's generated `Bundle.module` only looks beside `Bundle.main` and in
/// the build directory that produced the binary, and it calls `fatalError`
/// when neither exists. The packaged app keeps the resource bundle in
/// `Contents/Resources`, the build directory is a temporary path that
/// packaging deletes, and a running copy can outlive its deleted app bundle.
/// Every lookup goes through this accessor instead, which returns nil rather
/// than trapping; callers already fall back (provider initials for marks).
/// Nothing on the sign-in path depends on it: the Claude browser shim is
/// written at runtime by `ClaudeLoginBrowserPipe`.
extension Bundle {
  nonisolated static let reserveResources: Bundle? =
    Bundle.packagedReserveResources ?? Bundle.reserveResourcesBesideExecutable

  private nonisolated static var packagedReserveResources: Bundle? {
    guard let url = Bundle.main.url(forResource: "Reserve_Reserve", withExtension: "bundle")
    else { return nil }
    return Bundle(url: url)
  }

  /// Where `swift build` and `swift run` leave it: beside the executable. This
  /// is the first place `Bundle.module` looks, without its trap.
  private nonisolated static var reserveResourcesBesideExecutable: Bundle? {
    Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Reserve_Reserve.bundle"))
  }

  /// Problems that would make the packaged app fail on first use. The package
  /// smoke test runs this from the staged `Reserve.app`, with the SwiftPM build
  /// directory already removed, so a packaging regression fails the build
  /// instead of the first launch.
  nonisolated static func packagedReserveResourceFailures() -> [String] {
    guard let bundle = Bundle.packagedReserveResources else {
      return ["Reserve_Reserve.bundle is not in Contents/Resources"]
    }
    guard bundle.url(forResource: "anthropic", withExtension: "svg", subdirectory: "ProviderLogos") != nil
    else {
      return ["ProviderLogos are missing from Reserve_Reserve.bundle"]
    }
    return []
  }
}
