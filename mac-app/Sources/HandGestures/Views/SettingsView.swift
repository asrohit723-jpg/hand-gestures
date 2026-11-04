import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView(selection: $state.settingsTab) {
            GesturesTab(state: state)
                .tabItem { Label("Gestures", systemImage: "hand.raised") }
                .tag("gestures")
            FeelTab(state: state)
                .tabItem { Label("Camera & Feel", systemImage: "slider.horizontal.3") }
                .tag("feel")
            PermissionsTab(state: state)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag("permissions")
            ShortcutTab(state: state)
                .tabItem { Label("Shortcut", systemImage: "command") }
                .tag("shortcut")
            AboutTab(updater: Updater.shared)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 760, height: 620)
    }
}

// MARK: - Gestures

/// The gesture list: every line is a hand shape, a movement and an action.
struct GesturesTab: View {
    @ObservedObject var state: AppState
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                ForEach($state.settings.gestures) { $rule in
                    GestureEditorRow(rule: $rule, state: state)
                }
                Button {
                    state.settings.gestures.append(nextFreeRule())
                } label: {
                    Label("Add gesture", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Hold gestures need the shape held still for about \(String(format: "%.1f", state.settings.holdSeconds)) s; start / stop needs \(String(format: "%.1f", state.settings.wakeSeconds)) s. “Next” and “Previous” switch tabs in browsers, slides in Keynote, PowerPoint and Preview, and skip in QuickTime, IINA and VLC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PinchRow(emoji: "🤏", title: "Pinch to grab",
                         detail: "Touch thumb and index to press on whatever is under the pointer. Keep pinching and move your hand to drag pictures, files or windows — even onto another screen. Open your fingers to let go. A quick pinch is a click.",
                         isOn: $state.settings.pinchGrab)
                if state.settings.pinchGrab {
                    SliderRow(title: "Drag speed", value: $state.settings.dragSpeed, range: 0.4...3,
                              low: "Precise", high: "Fast", format: nil)
                }
                PinchRow(emoji: "🤏🤏", title: "Two-hand pinch to expand",
                         detail: "Pinch with both hands, then pull them apart to expand or push them together to shrink.",
                         isOn: $state.settings.twoHandZoom)
                if state.settings.twoHandZoom {
                    Picker("Expanding", selection: $state.settings.twoHandResizesWindow) {
                        Text("Zooms in and out (⌘+ / ⌘−)").tag(false)
                        Text("Resizes the window under the pointer").tag(true)
                    }
                }
            } header: {
                Text("Pinch, like Vision Pro")
            } footer: {
                Text("Aim with the trackpad, or turn on the laser pointer so your hand moves the pointer, then pinch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Back to the original gestures")
                    Spacer()
                    Button("Restore defaults") { confirmReset = true }
                        .disabled(state.settings.gestures == GestureRule.defaults)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore the original gestures?", isPresented: $confirmReset) {
            Button("Restore defaults", role: .destructive) { state.settings.gestures = GestureRule.defaults }
        } message: {
            Text("Your changes to the gesture list will be replaced.")
        }
    }

    /// A new line using the first shape not used for "hold still" yet.
    private func nextFreeRule() -> GestureRule {
        let used = Set(state.settings.gestures.filter { $0.motion == .hold }.map(\.pose))
        let pose = Pose.usable.first { !used.contains($0) } ?? .fist
        return GestureRule(pose: pose, motion: .hold, action: .none)
    }
}

struct PinchRow: View {
    let emoji: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(emoji).font(.title2).fixedSize().frame(minWidth: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}

struct GestureEditorRow: View {
    @Binding var rule: GestureRule
    @ObservedObject var state: AppState

    /// Start / stop can move to another shape, but always exists and is always "hold still".
    private var locked: Bool { rule.action == .startStop }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(rule.pose.emoji).font(.title2).frame(width: 30)

                Picker("Shape", selection: $rule.pose) {
                    ForEach(Pose.usable) { p in Text(p.title).tag(p) }
                }
                .labelsHidden().fixedSize()
                .frame(width: 140, alignment: .leading)
                .help(rule.pose.how)

                if locked {
                    Text(Motion.hold.title).foregroundStyle(.secondary).padding(.horizontal, 6)
                        .frame(width: 140, alignment: .leading)
                } else {
                    Picker("Movement", selection: motion) {
                        ForEach(Motion.allCases) { m in Text(m.title).tag(m) }
                    }
                    .labelsHidden().fixedSize()
                    .frame(width: 140, alignment: .leading)
                }

                Image(systemName: "arrow.right").foregroundStyle(.tertiary)

                if locked {
                    Label(ActionKind.startStop.title, systemImage: ActionKind.startStop.symbol)
                        .padding(.horizontal, 6)
                } else {
                    Picker("Action", selection: $rule.action) {
                        ForEach(ActionKind.groups(for: rule.motion), id: \.0) { group in
                            Section(group.0) {
                                ForEach(group.1) { a in Label(a.title, systemImage: a.symbol).tag(a) }
                            }
                        }
                    }
                    .labelsHidden().fixedSize()
                    if rule.action == .custom {
                        ShortcutRecorder(shortcut: $rule.shortcut)
                    }
                }

