import AppKit
import SwiftUI

/// A ring around the pointer while the hand is holding it, so it's always clear when
/// the hand is in control. It fills in while the fingers are pinched.
final class PointerRing {
    private final class Model: ObservableObject {
        @Published var pressed = false
    }

    private struct RingView: View {
        @ObservedObject var model: Model

        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(model.pressed ? 0.35 : 0.08))
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: model.pressed ? 3 : 2)
            }
            .frame(width: model.pressed ? 26 : 36, height: model.pressed ? 26 : 36)
            .shadow(color: .black.opacity(0.25), radius: 3)
            .frame(width: Self.size, height: Self.size)
            .animation(.easeOut(duration: 0.12), value: model.pressed)
        }

        static let size: CGFloat = 48
    }

    private let model = Model()
    private var panel: NSPanel?

    func show(at p: CGPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.pressed = false
        move(to: p)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    func setPressed(_ pressed: Bool) {
        if model.pressed != pressed { model.pressed = pressed }
    }

    /// `p` is in global display coordinates (origin top-left of the main display).
    func move(to p: CGPoint) {
        guard let panel, let main = NSScreen.screens.first else { return }
        let s = RingView.size
        panel.setFrameOrigin(NSPoint(x: p.x - s / 2, y: main.frame.maxY - p.y - s / 2))
    }

    private func makePanel() -> NSPanel {
        let s = RingView.size
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: RingView(model: model))
        return p
    }
}
