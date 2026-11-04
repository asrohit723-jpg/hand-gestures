import AppKit
import Foundation

/// A hand shape recognised in one frame.
enum Pose: String, Codable, CaseIterable {
    case openPalm, fist, point, lShape, v, three, rock, shaka, thumbsUp, ok, none

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
        case .none: "No gesture"
        }
    }
}

/// A gesture the user can assign an action to.
enum Trigger: String, Codable, CaseIterable, Identifiable {
    case thumbsUp, rock, shaka, lShape, fist
    case palmLeft, palmRight, palmUp, palmDown, vLeft, vRight

    var id: String { rawValue }

    static let holds: [Trigger] = [.thumbsUp, .rock, .shaka, .lShape, .fist]
    static let swipes: [Trigger] = [.palmLeft, .palmRight, .palmUp, .palmDown, .vLeft, .vRight]

    var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .rock: "🤘"
        case .shaka: "🤙"
        case .lShape: "📸"
        case .fist: "✊"
        case .palmLeft, .palmRight, .palmUp, .palmDown: "✋"
        case .vLeft, .vRight: "✌️"
        }
    }

    var title: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .rock: "Rock sign"
        case .shaka: "Shaka"
        case .lShape: "L shape"
        case .fist: "Fist"
        case .palmLeft: "Palm swipe left"
        case .palmRight: "Palm swipe right"
        case .palmUp: "Palm swipe up"
        case .palmDown: "Palm swipe down"
        case .vLeft: "V swipe left"
        case .vRight: "V swipe right"
        }
    }

    var how: String {
        switch self {
        case .thumbsUp: "Thumb up, fingers curled — hold still"
        case .rock: "Index and pinky up — hold still"
        case .shaka: "Thumb and pinky out — hold still"
        case .lShape: "Thumb and index out like a camera corner — hold still"
        case .fist: "Closed fist — hold still"
        case .palmLeft, .palmRight, .palmUp, .palmDown: "Open hand, quick move"
        case .vLeft, .vRight: "Two fingers up, quick move"
        }
    }

    var defaultAction: ActionKind {
        switch self {
        case .thumbsUp: .dictation
        case .rock: .pasteAndSend
        case .shaka: .lastApp
        case .lShape: .screenshotArea
        case .fist: .playPause
        case .palmLeft: .next
        case .palmRight: .previous
        case .palmUp: .missionControl
        case .palmDown: .reload
        case .vLeft: .desktopNext
        case .vRight: .desktopPrevious
        }
    }
}

/// Something a gesture can do.
enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    case dictation, pasteAndSend
    case next, previous, nextTab, previousTab, reload
    case missionControl, appExpose, desktopNext, desktopPrevious, lastApp
    case playPause, nextTrack, previousTrack, mute
    case screenshotArea, screenshotScreen
    case lockScreen, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nothing"
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

    static let groups: [(String, [ActionKind])] = [
        ("Dictation", [.dictation, .pasteAndSend]),
        ("Browsing & presenting", [.next, .previous, .nextTab, .previousTab, .reload]),
        ("Windows & desktops", [.missionControl, .appExpose, .desktopNext, .desktopPrevious, .lastApp]),
        ("Media", [.playPause, .nextTrack, .previousTrack, .mute]),
        ("Capture", [.screenshotArea, .screenshotScreen]),
        ("Other", [.lockScreen, .custom, .none]),
    ]
}

/// A recorded keyboard shortcut.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags raw value
    var display: String
}

struct GestureBinding: Codable, Equatable {
    var action: ActionKind
    var shortcut: Shortcut?
}

struct Settings: Codable, Equatable {
    var bindings: [String: GestureBinding] = Dictionary(
        uniqueKeysWithValues: Trigger.allCases.map { ($0.rawValue, GestureBinding(action: $0.defaultAction)) })
    var scrollEnabled = true
    var volumeEnabled = true
    var pointerEnabled = true

    var holdSeconds = 0.7
    var wakeSeconds = 1.2
    var sleepAfterSeconds = 30.0
    var swipeDistance = 0.18
    var scrollSpeed = 6000.0
    var invertScroll = false
    var pointerSmoothing = 0.35

    var sounds = true
    var showHUD = true
    var practiceMode = false
    var showPreview = true
    var cameraID: String?
    var startOnLaunch = true
    var onboarded = false

    func binding(_ t: Trigger) -> GestureBinding {
        bindings[t.rawValue] ?? GestureBinding(action: t.defaultAction)
    }

    static let storageKey = "settings.v1"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Settings.storageKey)
        }
    }
}
