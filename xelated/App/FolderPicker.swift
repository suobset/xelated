import AppKit
import Foundation

/// Folder selection via `NSOpenPanel`.
///
/// Used in preference to SwiftUI's `fileImporter` because the panel can be told to
/// allow directory creation, which puts a New Folder button in the sheet — needed so a
/// destination folder can be made on an external drive on the spot.
@MainActor
enum FolderPicker {
    static func choose(
        title: String,
        message: String,
        prompt: String = "Choose",
        startingAt: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        if let startingAt, FileManager.default.fileExists(atPath: startingAt.path) {
            panel.directoryURL = startingAt
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
