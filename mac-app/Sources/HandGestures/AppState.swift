import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

/// Everything the UI shows, plus the glue between the camera pipeline and actions.
/// Touched on the main thread only.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            pipeline.update(settings: settings)
            pipeline.wantsPreview = previewVisible && settings.showPreview
            if settings.cameraID != oldValue.cameraID && running { restart() }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var awake = false
    @Published private(set) var pointerMode = false
    @Published private(set) var pose: Pose = .none
    @Published private(set) var handVisible = false
    @Published private(set) var lastAction: String?
    @Published private(set) var lastActionSymbol = "hand.raised"
    @Published private(set) var preview: CGImage?
    @Published private(set) var joints: [CGPoint]?
    @Published private(set) var accessibilityGranted = Input.trusted
    @Published private(set) var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var errorMessage: String?
    /// The Settings tab to show; the cheat sheet's Edit button jumps to "gestures".
    @Published var settingsTab = "gestures"

    var previewVisible = false {
        didSet { pipeline.wantsPreview = previewVisible && settings.showPreview }
    }

    private let pipeline: CameraPipeline
    private let hud = HUD()
    private var pendingScroll = 0.0
    private var cursor: CGPoint?
    private var permissionTimer: Timer?

    private init() {
        let s = Settings.load()
        settings = s
        pipeline = CameraPipeline(settings: s)
        pipeline.onFrame = { [weak self] out in
            DispatchQueue.main.async { self?.handle(out) }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    // MARK: Status

    var statusText: String {
        if let errorMessage { return errorMessage }
        if !running { return "Off" }
        if pointerMode { return "Pointer mode — hold three fingers to exit" }
        if awake { return settings.practiceMode ? "Listening (practice — nothing runs)" : "Listening" }
        return "Hold an open palm still to start"
    }

    var menuBarSymbol: String {
        if !running { return "hand.raised.slash" }
        if pointerMode { return "hand.point.up.left.fill" }
        return awake ? "hand.raised.fill" : "hand.raised"
    }

    // MARK: Camera

    func setRunning(_ on: Bool) {
        if on { start() } else { stop() }
    }

    func start() {
        refreshPermissions()
        switch cameraStatus {
        case .authorized:
            do {
                try pipeline.start(cameraID: settings.cameraID)
                running = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    self.refreshPermissions()
                    if self.cameraStatus == .authorized { self.start() }
                }
            }
        default:
            errorMessage = "Camera access is off — turn it on in Permissions"
        }
    }

    func stop() {
        pipeline.stop()
        running = false
        awake = false
        pointerMode = false
        pose = .none
        handVisible = false
        preview = nil
        joints = nil
    }

    private func restart() {
        stop()
        start()
    }

    func refreshPermissions() {
        let ax = Input.trusted
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        if cam != cameraStatus { cameraStatus = cam }
    }

    // MARK: Frames and events

    private func handle(_ out: FrameOutput) {
        guard running else { return }
        if pose != out.pose { pose = out.pose }
        if handVisible != out.handVisible { handVisible = out.handVisible }
        if awake != out.awake { awake = out.awake }
        if pointerMode != out.pointerMode { pointerMode = out.pointerMode }
        if previewVisible {
            joints = out.joints
            if let img = out.preview { preview = img }
        }
        for e in out.events { handle(e) }
    }

    private func handle(_ e: GestureEvent) {
        let dry = settings.practiceMode
        switch e {
        case .wake:
            sound("Tink")
            note("Listening", symbol: "hand.raised.fill", tint: .green)
        case .sleep:
            sound("Bottle")
            note("Paused", symbol: "hand.raised.slash", tint: .secondary)
        case .gesture(let rule):
            guard let label = ActionRunner.run(rule, dryRun: dry) else { return }
            sound("Pop")
            note(dry ? "\(rule.pose.emoji)  Would run: \(label)" : label, symbol: rule.action.symbol, tint: .accentColor)
        case .scroll(let px):
            pendingScroll += px
            if abs(pendingScroll) >= 1 {
                if !dry { Input.scroll(Int32(pendingScroll.rounded(.towardZero))) }
                pendingScroll -= pendingScroll.rounded(.towardZero)
            }
        case .volume(let step):
            if dry { note(step > 0 ? "Would turn volume up" : "Would turn volume down",
                          symbol: "speaker.wave.2.fill", tint: .accentColor) }
            else { Input.media(step > 0 ? .volumeUp : .volumeDown) }
        case .pointerOn:
            cursor = nil
            sound("Morse")
            note("Pointer on", symbol: "cursorarrow.motionlines", tint: .orange)
        case .pointerOff:
            sound("Morse")
            note("Pointer off", symbol: "cursorarrow", tint: .secondary)
        case .pointer(let p):
            guard !dry else { return }
            let margin = 0.2
            let x = min(max((Double(p.x) - margin) / (1 - 2 * margin), 0), 1)
            let y = min(max((Double(p.y) - margin) / (1 - 2 * margin), 0), 1)
            let size = Input.mainScreenSize
            let target = CGPoint(x: x * size.width, y: y * size.height)
            let k = settings.pointerSmoothing
            let next = cursor.map { CGPoint(x: $0.x * k + target.x * (1 - k), y: $0.y * k + target.y * (1 - k)) } ?? target
            cursor = next
            Input.moveCursor(to: next)
        }
    }

    /// An on-screen confirmation from outside the gesture pipeline (e.g. the on/off shortcut).
    func announce(_ text: String, symbol: String, tint: Color) {
        note(text, symbol: symbol, tint: tint)
    }

    private func note(_ text: String, symbol: String, tint: Color) {
        lastAction = text
        lastActionSymbol = symbol
        if settings.showHUD { hud.show(symbol: symbol, text: text, tint: tint) }
    }

    private func sound(_ name: String) {
        guard settings.sounds, let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = 0.35
        s.play()
    }

    // MARK: On / off shortcut

    static let defaultToggleShortcut = Shortcut(
        keyCode: 4, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, display: "⌃⌥H")

    /// The system-wide shortcut that turns Hand Gestures on and off; nil when removed.
    @Published var toggleShortcut: Shortcut? = AppState.loadToggleShortcut() {
        didSet {
            if let s = toggleShortcut, let data = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(data, forKey: "toggleShortcut")
            } else {
                UserDefaults.standard.set(Data(), forKey: "toggleShortcut")   // empty = removed
            }
        }
    }
    /// True while the Shortcut page is listening for keys, so the current shortcut doesn't fire.
    @Published var recordingShortcut = false
    /// Set when macOS refuses the shortcut (another app already uses it).
    @Published var shortcutProblem: String?

    private static func loadToggleShortcut() -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: "toggleShortcut") else { return defaultToggleShortcut }
        return data.isEmpty ? nil : (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? defaultToggleShortcut
    }

    // MARK: Dock icon

    /// On by default: on a MacBook with a notch, a crowded menu bar can hide the icon.
    var showInDock: Bool {
        get { UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "showInDock")
            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            if !newValue { NSApp.activate(ignoringOtherApps: true) }
            objectWillChange.send()
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
