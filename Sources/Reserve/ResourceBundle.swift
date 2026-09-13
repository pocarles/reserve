import Foundation

/// Resources SwiftPM copies next to the binary: provider marks and the Claude
/// login helper script.
///
/// SwiftPM's generated `Bundle.module` only looks beside `Bundle.main` and in
/// the build directory that produced the binary. The packaged app keeps the
/// resource bundle in `Contents/Resources`, and the build directory is a
/// temporary path that packaging deletes, so the first feature to touch
/// `Bundle.module` in an installed copy traps. Every lookup goes through this
/// accessor instead; `Bundle.module` remains only as the development fallback.
extension Bundle {
  nonisolated static let reserveResources: Bundle = {
    if let bundle = Bundle.packagedReserveResources { return bundle }
    return Bundle.module
  }()

  private nonisolated static var packagedReserveResources: Bundle? {
    guard let url = Bundle.main.url(forResource: "Reserve_Reserve", withExtension: "bundle")
    else { return nil }
    return Bundle(url: url)
  }

  /// Problems that would make the packaged app crash or fail on first use.
  /// The package smoke test runs this from the staged `Reserve.app`, with the
  /// SwiftPM build directory already removed, so a packaging regression fails
  /// the build instead of the first Claude sign-in.
  nonisolated static func packagedReserveResourceFailures() -> [String] {
    guard let bundle = Bundle.packagedReserveResources else {
      return ["Reserve_Reserve.bundle is not in Contents/Resources"]
    }
    guard let script = bundle.url(forResource: "ClaudeLoginBrowser", withExtension: "sh") else {
      return ["ClaudeLoginBrowser.sh is missing from Reserve_Reserve.bundle"]
    }
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
      return ["ClaudeLoginBrowser.sh is not executable in Reserve_Reserve.bundle"]
    }
    return []
  }
}
