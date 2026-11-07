import AVFoundation
import SwiftUI

/// The panes in the Settings sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, pointer, gestures, shortcut, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .pointer: "Pointer & Clicks"
        case .gestures: "Gestures"
        case .shortcut: "Keyboard Shortcut"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .pointer: "cursorarrow.rays"
        case .gestures: "hand.raised.fill"
        case .shortcut: "command"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .pointer: .blue
        case .gestures: .orange
        case .shortcut: .purple
        case .permissions: .green
        case .about: .indigo
        }
    }
}

/// Settings laid out like System Settings: a sidebar of panes, the pane on the right.
struct SettingsView: View {
    @ObservedObject var state: AppState
    var height: CGFloat = 640

    private var pane: SettingsPane { SettingsPane(rawValue: state.settingsTab) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPane?>(get: { pane }, set: { state.settingsTab = ($0 ?? .general).rawValue })) {
                ForEach(SettingsPane.allCases) { p in
                    Label { Text(p.title) } icon: { IconTile(symbol: p.symbol, tint: p.tint, size: 20) }
                        .tag(p)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 2)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 840, height: height)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralPane(state: state)
        case .pointer: PointerPane(state: state)
        case .gestures: GesturesPane(state: state)
        case .shortcut: ShortcutTab(state: state)
        case .permissions: PermissionsTab(state: state)
        case .about: AboutTab(updater: Updater.shared)
        }
    }
}

/// A white symbol on a coloured rounded square, as in System Settings.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var state: AppState
    @State private var cameras = CameraPipeline.cameras()
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker(selection: startStopPose) {
                    ForEach(Pose.usable) { p in Text("\(p.emoji)  \(p.title)").tag(p) }
                } label: {
                    Text("Start / stop shape")
                    Text("Hold this shape still to turn listening on or off.")
                }
                Toggle(isOn: $state.settings.startStopBothHands) {
                    Text("Use both hands")
                    Text("Show the shape with both hands at once, so one stray hand does nothing.")
                }
                SliderRow(title: "Hold to start / stop", value: $state.settings.wakeSeconds, range: 0.6...2.5,
                          low: "Quick", high: "Deliberate", format: "%.1f s")
                SliderRow(title: "Stop listening when no hand for", value: $state.settings.sleepAfterSeconds,
                          range: 10...180, low: "10 s", high: "3 min", format: "%.0f s")
                Toggle(isOn: $state.settings.pauseWhileTyping) {
                    Text("Pause while typing")
                    Text("Hands are ignored for a second after any key press, like a trackpad ignoring your palm.")
                }
            } header: {
                Text("Listening")
            }

            Section("Camera") {
                Picker("Camera", selection: cameraSelection) {
                    ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Toggle("Show the camera preview in the menu", isOn: $state.settings.showPreview)
            }

            Section("Feedback") {
                Toggle(isOn: $state.settings.showHUD) {
                    Text("On-screen confirmation")
                    Text("Briefly shows what each gesture did.")
                }
                Toggle("Sounds", isOn: $state.settings.sounds)
                Toggle(isOn: $state.settings.practiceMode) {
                    Text("Practice mode")
                    Text("Shows what a gesture would do, without doing it.")
                }
            }

            Section("App") {
                Toggle("Turn on when the app opens", isOn: $state.settings.startOnLaunch)
                Toggle("Open at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                Toggle(isOn: Binding(get: { state.showInDock }, set: { state.showInDock = $0 })) {
                    Text("Show in Dock")
                    Text("Handy when the menu bar icon is hidden behind the notch. Your keyboard shortcut works too.")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cameras = CameraPipeline.cameras() }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset All Settings", role: .destructive) {
                var fresh = Settings()
                fresh.onboarded = true
                fresh.cameraID = state.settings.cameraID
                state.settings = fresh
            }
        } message: {
            Text("Every setting and your gesture list go back to the recommended defaults. Your camera choice is kept.")
        }
    }

    private var cameraSelection: Binding<String?> {
        Binding(get: { state.settings.cameraID ?? CameraPipeline.pickCamera(nil)?.uniqueID },
                set: { state.settings.cameraID = $0 })
    }

    /// The shape of the start / stop gesture, which always exists.
    private var startStopPose: Binding<Pose> {
        Binding(get: { state.settings.startStopRule.pose }, set: { pose in
            if let i = state.settings.gestures.firstIndex(where: { $0.action == .startStop }) {
                state.settings.gestures[i].pose = pose
            }
        })
    }
}

// MARK: - Pointer & clicks

