import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GesturesTab(state: state)
                .tabItem { Label("Gestures", systemImage: "hand.raised") }
            FeelTab(state: state)
                .tabItem { Label("Camera & Feel", systemImage: "slider.horizontal.3") }
            PermissionsTab(state: state)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutTab(updater: Updater.shared)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: - Gestures

struct GesturesTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                ForEach(Trigger.holds) { GestureRow(trigger: $0, state: state) }
            } header: {
                Text("Hold still")
            } footer: {
                Text("Hold the shape still for about \(String(format: "%.1f", state.settings.holdSeconds)) s.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Trigger.swipes) { GestureRow(trigger: $0, state: state) }
            } header: {
                Text("Swipe")
            } footer: {
                Text("“Next” and “Previous” switch tabs in browsers, slides in Keynote, PowerPoint and Preview, and skip in QuickTime, IINA and VLC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Built in") {
                FixedRow(emoji: "✋", title: "Open palm", how: "Hold still to start or stop listening", value: nil)
                FixedRow(emoji: "☝️", title: "Point", how: "Then move your hand up or down to scroll",
                         value: $state.settings.scrollEnabled)
                FixedRow(emoji: "👌", title: "OK sign", how: "Then raise or lower your hand for volume",
                         value: $state.settings.volumeEnabled)
                FixedRow(emoji: "3️⃣", title: "Three fingers", how: "Hold to turn the laser pointer on or off",
                         value: $state.settings.pointerEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct GestureRow: View {
    let trigger: Trigger
    @ObservedObject var state: AppState

    private var binding: Binding<GestureBinding> {
        Binding(get: { state.settings.binding(trigger) },
                set: { state.settings.bindings[trigger.rawValue] = $0 })
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(trigger.emoji).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.title)
                Text(trigger.how).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if binding.wrappedValue.action == .custom {
                ShortcutRecorder(shortcut: binding.shortcut)
            }
            Picker("", selection: binding.action) {
                ForEach(ActionKind.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { a in
                            Label(a.title, systemImage: a.symbol).tag(a)
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct FixedRow: View {
    let emoji: String
    let title: String
    let how: String
    let value: Binding<Bool>?

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(how).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let value { Toggle("", isOn: value).labelsHidden().toggleStyle(.switch) }
            else { Text("Always on").font(.caption).foregroundStyle(.secondary) }
        }
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
                Text("Open Hand Gestures from the Dock, from Spotlight, or with ⌃⌥H anywhere — handy when the menu bar icon is hidden behind the notch.")
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
