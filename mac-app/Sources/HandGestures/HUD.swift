import AppKit
import SwiftUI

/// A small floating confirmation near the bottom of the screen, e.g. "↻ Reload page".
final class HUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    struct Content: View {
        let symbol: String
        let text: String
        let tint: Color

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(16)
            .fixedSize()
        }
    }

    func show(symbol: String, text: String, tint: Color = .accentColor) {
        let host = NSHostingView(rootView: Content(symbol: symbol, text: text, tint: tint))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 70, width: size.width, height: size.height),
                           display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
}
