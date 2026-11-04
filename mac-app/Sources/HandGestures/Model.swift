import AppKit
import Foundation

/// A hand shape recognised in one frame.
enum Pose: String, Codable, CaseIterable, Identifiable {
    case openPalm, fist, point, lShape, v, three, rock, shaka, thumbsUp, ok, pinch, none

    var id: String { rawValue }

    /// Shapes a gesture can use.
    static let usable: [Pose] = [.openPalm, .fist, .point, .lShape, .v, .three, .rock, .shaka, .thumbsUp, .ok]

    var emoji: String {
        switch self {
        case .openPalm: "✋"
        case .fist: "✊"
        case .point: "☝️"
        case .lShape: "📸"
        case .v: "✌️"
        case .three: "3️⃣"
        case .rock: "🤘"
        case .shaka: "🤙"
        case .thumbsUp: "👍"
        case .ok: "👌"
        case .pinch: "🤏"
        case .none: "·"
        }
    }

    var title: String {
        switch self {
        case .openPalm: "Open palm"
        case .fist: "Fist"
        case .point: "Point"
        case .lShape: "L shape"
        case .v: "V sign"
        case .three: "Three fingers"
        case .rock: "Rock sign"
        case .shaka: "Shaka"
        case .thumbsUp: "Thumbs up"
        case .ok: "OK sign"
        case .pinch: "Pinch"
        case .none: "No gesture"
        }
    }

    var how: String {
        switch self {
        case .openPalm: "All fingers up"
        case .fist: "All fingers curled"
        case .point: "Index finger up"
        case .lShape: "Thumb and index out"
        case .v: "Index and middle up"
        case .three: "Index, middle and ring up"
        case .rock: "Index and pinky up"
        case .shaka: "Thumb and pinky out"
        case .thumbsUp: "Thumb up, fingers curled"
        case .ok: "Thumb and index touching, other fingers up"
        case .pinch: "Thumb and index touching"
        case .none: ""
        }
    }
}

/// What the hand does with a shape.
enum Motion: String, Codable, CaseIterable, Identifiable {
    case hold, swipeLeft, swipeRight, swipeUp, swipeDown, moveUpDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold still"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .moveUpDown: "Move up / down"
        }
    }

    var isSwipe: Bool { [.swipeLeft, .swipeRight, .swipeUp, .swipeDown].contains(self) }
}