struct PointerPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $state.settings.handPointer) {
                    Text("☝️  Point to pick up the pointer")
                    Text("Point with your index finger and hold still for a moment; a ring shows your hand has the pointer. Move like a mouse: slowly for precision, quickly to go far. Lower your hand to let go. A relaxed or raised hand does nothing.")
                }
                if state.settings.handPointer {
                    SliderRow(title: "Speed", value: $state.settings.pointerSpeed, range: 0.4...2.5,
                              low: "Slow", high: "Fast", format: nil)
                    SliderRow(title: "Steadiness", value: $state.settings.pointerSmoothing, range: 0...0.85,
                              low: "Responsive", high: "Steady", format: nil)
                    Toggle("Show a ring around the pointer while your hand holds it", isOn: $state.settings.showPointerRing)
                }
            } header: {
                Text("Moving the pointer")
            }

            Section("Clicking") {
                Toggle(isOn: $state.settings.pinchGrab) {
                    Text("🤏  Pinch to click")
                    Text("While you hold the pointer, touch thumb and index: once to click, twice to double-click and open, pinch and move to drag pictures, files or windows. Touch thumb and middle finger, index still up, to right-click.")
                }
            }

            Section("Two hands") {
                Toggle(isOn: $state.settings.twoHandZoom) {
                    Text("🤏🤏  Pinch with both hands to expand")
                    Text("Pull your hands apart to expand, push them together to shrink.")
                }
                if state.settings.twoHandZoom {
                    Picker("Expanding", selection: $state.settings.twoHandResizesWindow) {
                        Text("Zooms in and out (⌘+ / ⌘−)").tag(false)
                        Text("Resizes the window under the pointer").tag(true)
                    }
                }
            }

            Section("Scrolling") {
                SliderRow(title: "Scroll speed", value: $state.settings.scrollSpeed, range: 1500...15000,
                          low: "Slow", high: "Fast", format: nil)
                Toggle("Reverse scroll direction", isOn: $state.settings.invertScroll)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures

/// The gesture list, grouped by hand shape: each line is a movement and what it does.
struct GesturesPane: View {
    @ObservedObject var state: AppState
    @State private var confirmReset = false
    @State private var adding: GestureRule?

    /// Shapes in the order they first appear in the list.
    private var shapes: [Pose] {
        var seen: [Pose] = []
        for r in state.settings.gestures where !seen.contains(r.pose) { seen.append(r.pose) }
        return seen
    }

    var body: some View {
        Form {
            if state.settings.offerRecommended { recommendedBanner }

            ForEach(shapes) { pose in
                Section {
                    ForEach(state.settings.gestures.filter { $0.pose == pose }) { rule in
                        GestureRow(rule: binding(for: rule), state: state)
                    }
                } header: {
                    HStack(spacing: 10) {
                        Text(pose.emoji).font(.title2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pose.title).font(.headline).foregroundStyle(.primary)
                            Text(pose.how).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .textCase(nil)
                }
            }

            Section {
                HStack {
                    Button {
                        adding = nextFreeRule()
                    } label: {
                        Label("Add Gesture…", systemImage: "plus")
                    }
                    Spacer()
                    Button("Restore Defaults…") { confirmReset = true }
                        .disabled(GestureRule.sameList(state.settings.gestures, GestureRule.defaults))
                }
            } footer: {
                Text("Swipe left means next / forward and swipe right means previous / back, like a phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Timing") {
                SliderRow(title: "Hold still for", value: $state.settings.holdSeconds, range: 0.3...1.5,
                          low: "Quick", high: "Deliberate", format: "%.1f s")
                SliderRow(title: "Swipe length", value: $state.settings.swipeDistance, range: 0.08...0.35,
                          low: "Short", high: "Long", format: nil)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $adding) { rule in
            AddGestureSheet(rule: rule, settings: state.settings) { state.settings.gestures.append($0) }
        }
        .confirmationDialog("Restore the recommended gestures?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) {
                state.settings.gestures = GestureRule.defaults
                state.settings.offerRecommended = false
            }
        } message: {
            Text("Your changes to the gesture list will be replaced.")
        }
    }

    private var recommendedBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new recommended set is ready").font(.body.weight(.semibold))
                    Text("It works like the trackpad: two fingers scroll and go back / forward, a whole hand swipes desktops, up for Mission Control, down for the app's windows. You kept your own list, so it hasn't been switched.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Use the Recommended Set") {
                            state.settings.gestures = GestureRule.defaults
                            state.settings.offerRecommended = false
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Keep Mine") { state.settings.offerRecommended = false }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A rule found by id, so a row stays valid while others are added or removed.
    private func binding(for rule: GestureRule) -> Binding<GestureRule> {
        Binding(get: { state.settings.gestures.first { $0.id == rule.id } ?? rule },
                set: { new in
                    if let i = state.settings.gestures.firstIndex(where: { $0.id == rule.id }) {
                        state.settings.gestures[i] = new
                    }
                })
    }

    /// A new line using the first shape not used for "hold still" yet.
    private func nextFreeRule() -> GestureRule {
        let used = Set(state.settings.gestures.filter { $0.motion == .hold }.map(\.pose))
        let pose = Pose.usable.first { !used.contains($0) } ?? .fist
        return GestureRule(pose: pose, motion: .hold, action: .none)
    }
}

/// One line of the list: the movement on the left, what it does on the right, and a
/// menu to change the shape or movement, or remove it.
struct GestureRow: View {
    @Binding var rule: GestureRule
    @ObservedObject var state: AppState

    /// Start / stop always exists and is always "hold still"; its shape is set in General.
    private var locked: Bool { rule.action == .startStop }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label {
                    Text(locked && state.settings.startStopBothHands ? "Hold still, both hands" : rule.motion.title)
                } icon: {
                    Image(systemName: rule.motion.symbol).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)

                if locked {
                    Label(ActionKind.startStop.title, systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Start / stop can't be removed, or there'd be no way to turn listening on. Change its shape in General.")
                } else {
                    if rule.action == .custom {
                        ShortcutRecorder(shortcut: $rule.shortcut)
                    }
                    ActionPicker(action: $rule.action, motion: rule.motion)
                    Menu {
                        Picker("Hand Shape", selection: $rule.pose) {
                            ForEach(Pose.usable) { p in Text("\(p.emoji)  \(p.title)").tag(p) }
                        }
                        Picker("Movement", selection: motion) {
                            ForEach(Motion.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                        }
                        Divider()
                        Button("Remove Gesture", role: .destructive) {
                            let id = rule.id
                            DispatchQueue.main.async { state.settings.gestures.removeAll { $0.id == id } }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Change the shape or movement, or remove this gesture")
                }
            }
            if let warning = state.settings.warning(for: rule) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Changing the movement drops an action that no longer fits it.
    private var motion: Binding<Motion> {
        Binding(get: { rule.motion }, set: { rule.motion = $0; rule.action = ActionPicker.fitting(rule.action, $0) })
    }
}

/// The actions that fit a movement, grouped.
struct ActionPicker: View {
    @Binding var action: ActionKind
    let motion: Motion

    var body: some View {
        Picker("Action", selection: $action) {
            ForEach(ActionKind.groups(for: motion), id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { a in Label(a.title, systemImage: a.symbol).tag(a) }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    static func fitting(_ action: ActionKind, _ motion: Motion) -> ActionKind {
        if ActionKind.groups(for: motion).flatMap(\.1).contains(action) { return action }
        return motion == .moveUpDown ? .scroll : .none
    }
}

/// Builds a new gesture: shape, movement, action.
struct AddGestureSheet: View {
    @State var rule: GestureRule
    let settings: Settings
    let add: (GestureRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a Gesture").font(.headline).padding([.horizontal, .top], 20)
            Form {
                Picker("Hand shape", selection: $rule.pose) {
                    ForEach(Pose.usable) { p in Text("\(p.emoji)  \(p.title)").tag(p) }
                }
                Picker("Movement", selection: Binding(get: { rule.motion }, set: {
                    rule.motion = $0
                    rule.action = ActionPicker.fitting(rule.action, $0)
                })) {
                    ForEach(Motion.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                }
                LabeledContent("Does") { ActionPicker(action: $rule.action, motion: rule.motion) }
                if rule.action == .custom {
                    LabeledContent("Shortcut") { ShortcutRecorder(shortcut: $rule.shortcut) }
                }
                if let warning = previewWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.action == .none || taken)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }

    /// This shape and movement already do something.
    private var taken: Bool {
        settings.gestures.contains { $0.pose == rule.pose && $0.motion == rule.motion }
    }

    private var previewWarning: String? {
        if taken { return "\(rule.pose.title) · \(rule.motion.title.lowercased()) is already in your list. Pick another shape or movement." }
        var s = settings
        s.gestures.append(rule)
        return s.warning(for: rule)
    }
}

/// Click, then press the keys to record a shortcut.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (shortcut?.display ?? "Record Shortcut")) {
            recording ? stop() : start()
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 && mods.isEmpty { stop(); return nil }   // Esc cancels
            shortcut = Shortcut(keyCode: e.keyCode, modifiers: mods.rawValue,
                                display: Input.describe(keyCode: e.keyCode, modifiers: mods,
                                                        characters: e.charactersIgnoringModifiers))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Title (and value) on the left, a slider between its two end labels on the right.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let format: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(low).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
                Slider(value: $value, in: range).labelsHidden().frame(width: 190)
                Text(high).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .leading)
            }
        } label: {
            Text(title)
            if let format { Text(String(format: format, value)).monospacedDigit() }
        }
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Camera", symbol: "camera.fill", tint: .blue,
                    detail: "To see your hands. Video is processed on this Mac and never saved or sent anywhere.",
                    granted: state.cameraStatus == .authorized,
                    actionTitle: state.cameraStatus == .notDetermined ? "Allow…" : "Open Settings",
                    action: {
                        if state.cameraStatus == .notDetermined { state.start() }
                        else { Permissions.openCameraSettings() }
                    })
                PermissionRow(
                    title: "Accessibility", symbol: "accessibility", tint: .indigo,
                    detail: "To press shortcuts, scroll, change volume and move the pointer for you.",
                    granted: state.accessibilityGranted,
                    actionTitle: "Open Settings",
                    action: { Input.askForAccessibility(); Permissions.openAccessibilitySettings() })
            } footer: {
                Text("Updates are signed with the same certificate, so macOS keeps both permissions after updating.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        }
        .padding(.vertical, 2)
    }
}

enum Permissions {
    static func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