                Spacer(minLength: 4)

                if locked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Start / stop can't be removed, or there'd be no way to turn listening on. You can change its shape.")
                } else {
                    Button {
                        let id = rule.id
                        DispatchQueue.main.async { state.settings.gestures.removeAll { $0.id == id } }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this gesture")
                }
            }
            if let warning = state.settings.warning(for: rule) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 2)
    }

    /// Changing the movement drops an action that no longer fits it.
    private var motion: Binding<Motion> {
        Binding(get: { rule.motion }, set: { m in
            rule.motion = m
            let allowed = ActionKind.groups(for: m).flatMap(\.1)
            if !allowed.contains(rule.action) { rule.action = m == .moveUpDown ? .scroll : .none }
        })
    }
}

/// Click, then press the keys to record a shortcut.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (shortcut?.display ?? "Record")) {
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

// MARK: - Camera & feel

struct FeelTab: View {
    @ObservedObject var state: AppState
    @State private var cameras = CameraPipeline.cameras()

    var body: some View {
        Form {
            Section {
                Toggle("Show in Dock", isOn: Binding(get: { state.showInDock }, set: { state.showInDock = $0 }))
            } header: {
                Text("App")
            } footer: {
                Text("Open Hand Gestures from the Dock, from Spotlight, or with your shortcut (Settings › Shortcut) — handy when the menu bar icon is hidden behind the notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Camera") {
                Picker("Camera", selection: cameraSelection) {
                    ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Toggle("Show camera preview in the menu", isOn: $state.settings.showPreview)
                Toggle("Turn on when the app opens", isOn: $state.settings.startOnLaunch)
                Toggle("Open at login", isOn: Binding(get: { state.launchAtLogin },
                                                      set: { state.launchAtLogin = $0 }))
            }
            Section("Feedback") {
                Toggle("On-screen confirmation", isOn: $state.settings.showHUD)
                Toggle("Sounds", isOn: $state.settings.sounds)
                Toggle("Practice mode — show what would happen, do nothing", isOn: $state.settings.practiceMode)
            }
            Section("Feel") {
                SliderRow(title: "Hold time", value: $state.settings.holdSeconds, range: 0.3...1.5,
                          low: "Quick", high: "Deliberate", format: "%.1f s")
                SliderRow(title: "Palm hold to start / stop", value: $state.settings.wakeSeconds, range: 0.6...2.5,
                          low: "Quick", high: "Deliberate", format: "%.1f s")
                SliderRow(title: "Swipe length", value: $state.settings.swipeDistance, range: 0.08...0.35,
                          low: "Short", high: "Long", format: nil)
                SliderRow(title: "Scroll speed", value: $state.settings.scrollSpeed, range: 1500...15000,
                          low: "Slow", high: "Fast", format: nil)
                Toggle("Reverse scroll direction", isOn: $state.settings.invertScroll)
                SliderRow(title: "Pointer steadiness", value: $state.settings.pointerSmoothing, range: 0...0.85,
                          low: "Responsive", high: "Steady", format: nil)
                SliderRow(title: "Stop listening after no hand for", value: $state.settings.sleepAfterSeconds,
                          range: 10...180, low: "10 s", high: "3 min", format: "%.0f s")
            }
            Section {
                Button("Restore defaults") {
                    var fresh = Settings()
                    fresh.onboarded = true
                    fresh.cameraID = state.settings.cameraID
                    state.settings = fresh
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cameras = CameraPipeline.cameras() }
    }

    private var cameraSelection: Binding<String?> {
        Binding(get: { state.settings.cameraID ?? CameraPipeline.pickCamera(nil)?.uniqueID },
                set: { state.settings.cameraID = $0 })
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let format: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if let format { Text(String(format: format, value)).foregroundStyle(.secondary).monospacedDigit() }
            }
            Slider(value: $value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
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
                    title: "Camera", symbol: "camera.fill",
                    detail: "To see your hand. Video is processed on this Mac and never saved or sent anywhere.",
                    granted: state.cameraStatus == .authorized,
                    actionTitle: state.cameraStatus == .notDetermined ? "Allow…" : "Open Settings",
                    action: {
                        if state.cameraStatus == .notDetermined { state.start() }
                        else { Permissions.openCameraSettings() }
                    })
                PermissionRow(
                    title: "Accessibility", symbol: "keyboard.fill",
                    detail: "To press shortcuts, scroll, change volume and move the pointer for you.",
                    granted: state.accessibilityGranted,
                    actionTitle: "Open Settings",
                    action: { Input.askForAccessibility(); Permissions.openAccessibilitySettings() })
            } footer: {
                Text("If you rebuild or move the app, macOS may ask for Accessibility again: remove Hand Gestures from the list with −, then add it back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let symbol: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(granted ? .green : .red)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(actionTitle, action: action) }
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