/// Something a gesture can do.
enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    case startStop, pointer
    case scroll, volume
    case dictation, pasteAndSend
    case next, previous, nextTab, previousTab, reload
    case missionControl, appExpose, desktopNext, desktopPrevious, lastApp, minimize, fullScreen
    case playPause, nextTrack, previousTrack, mute
    case screenshotArea, screenshotScreen
    case lockScreen, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nothing"
        case .startStop: "Start / stop listening"
        case .pointer: "Laser pointer on / off"
        case .scroll: "Scroll"
        case .volume: "Volume"
        case .dictation: "Wispr dictation on / off"
        case .pasteAndSend: "Paste last dictation + Enter"
        case .next: "Next (tab, slide or skip)"
        case .previous: "Previous (tab, slide or skip)"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .reload: "Reload page"
        case .missionControl: "Mission Control"
        case .appExpose: "App windows"
        case .desktopNext: "Next desktop"
        case .desktopPrevious: "Previous desktop"
        case .lastApp: "Switch to last app"
        case .minimize: "Minimize window"
        case .fullScreen: "Full screen on / off"
        case .playPause: "Play / pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        case .mute: "Mute"
        case .screenshotArea: "Screenshot area to clipboard"
        case .screenshotScreen: "Screenshot screen to clipboard"
        case .lockScreen: "Lock screen"
        case .custom: "Keyboard shortcut…"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .startStop: "hand.raised.fill"
        case .pointer: "cursorarrow.motionlines"
        case .scroll: "arrow.up.and.down"
        case .volume: "speaker.wave.2.fill"
        case .dictation: "mic.fill"
        case .pasteAndSend: "paperplane.fill"
        case .next: "chevron.right.2"
        case .previous: "chevron.left.2"
        case .nextTab: "arrow.right.square"
        case .previousTab: "arrow.left.square"
        case .reload: "arrow.clockwise"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "macwindow.on.rectangle"
        case .desktopNext: "arrow.right.to.line"
        case .desktopPrevious: "arrow.left.to.line"
        case .lastApp: "arrow.left.arrow.right"
        case .minimize: "minus.rectangle"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .playPause: "playpause.fill"
        case .nextTrack: "forward.fill"
        case .previousTrack: "backward.fill"
        case .mute: "speaker.slash.fill"
        case .screenshotArea: "camera.viewfinder"
        case .screenshotScreen: "camera.fill"
        case .lockScreen: "lock.fill"
        case .custom: "keyboard"
        }
    }

    /// Actions that run once (a key press, a media key…), as opposed to the
    /// built-in modes the recognizer drives itself.
    var isDiscrete: Bool { ![.startStop, .pointer, .scroll, .volume].contains(self) }

    static let discreteGroups: [(String, [ActionKind])] = [
        ("Dictation", [.dictation, .pasteAndSend]),
        ("Browsing & presenting", [.next, .previous, .nextTab, .previousTab, .reload]),
        ("Windows & desktops", [.missionControl, .appExpose, .desktopNext, .desktopPrevious, .lastApp, .minimize, .fullScreen]),
        ("Media", [.playPause, .nextTrack, .previousTrack, .mute]),
        ("Capture", [.screenshotArea, .screenshotScreen]),
        ("Other", [.lockScreen, .custom, .none]),
    ]

    /// The actions that make sense for a movement.
    static func groups(for motion: Motion) -> [(String, [ActionKind])] {
        switch motion {
        case .moveUpDown: [("Move up / down", [.scroll, .volume, .none])]
        case .hold: [("Hand Gestures", [.pointer])] + discreteGroups
        default: discreteGroups
        }
    }
}

/// A recorded keyboard shortcut.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags raw value
    var display: String
}

/// One line of the cheat sheet: a hand shape, what the hand does with it, and the action.
struct GestureRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var pose: Pose
    var motion: Motion
    var action: ActionKind
    var shortcut: Shortcut?

    var gestureTitle: String { "\(pose.title) · \(motion.title.lowercased())" }

    var actionTitle: String {
        action == .custom ? (shortcut?.display ?? "Shortcut not set") : action.title
    }

    static let defaults: [GestureRule] = [
        .init(pose: .openPalm, motion: .hold, action: .startStop),
        .init(pose: .thumbsUp, motion: .hold, action: .dictation),
        .init(pose: .rock, motion: .hold, action: .pasteAndSend),
        .init(pose: .shaka, motion: .hold, action: .lastApp),
        .init(pose: .lShape, motion: .hold, action: .screenshotArea),
        .init(pose: .fist, motion: .hold, action: .playPause),
        .init(pose: .three, motion: .hold, action: .pointer),
        .init(pose: .openPalm, motion: .swipeLeft, action: .next),
        .init(pose: .openPalm, motion: .swipeRight, action: .previous),
        .init(pose: .openPalm, motion: .swipeUp, action: .missionControl),
        .init(pose: .openPalm, motion: .swipeDown, action: .reload),
        .init(pose: .v, motion: .swipeLeft, action: .desktopNext),
        .init(pose: .v, motion: .swipeRight, action: .desktopPrevious),
        .init(pose: .point, motion: .moveUpDown, action: .scroll),
        .init(pose: .ok, motion: .moveUpDown, action: .volume),
    ]
}

struct Settings: Codable, Equatable {
    var gestures: [GestureRule] = GestureRule.defaults

