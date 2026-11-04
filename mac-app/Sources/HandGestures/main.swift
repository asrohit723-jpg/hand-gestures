import AppKit
import Carbon
import Combine
import SwiftUI

/// Menu bar icon + dropdown, the Hand Gestures window (for when the menu bar icon is
/// hidden behind the notch), and the Settings / Welcome windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var controlWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        updateIcon()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: menuView())

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &cancellables)

        // ⌃⌥H opens the Hand Gestures window from anywhere.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggleControlWindow()
        }

        Updater.shared.startChecking()

        if !state.settings.onboarded || state.cameraStatus != .authorized || !state.accessibilityGranted {
            showWelcome()
        } else if state.settings.startOnLaunch {
            state.start()
        }
    }

    /// Clicking the Dock icon, or opening the app again from Spotlight or Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if welcomeWindow?.isVisible == true || settingsWindow?.isVisible == true { return true }
        showControlWindow()
        return false
    }

    private func menuView() -> MenuView {
        MenuView(state: state,
                 openSettings: { [weak self] in self?.showSettings() },
                 openWelcome: { [weak self] in self?.showWelcome() })
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: state.menuBarSymbol, accessibilityDescription: "Hand Gestures")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func toggleControlWindow() {
        if let w = controlWindow, w.isVisible, w.isKeyWindow { w.close() } else { showControlWindow() }
    }

    private func showControlWindow() {
        popover.performClose(nil)
        if controlWindow == nil {
            controlWindow = makeWindow(title: "Hand Gestures", view: menuView())
        }
        present(controlWindow!)
    }

    @objc private func checkForUpdates() {
        Updater.shared.check()
        showControlWindow()
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Hand Gestures Settings", view: SettingsView(state: state))
        }
        present(settingsWindow!)
    }

    private func showWelcome() {
        popover.performClose(nil)
        if welcomeWindow == nil {
            welcomeWindow = makeWindow(title: "Welcome", view: WelcomeView(state: state) { [weak self] in
                guard let self else { return }
                self.state.settings.onboarded = true
                self.state.previewVisible = false
                self.welcomeWindow?.close()
                if !self.state.running { self.state.start() }
            })
        }
        present(welcomeWindow!)
    }

    private func makeWindow<V: View>(title: String, view: V) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// App menu for when the app shows in the Dock: Settings, Close, Quit.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Hand Gestures", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}

/// A system-wide keyboard shortcut (Carbon hot key; needs no extra permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4847_5354), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    Snapshot.run(dir: CommandLine.arguments[i + 1])
    exit(0)
}
// Command-line checks of the updater, used when testing releases.
if CommandLine.arguments.contains("--check-update") {
    Updater.shared.check { release in
        print("current \(Updater.shared.currentVersion); latest \(release?.version ?? "none newer"); status \(Updater.shared.status)")
        exit(0)
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--install-update") {
    let updater = Updater.shared
    updater.check { release in
        guard release != nil else { print("nothing to install: \(updater.status)"); exit(1) }
        var watcher: AnyCancellable?
        watcher = updater.$status.sink { status in
            if case .failed(let message) = status { print("failed: \(message)"); watcher?.cancel(); exit(1) }
        }
        updater.install()
    }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--verify-update"), i + 2 < CommandLine.arguments.count {
    do {
        let app = try Updater.unpackAndVerify(URL(fileURLWithPath: CommandLine.arguments[i + 1]),
                                              expecting: CommandLine.arguments[i + 2])
        print("verified: \(app.path)")
        exit(0)
    } catch {
        print("rejected: \(error.localizedDescription)")
        exit(1)
    }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppState.shared.showInDock ? .regular : .accessory)
app.run()
