import AppKit
import ApplicationServices

/// Synthesised keyboard, media-key, scroll and cursor input.
/// Needs Accessibility permission (System Settings > Privacy & Security > Accessibility).
enum Input {
    enum Mod: CaseIterable {
        case ctrl, opt, shift, cmd, fn
        var code: CGKeyCode {
            switch self { case .cmd: 55; case .shift: 56; case .opt: 58; case .ctrl: 59; case .fn: 63 }
        }
        var flag: CGEventFlags {
            switch self {
            case .cmd: .maskCommand
            case .shift: .maskShift
            case .opt: .maskAlternate
            case .ctrl: .maskControl
            case .fn: .maskSecondaryFn
            }
        }
    }

    enum Key {
        static let v: CGKeyCode = 9, r: CGKeyCode = 15, q: CGKeyCode = 12
        static let three: CGKeyCode = 20, four: CGKeyCode = 21
        static let rightBracket: CGKeyCode = 30, leftBracket: CGKeyCode = 33
        static let returnKey: CGKeyCode = 36, tab: CGKeyCode = 48, space: CGKeyCode = 49
        static let left: CGKeyCode = 123, right: CGKeyCode = 124, down: CGKeyCode = 125, up: CGKeyCode = 126
    }

    /// Arrow and navigation keys only switch Spaces / open Mission Control when
    /// they carry the flags a real keyboard sends with them.
    private static let navKeys: ClosedRange<CGKeyCode> = 115...126

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// Press a key with modifiers. Modifiers go down as real key presses so
    /// Cmd+Tab and Fn-based hotkeys behave as if typed.
    static func press(_ key: CGKeyCode?, _ mods: [Mod] = []) {
        var flags: CGEventFlags = []
        for m in mods {
            flags.insert(m.flag)
            post(m.code, down: true, flags: flags)
        }
        if let key {
            var keyFlags = flags
            if navKeys.contains(key) { keyFlags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
            post(key, down: true, flags: keyFlags)
            usleep(20_000)
            post(key, down: false, flags: keyFlags)
        }
        for m in mods.reversed() {
            flags.remove(m.flag)
            post(m.code, down: false, flags: flags)
        }
    }

    static func press(_ s: Shortcut) {
        let f = NSEvent.ModifierFlags(rawValue: s.modifiers)
        var mods: [Mod] = []
        if f.contains(.control) { mods.append(.ctrl) }
        if f.contains(.option) { mods.append(.opt) }
        if f.contains(.shift) { mods.append(.shift) }
        if f.contains(.command) { mods.append(.cmd) }
        press(CGKeyCode(s.keyCode), mods)
    }

    enum Media: Int32 { case volumeUp = 0, volumeDown = 1, mute = 7, play = 16, next = 17, previous = 18 }

    /// Media and volume keys; these also show the system's own HUD.
    static func media(_ key: Media) {
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: Int((key.rawValue << 16) | Int32(state)), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func scroll(_ pixels: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: pixels, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    static func moveCursor(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static var mainScreenSize: CGSize { CGDisplayBounds(CGMainDisplayID()).size }

    /// Readable form of a shortcut, e.g. ⌃⌘→.
    static func describe(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let named: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
                                       123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return s + (named[keyCode] ?? (characters ?? "?").uppercased())
    }
}

/// Runs the action bound to a gesture.
enum ActionRunner {
    static let browsers = ["Google Chrome", "Safari", "Arc", "Microsoft Edge", "Brave Browser", "Firefox", "Dia", "Comet"]
    static let slideApps = ["Keynote", "Microsoft PowerPoint", "Preview"]
    static let videoApps = ["QuickTime Player", "IINA", "VLC"]

    static var frontApp: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }

    /// Performs the action and returns the label to show, or nil if nothing applies here.
    @discardableResult
    static func run(_ b: GestureBinding, dryRun: Bool) -> String? {
        let app = frontApp
        var label = b.action.title
        var work: (() -> Void)?

        switch b.action {
        case .none: return nil
        case .dictation: work = { Input.press(Input.Key.space, [.fn]) }
        case .pasteAndSend:
            label = "Paste + send"
            work = {
                Input.press(Input.Key.v, [.ctrl, .cmd])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Input.press(Input.Key.returnKey) }
            }
        case .next, .previous:
            let next = b.action == .next
            if browsers.contains(app) {
                label = next ? "Next tab" : "Previous tab"
                work = { Input.press(next ? Input.Key.rightBracket : Input.Key.leftBracket, [.shift, .cmd]) }
            } else if slideApps.contains(app) {
                label = next ? "Next slide" : "Previous slide"
                work = { Input.press(next ? Input.Key.right : Input.Key.left) }
            } else if videoApps.contains(app) {
                label = next ? "Skip forward" : "Skip back"
                work = { Input.press(next ? Input.Key.right : Input.Key.left) }
            } else {
                return "\(next ? "Next" : "Previous") isn't set up for \(app.isEmpty ? "this app" : app)"
            }
        case .nextTab: work = { Input.press(Input.Key.rightBracket, [.shift, .cmd]) }
        case .previousTab: work = { Input.press(Input.Key.leftBracket, [.shift, .cmd]) }
        case .reload: work = { Input.press(Input.Key.r, [.cmd]) }
        case .missionControl: work = { Input.press(Input.Key.up, [.ctrl]) }
        case .appExpose: work = { Input.press(Input.Key.down, [.ctrl]) }
        case .desktopNext: work = { Input.press(Input.Key.right, [.ctrl]) }
        case .desktopPrevious: work = { Input.press(Input.Key.left, [.ctrl]) }
        case .lastApp: work = { Input.press(Input.Key.tab, [.cmd]) }
        case .playPause: work = { Input.media(.play) }
        case .nextTrack: work = { Input.media(.next) }
        case .previousTrack: work = { Input.media(.previous) }
        case .mute: work = { Input.media(.mute) }
        case .screenshotArea: work = { Input.press(Input.Key.four, [.ctrl, .shift, .cmd]) }
        case .screenshotScreen: work = { Input.press(Input.Key.three, [.ctrl, .shift, .cmd]) }
        case .lockScreen: work = { Input.press(Input.Key.q, [.ctrl, .cmd]) }
        case .custom:
            guard let s = b.shortcut else { return "No shortcut recorded" }
            label = s.display
            work = { Input.press(s) }
        }
        if !dryRun { work?() }
        return label
    }
}
