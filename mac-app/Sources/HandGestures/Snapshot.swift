import AppKit
import SwiftUI

/// Debug aid: `HandGestures --snapshot <dir>` renders each screen to a PNG and exits.
enum Snapshot {
    static func run(dir: String) {
        let state = AppState.shared
        let bg = Color(nsColor: .windowBackgroundColor)
        render(MenuView(state: state, openSettings: {}, openWelcome: {}).background(bg), "menu", dir)
        render(CheatSheet(settings: state.settings).padding(14).frame(width: 340).background(bg), "cheatsheet", dir)
        render(GesturesTab(state: state).frame(width: 640, height: 600).background(bg), "settings-gestures", dir)
        render(FeelTab(state: state).frame(width: 640, height: 600).background(bg), "settings-feel", dir)
        render(PermissionsTab(state: state).frame(width: 640, height: 300).background(bg), "settings-permissions", dir)
        render(WelcomeView(state: state, done: {}).background(bg), "welcome", dir)
        render(HUD.Content(symbol: "arrow.clockwise", text: "Reload page", tint: .accentColor), "hud", dir)
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: String) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
