import AppKit
import SwiftUI
import YumYumCore

@MainActor
final class ShortcutRecorderButton: NSButton {
    var shortcut: ClipboardFeedShortcut
    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    var onRecord: ((ClipboardFeedShortcut) -> Void)?
    var isRecording = false

    init(shortcut: ClipboardFeedShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        updateShortcut(shortcut)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateShortcut(_ shortcut: ClipboardFeedShortcut) {
        guard !isRecording else { return }
        self.shortcut = shortcut
        title = shortcut.displayName
        setAccessibilityLabel(AppText.localized("클립보드 먹이기 전역 단축키"))
        setAccessibilityValue(shortcut.displayName)
        setAccessibilityHelp(AppText.localized("누른 뒤 새 키 조합을 입력하세요. Esc로 취소합니다."))
    }

    @objc
    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = AppText.localized("키 조합을 누르세요…")
        onBeginRecording?()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return handleRecordingKey(event)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording, handleRecordingKey(event) { return }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            endRecording()
        }
        return super.resignFirstResponder()
    }

    private func handleRecordingKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            endRecording()
            return true
        }
        guard let shortcut = ClipboardFeedShortcut.recorded(from: event) else {
            NSSound.beep()
            return true
        }
        self.shortcut = shortcut
        onRecord?(shortcut)
        endRecording()
        return true
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        title = shortcut.displayName
        setAccessibilityValue(shortcut.displayName)
        onEndRecording?()
        window?.makeFirstResponder(nil)
    }
}

@MainActor
struct ShortcutRecorderField: NSViewRepresentable {
    let shortcut: ClipboardFeedShortcut
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void
    let onRecord: (ClipboardFeedShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(shortcut: shortcut)
        button.onBeginRecording = onBeginRecording
        button.onEndRecording = onEndRecording
        button.onRecord = onRecord
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.onBeginRecording = onBeginRecording
        nsView.onEndRecording = onEndRecording
        nsView.onRecord = onRecord
        nsView.updateShortcut(shortcut)
    }
}
