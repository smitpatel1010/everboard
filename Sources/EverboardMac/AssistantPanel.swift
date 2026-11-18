import AppKit
import EverboardCore
import SwiftUI

/// The Assistant as a floating panel over whatever app you're in (⌥⇧Space), Spotlight-style.
/// It's non-activating, so your current app stays in front; it shares chats with the Assistant screen.
@MainActor
final class AssistantPanel: NSObject, NSWindowDelegate {
    static let shared = AssistantPanel()
    static let size = NSSize(width: 600, height: 440)

    private var panel: PalettePanel?
    private var keyMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The hotkey: open and start listening; pressed again while listening, send; while idle, close.
    func hotkey() {
        let voice = VoiceInput.shared
        if isVisible {
            if voice.isListening { voice.stop() } else { close() }
            return
        }
        show(listen: true)
    }

    func show(listen: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: AssistantOverlay(close: { [weak self] in self?.close() })
            .environment(\.refLinker, AppModel.shared.refLinker))
        // Top third of the screen the mouse is on.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - Self.size.width / 2, y: f.maxY - f.height / 3 - Self.size.height / 2,
                                  width: Self.size.width, height: Self.size.height), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        Task {
            await AssistantModel.shared.load()
            if listen && !VoiceInput.shared.isListening { AssistantModel.shared.toggleListening() }
        }
    }

    func close() {
        if VoiceInput.shared.isListening { VoiceInput.shared.cancel() }
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses it, unless you're mid-request: listening or waiting on an answer.
        let a = AssistantModel.shared
        if !VoiceInput.shared.isListening && !a.thinking && NSApp.modalWindow == nil { close() }
    }

    private func makePanel() -> PalettePanel {
        let p = PalettePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        return p
    }

    /// Esc cancels listening first, then closes.
    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow, event.keyCode == 53 else { return event }
            if VoiceInput.shared.isListening { VoiceInput.shared.cancel() } else { self.close() }
            return nil
        }
    }
}

/// What the floating panel shows: the current chat's latest turns, a run confirmation if one is waiting, and a composer.
struct AssistantOverlay: View {
    private var assistant: AssistantModel { .shared }
    private var voice: VoiceInput { .shared }
    let close: () -> Void
    @FocusState private var focused: Bool

    var recent: [AssistantChat.Message] { Array(assistant.messages.suffix(6)) }

    var body: some View {
        @Bindable var assistant = assistant
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Theme.accentGradient).frame(width: 24, height: 24)
                    .overlay(Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Assistant").font(.system(size: 13, weight: .semibold))
                    Text(assistant.current.map { $0.messages.isEmpty ? "New chat" : $0.title } ?? "New chat")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { assistant.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New chat")
                Button {
                    close()
                    AppModel.shared.showDashboard(.assistant)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help("Open in Everboard")
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close (esc)")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if recent.isEmpty && !assistant.thinking {
                            VStack(spacing: 10) {
                                Text(voice.isListening ? "Listening…" : "Ask anything about your work, or tell an agent what to do.")
                                    .foregroundStyle(.secondary)
                                FlowChips(items: AssistantModel.suggestions) { assistant.handle($0, spoken: false) }
                            }
                            .padding(.top, 28)
                        }
                        ForEach(recent) { MessageBubble(message: $0).id($0.id) }
                        if assistant.thinking { ThinkingBubble() }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: assistant.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: assistant.thinking) { withAnimation { proxy.scrollTo("bottom") } }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 10) {
                if voice.isListening {
                    Image(systemName: "waveform").foregroundStyle(.red).symbolEffect(.variableColor.iterative, isActive: true)
                    Text(voice.transcript.isEmpty ? "Listening… (esc to cancel)" : voice.transcript)
                        .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary).lineLimit(2)
                    Spacer()
                } else {
                    TextField("Ask or tell your agents…", text: $assistant.draft)
                        .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                        .onSubmit { assistant.submitDraft() }
                }
                if case .unavailable(let problem) = voice.state {
                    Image(systemName: "mic.slash").foregroundStyle(.orange).help(problem)
                }
                MicButton(size: 34)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: AssistantPanel.size.width, height: AssistantPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { if !voice.isListening { focused = true } }
    }
}
