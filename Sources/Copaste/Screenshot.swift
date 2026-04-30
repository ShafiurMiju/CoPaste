import Foundation

enum Screenshot {
    /// Launches the macOS system screen-capture UI in interactive (region
    /// selection) mode and writes the result to the clipboard. Our
    /// ClipboardWatcher then picks it up and adds it to the Images tab.
    static func captureInteractive() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-c"]
        do {
            try task.run()
        } catch {
            NSLog("[Copaste] screencapture failed: \(error)")
        }
    }
}
