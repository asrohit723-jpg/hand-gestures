import SwiftUI

/// Settings › Keyboard Shortcut: the system-wide key that turns Hand Gestures on and off.
struct ShortcutTab: View {
    @ObservedObject var state: AppState
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: "command", tint: .purple, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Turn Hand Gestures on and off")
                        Text("Press once to turn it on and open the window. Press again to turn it off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    recorder
                }
                .padding(.vertical, 4)

                if state.recordingShortcut {
                    Text("Press the new shortcut — include ⌘, ⌥ or ⌃. Esc cancels.")
                        .font(.caption).foregroundStyle(Color.accentColor)
                } else if let hint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                } else if let problem = state.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Works from any app, even when the menu bar icon is hidden behind the notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset to \(AppState.defaultToggleShortcut.display)") {
                        stopRecording()
                        state.toggleShortcut = AppState.defaultToggleShortcut
                    }
                    .disabled(state.toggleShortcut == AppState.defaultToggleShortcut)
                    Spacer()
                    Button("Remove Shortcut", role: .destructive) {
                        stopRecording()
                        state.toggleShortcut = nil
                    }
                    .disabled(state.toggleShortcut == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopRecording)
    }

    private var recorder: some View {
        Button {
            state.recordingShortcut ? stopRecording() : startRecording()
        } label: {
            Text(state.recordingShortcut ? "Press keys…" : (state.toggleShortcut?.display ?? "Record shortcut"))
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(state.recordingShortcut ? .accentColor : nil)
    }

    private func startRecording() {
        hint = nil
        state.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 && mods.isEmpty {          // Esc cancels
                stopRecording()
                return nil
            }
            guard !mods.intersection([.command, .option, .control]).isEmpty else {
                hint = "Add ⌘, ⌥ or ⌃ so the shortcut doesn't get in the way of typing."
                return nil
            }
            hint = nil
            state.toggleShortcut = Shortcut(
                keyCode: e.keyCode, modifiers: mods.rawValue,
                display: Input.describe(keyCode: e.keyCode, modifiers: mods, characters: e.charactersIgnoringModifiers))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if state.recordingShortcut { state.recordingShortcut = false }
    }
}
