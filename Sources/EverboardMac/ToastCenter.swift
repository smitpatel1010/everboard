import AppKit
import EverboardCore
import SwiftUI

/// In-app banners used when macOS won't deliver system notifications (e.g. the app isn't properly signed).
/// Non-activating panels in the top-right corner, stacked, auto-dismissing.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    struct Toast: Identifiable {
        let id = UUID()
        let title: String
        let body: String
        let actionTitle: String?
        let onClick: () -> Void
        let onAction: (() -> Void)?
    }

    private var panels: [(UUID, NSPanel)] = []
    private let width: CGFloat = 360
    private let maxVisible = 4

    func show(_ toast: Toast, duration: TimeInterval = 10) {
        if panels.count >= maxVisible, let oldest = panels.first { dismiss(oldest.0) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 90),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let id = toast.id
        let host = NSHostingView(rootView: ToastView(toast: toast, dismiss: { [weak self] in self?.dismiss(id) }))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(NSSize(width: width, height: host.fittingSize.height))
        panels.append((id, panel))
        layout()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.dismiss(id) }
    }

    func dismiss(_ id: UUID) {
        guard let i = panels.firstIndex(where: { $0.0 == id }) else { return }
        panels[i].1.orderOut(nil)
        panels.remove(at: i)
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.maxY - 10
        for (_, p) in panels.reversed() {
            y -= p.frame.height
            p.setFrameOrigin(NSPoint(x: screen.maxX - width - 12, y: y))
            y -= 8
        }
    }
}

private struct ToastView: View {
    let toast: ToastCenter.Toast
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.grid.2x2.fill").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text(toast.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let actionTitle = toast.actionTitle, let onAction = toast.onAction {
                    Button(actionTitle) { onAction(); dismiss() }.controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless).opacity(hovering ? 1 : 0.4)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { toast.onClick(); dismiss() }
        .onHover { hovering = $0 }
    }
}
