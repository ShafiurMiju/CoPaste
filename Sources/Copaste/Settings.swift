import AppKit
import SwiftUI

final class SettingsController {
    static let shared = SettingsController()

    private var window: NSWindow?
    /// Called after the user applies new limits so the rest of the app can
    /// reload (re-trim and refresh the popup).
    var onApply: (() -> Void)?

    func show() {
        if window == nil { build() }
        guard let w = window else { return }

        let view = SettingsView(
            initialTextLimit: Database.textHistoryLimit,
            initialImageLimit: Database.imageHistoryLimit,
            currentTextCount: Database.shared.textCount(),
            currentImageCount: Database.shared.imageCount(),
            unpinnedTextCount: Database.shared.unpinnedTextCount(),
            unpinnedImageCount: Database.shared.unpinnedImageCount(),
            onApply: { [weak self] textLimit, imageLimit in
                UserDefaults.standard.set(textLimit, forKey: Database.textHistoryLimitKey)
                UserDefaults.standard.set(imageLimit, forKey: Database.imageHistoryLimitKey)
                Database.shared.enforceLimits()
                self?.onApply?()
                w.close()
            },
            onCancel: { w.close() }
        )
        let host = NSHostingController(rootView: view)
        w.contentViewController = host

        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "History Limits"
        w.isReleasedWhenClosed = false
        self.window = w
    }
}

private struct SettingsView: View {
    let currentTextCount: Int
    let currentImageCount: Int
    let unpinnedTextCount: Int
    let unpinnedImageCount: Int
    let onApply: (Int, Int) -> Void
    let onCancel: () -> Void

    @State private var textLimit: Double
    @State private var imageLimit: Double
    @State private var showConfirmAlert = false

    init(
        initialTextLimit: Int,
        initialImageLimit: Int,
        currentTextCount: Int,
        currentImageCount: Int,
        unpinnedTextCount: Int,
        unpinnedImageCount: Int,
        onApply: @escaping (Int, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentTextCount = currentTextCount
        self.currentImageCount = currentImageCount
        self.unpinnedTextCount = unpinnedTextCount
        self.unpinnedImageCount = unpinnedImageCount
        self.onApply = onApply
        self.onCancel = onCancel
        _textLimit = State(initialValue: Double(initialTextLimit))
        _imageLimit = State(initialValue: Double(initialImageLimit))
    }

    private var textDeletions: Int {
        max(0, unpinnedTextCount - Int(textLimit))
    }
    private var imageDeletions: Int {
        max(0, unpinnedImageCount - Int(imageLimit))
    }
    private var totalDeletions: Int { textDeletions + imageDeletions }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("History Limits")
                .font(.headline)

            limitSection(
                title: "Text clips",
                value: $textLimit,
                range: 10...1000,
                step: 10,
                currentCount: currentTextCount
            )

            limitSection(
                title: "Image clips",
                value: $imageLimit,
                range: 5...200,
                step: 5,
                currentCount: currentImageCount
            )

            Spacer(minLength: 0)

            HStack {
                Button("Reset Defaults") {
                    textLimit = Double(Database.defaultTextHistoryLimit)
                    imageLimit = Double(Database.defaultImageHistoryLimit)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if totalDeletions > 0 {
                        showConfirmAlert = true
                    } else {
                        onApply(Int(textLimit), Int(imageLimit))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(width: 420, height: 260)
        .alert("Trim older clips?", isPresented: $showConfirmAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Trim & Apply", role: .destructive) {
                onApply(Int(textLimit), Int(imageLimit))
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        var lines: [String] = []
        if textDeletions > 0 {
            lines.append("• \(textDeletions) older text clip\(textDeletions == 1 ? "" : "s")")
        }
        if imageDeletions > 0 {
            lines.append("• \(imageDeletions) older image\(imageDeletions == 1 ? "" : "s")")
        }
        let bullets = lines.joined(separator: "\n")
        return "Lowering the limit will permanently delete:\n\n\(bullets)\n\nPinned clips are kept. This cannot be undone."
    }

    @ViewBuilder
    private func limitSection(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        currentCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int(value.wrappedValue))")
                    .monospacedDigit()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Slider(value: value, in: range, step: step)
            HStack {
                Text("\(Int(range.lowerBound))")
                Spacer()
                Text("\(currentCount) currently stored")
                Spacer()
                Text("\(Int(range.upperBound))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

}
