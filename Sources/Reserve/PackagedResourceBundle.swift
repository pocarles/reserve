import Foundation

/// Some `Bundle.module` accessor generations never check Contents/Resources,
/// where `Scripts/package_app.sh` places the bundle, and merely evaluating
/// `Bundle.module` is then fatal — so resolve the packaged bundle first.
enum PackagedResourceBundle {
  /// The resource bundle to use for `Bundle.module.url(forResource:...)`
  /// call sites, working both from the packaged Reserve.app and from
  /// `swift run`/`swift test` during development.
  static var resolved: Bundle {
    self.packaged ?? Bundle.module
  }

  private static var packaged: Bundle? {
    guard
      Bundle.main.bundleURL.pathExtension == "app",
      let url = Bundle.main.url(forResource: "Reserve_Reserve", withExtension: "bundle")
    else { return nil }
    return Bundle(url: url)
  }
}
