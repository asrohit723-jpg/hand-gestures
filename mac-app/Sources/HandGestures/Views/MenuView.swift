import SwiftUI

/// The dropdown under the menu bar icon.
struct MenuView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared
    var openSettings: () -> Void
    var openWelcome: () -> Void
    @State private var showCheatSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            UpdateBanner(updater: updater)

            if !state.accessibilityGranted || state.cameraStatus == .denied || state.cameraStatus == .restricted {
                PermissionBanner(state: state, openWelcome: openWelcome)
            }

            if state.running && state.settings.showPreview {
                CameraPreview(state: state)
                    .frame(height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if state.running { liveStatus }

            DisclosureGroup(isExpanded: $showCheatSheet) {
                CheatSheet(settings: state.settings, onEdit: { state.settingsTab = "gestures"; openSettings() })
                    .padding(.top, 6)
            } label: {
                Text("Gesture cheat sheet").font(.callout.weight(.medium))
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Practice mode")
                    Text("Show what a gesture would do, without doing it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Practice mode", isOn: $state.settings.practiceMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            HStack {
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { state.previewVisible = true }
        .onDisappear { state.previewVisible = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(state.awake ? Color.green.gradient : Color.accentColor.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: state.menuBarSymbol)
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Hand Gestures").font(.headline)
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(state.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { state.running }, set: { state.setRunning($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(state.running ? "Turn the camera off" : "Turn the camera on")
        }
    }

    private var liveStatus: some View {
        HStack(spacing: 8) {
            Label {
                Text(state.handVisible ? state.pose.title : "No hand in view")
            } icon: {
                Text(state.handVisible ? state.pose.emoji : "🫥")
            }
            .font(.callout)
            Spacer()
            if let last = state.lastAction {
                Label(last, systemImage: state.lastActionSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

struct PermissionBanner: View {
    @ObservedObject var state: AppState
    var openWelcome: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.accessibilityGranted ? "Camera access needed" : "Accessibility access needed")
                    .font(.callout.weight(.semibold))
                Text(state.accessibilityGranted
                     ? "Hand Gestures can't see your hand without the camera."
                     : "Gestures are recognised but can't press keys until you allow this.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Set up permissions…", action: openWelcome)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Every gesture and what it currently does.
struct CheatSheet: View {
    let settings: Settings
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if settings.handPointer { row("✋", "Relaxed hand or point · move", "Move the pointer") }
            if settings.pinchGrab {
                row("🤏", "Pinch", "Click")
                row("🤏", "Pinch twice", "Double-click")
                row("🤏", "Pinch and hold still", "Right-click")
                row("🤏", "Pinch and move", "Drag")
            }
            if settings.twoHandZoom {
                row("🤏🤏", "Both hands pinch · apart / together",
                    settings.twoHandResizesWindow ? "Resize window" : "Zoom in / out")
            }
            Divider().padding(.vertical, 2)
            ForEach(settings.gestures.filter { $0.action != .none }) { rule in
                HStack(spacing: 8) {
                    Text(rule.action == .startStop && settings.startStopBothHands ? rule.pose.emoji + rule.pose.emoji : rule.pose.emoji)
                        .fixedSize().frame(minWidth: 22)
                    Text(rule.gestureTitle(in: settings)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(rule.actionTitle).multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit gestures…", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.top, 4)
            }
        }
    }

    private func row(_ emoji: String, _ gesture: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(emoji).fixedSize().frame(minWidth: 22)
            Text(gesture).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(action).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