    var holdSeconds = 0.7
    var wakeSeconds = 1.2
    var sleepAfterSeconds = 30.0
    var swipeDistance = 0.18
    var scrollSpeed = 6000.0
    var invertScroll = false
    var pointerSmoothing = 0.35

    /// Pinch thumb and index to press the mouse; move while pinched to drag.
    var pinchGrab = true
    var dragSpeed = 1.0
    /// Pinch with both hands and pull apart / push together.
    var twoHandZoom = true
    var twoHandResizesWindow = false

    var sounds = true
    var showHUD = true
    var practiceMode = false
    var showPreview = true
    var cameraID: String?
    var startOnLaunch = true
    var onboarded = false

    /// The rule that starts and stops listening (there is always exactly one).
    var startStopRule: GestureRule {
        gestures.first { $0.action == .startStop } ?? GestureRule.defaults[0]
    }

    /// A problem with a rule, shown under it in the editor.
    func warning(for rule: GestureRule) -> String? {
        let same = gestures.filter { $0.pose == rule.pose && $0.motion == rule.motion }
        if same.count > 1, same.first?.id != rule.id {
            return "\(rule.pose.title) · \(rule.motion.title.lowercased()) is already used above, so this one won't run."
        }
        if rule.motion == .moveUpDown,
           gestures.contains(where: { $0.pose == rule.pose && ($0.motion == .swipeUp || $0.motion == .swipeDown) }) {
            return "Moving \(rule.pose.title.lowercased()) up or down can be mistaken for its swipe up / down."
        }
        if rule.action == .custom && rule.shortcut == nil { return "Record a shortcut for this gesture." }
        return nil
    }

    static let storageKey = "settings.v1"

    /// Loads saved settings, keeping defaults for anything new, and carries over the
    /// per-gesture choices saved by versions before the gesture editor.
    static func load() -> Settings {
        let encoder = JSONEncoder()
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultsData = try? encoder.encode(Settings()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any]
        else { return Settings() }

        if stored["gestures"] == nil, let old = stored["bindings"] as? [String: Any],
           let rules = migrate(old, stored), let rulesData = try? encoder.encode(rules) {
            stored["gestures"] = try? JSONSerialization.jsonObject(with: rulesData)
        }
        let merged = defaults.merging(stored.filter { defaults[$0.key] != nil }) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(Settings.self, from: mergedData) else { return Settings() }
        return s
    }

    /// Before the editor, gestures were a fixed list keyed by name with on/off switches.
    private static func migrate(_ bindings: [String: Any], _ stored: [String: Any]) -> [GestureRule]? {
        let old: [String: (Pose, Motion)] = [
            "thumbsUp": (.thumbsUp, .hold), "rock": (.rock, .hold), "shaka": (.shaka, .hold),
            "lShape": (.lShape, .hold), "fist": (.fist, .hold),
            "palmLeft": (.openPalm, .swipeLeft), "palmRight": (.openPalm, .swipeRight),
            "palmUp": (.openPalm, .swipeUp), "palmDown": (.openPalm, .swipeDown),
            "vLeft": (.v, .swipeLeft), "vRight": (.v, .swipeRight),
        ]
        var rules: [GestureRule] = []
        for d in GestureRule.defaults {
            switch d.action {
            case .pointer where stored["pointerEnabled"] as? Bool == false: continue
            case .scroll where stored["scrollEnabled"] as? Bool == false: continue
            case .volume where stored["volumeEnabled"] as? Bool == false: continue
            default: break
            }
            var rule = d
            if let key = old.first(where: { $0.value == (d.pose, d.motion) })?.key,
               let b = bindings[key] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: b),
               let decoded = try? JSONDecoder().decode(OldBinding.self, from: data) {
                rule.action = decoded.action
                rule.shortcut = decoded.shortcut
            }
            rules.append(rule)
        }
        return rules
    }

    private struct OldBinding: Codable {
        var action: ActionKind
        var shortcut: Shortcut?
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Settings.storageKey)
        }
    }
}
