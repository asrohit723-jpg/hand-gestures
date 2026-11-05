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
    @Published private(set) var pose: Pose = .none
    @Published private(set) var handVisible = false
    @Published private(set) var lastAction: String?
    @Published private(set) var lastActionSymbol = "hand.raised"
    @Published private(set) var preview: CGImage?
    @Published private(set) var joints: [[CGPoint]]?
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
    private var mouseDown = false
    private var pressPoint = CGPoint.zero          // where a pinch clicks / starts a drag
    private var handBase: CGPoint?                 // filtered palm position the last move was measured from
    private var lastAim = 0.0
    private var frozen = false                     // fingers closed: the pointer holds still
    private var aimTrail: [(t: Double, p: CGPoint)] = []
    private let ring = PointerRing()
    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
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
        if awake { return settings.practiceMode ? "Listening (practice — nothing runs)" : "Listening" }
        let shape = settings.startStopRule.pose.title.lowercased()
        return settings.startStopBothHands ? "Show \(shape) on both hands, still, to start" : "Hold \(shape) still to start"
    }

    var menuBarSymbol: String {
        if !running { return "hand.raised.slash" }
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
        if mouseDown { Input.mouse(.leftMouseUp, at: Input.mouseLocation); mouseDown = false }
        ring.hide()
        WindowResizer.end()
        running = false
        awake = false
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
            if rule.action == .pointer {
                settings.handPointer.toggle()
                sound("Morse")
                note(settings.handPointer ? "Hand pointer on" : "Hand pointer off", symbol: "cursorarrow.motionlines",
                     tint: settings.handPointer ? .orange : .secondary)
                return
            }
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

        case .engage:
            handBase = nil            // movement starts from here: the pointer never jumps
            if settings.showPointerRing { ring.show(at: Input.mouseLocation) }
        case .release:
            handBase = nil
            frozen = false
            ring.hide()
        case .aim(let p):
            aim(by: p)                // moves in practice mode too, so pointing can be learned
        case .pinchDown:
            // Click where the pointer was a moment before the fingers closed.
            let now = CACurrentMediaTime()
            pressPoint = aimTrail.last(where: { now - $0.t >= 0.1 })?.p ?? Input.mouseLocation
            frozen = true
            ring.setPressed(true)
            if pressPoint != Input.mouseLocation { Input.moveCursor(to: pressPoint); ring.move(to: pressPoint) }
        case .click(let count):
            unfreeze()
            if dry { note(count == 2 ? "🤏🤏  Would double-click" : "🤏  Would click", symbol: "cursorarrow.click", tint: .accentColor); return }
            Input.click(at: pressPoint, count: count)
        case .rightClick:
            unfreeze()
            if dry { note("🤏  Would right-click", symbol: "contextualmenu.and.cursorarrow", tint: .accentColor); return }
            sound("Pop")
            Input.rightClick(at: pressPoint)
        case .dragStart:
            frozen = false
            handBase = nil            // carry on from the press point, no jump
            if dry { note("🤏  Would drag", symbol: "hand.pinch.fill", tint: .accentColor); return }
            Input.mouse(.leftMouseDown, at: pressPoint)
            mouseDown = true
        case .dragEnd:
            unfreeze()
            guard mouseDown else { return }
            Input.mouse(.leftMouseUp, at: Input.mouseLocation)
            mouseDown = false

        case .zoomStart:
            if settings.twoHandResizesWindow && !dry {
                if !WindowResizer.begin(at: Input.mouseLocation) {
                    note("No window under the pointer to resize", symbol: "macwindow", tint: .secondary)
                }
            } else {
                note(dry ? "🤏🤏  Would zoom" : "Zoom", symbol: "arrow.up.left.and.arrow.down.right", tint: .accentColor)
            }
        case .zoom(let step):
            guard !dry else { return }
            Input.press(step > 0 ? Input.Key.equal : Input.Key.minus, [.cmd])
        case .scale(let factor):
            guard !dry else { return }
            WindowResizer.scale(factor)
        case .zoomEnd:
            WindowResizer.end()
        }
    }

    private func unfreeze() {
        frozen = false
        handBase = nil
        ring.setPressed(false)
    }

    /// Moves the pointer by how far the palm moved since the last frame, like a mouse:
    /// slow moves are precise, quick moves go far. The palm position is filtered first
    /// (One Euro: steady when still, quick when moving) and tiny wobbles are ignored.
    private func aim(by p: CGPoint) {
        let now = CACurrentMediaTime()
        let minCutoff = max(0.3, 2.5 * (1 - settings.pointerSmoothing))
        filterX.minCutoff = minCutoff; filterY.minCutoff = minCutoff
        filterX.beta = 8; filterY.beta = 8          // palm units are 0...1 of the frame
        guard let base = handBase else {
            filterX.reset(to: Double(p.x)); filterY.reset(to: Double(p.y))
            handBase = p
            lastAim = now
            return
        }
        let hand = CGPoint(x: filterX.filter(Double(p.x), at: now), y: filterY.filter(Double(p.y), at: now))
        let dx = Double(hand.x - base.x), dy = Double(hand.y - base.y)
        let distance = hypot(dx, dy)
        guard !frozen, distance > 0.0015 else { return }    // a resting hand's wobble builds up instead of moving
        let speed = distance / max(now - lastAim, 1.0 / 60)
        handBase = hand
        lastAim = now

        // Acceleration: about 0.6x the screen width per frame-width at a slow move, up to 3x when quick.
        let gain = settings.pointerSpeed * (0.6 + min(speed / 0.6, 2.4))
        let width = Double(Input.mainScreenSize.width)
        let from = Input.mouseLocation
        let b = Input.desktopBounds
        let to = CGPoint(x: min(max(from.x + dx * width * gain, b.minX), b.maxX - 1),
                         y: min(max(from.y + dy * width * gain, b.minY), b.maxY - 1))
        aimTrail.append((now, to))
        aimTrail.removeAll { now - $0.t > 0.5 }
        if mouseDown { Input.mouse(.leftMouseDragged, at: to) } else { Input.moveCursor(to: to) }
        ring.move(to: to)
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
