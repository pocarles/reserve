import AppKit
import ReserveCore

/// The folder chooser for an added Claude account, shared by Settings and the
/// Connect window. Hidden folders are shown because Claude Code's configuration
/// homes are dot-folders by convention, and a folder may be created on the spot:
/// Claude Code fills it in at the first sign-in.
@MainActor
enum ClaudeConfigDirectoryPicker {
  static func choose(
    current: ClaudeConfigDirectory?,
    from window: NSWindow?,
    completion: @escaping @MainActor (URL?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Choose"
    panel.message = "Choose the Claude Code configuration folder for this account, such as ~/.claude-team."
    panel.directoryURL = current?.url ?? FileManager.default.homeDirectoryForCurrentUser
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      completion(response == .OK ? panel.url : nil)
    }
    if let window, window.isVisible {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }
}
