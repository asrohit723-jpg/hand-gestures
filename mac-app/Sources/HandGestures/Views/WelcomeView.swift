import SwiftUI

/// First-run setup: camera, accessibility, then a live "try it".
struct WelcomeView: View {
    @ObservedObject var state: AppState
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Hand Gestures").font(.title2.weight(.semibold))
                    Text("Control your Mac with your hand. It lives in the menu bar.")
                        .foregroundStyle(.secondary)
                }
            }

            Step(number: 1, title: "Let it see your hand",
                 detail: "Camera video is processed on this Mac and never saved or sent anywhere.",
                 done: state.cameraStatus == .authorized) {
                Button(state.cameraStatus == .notDetermined ? "Allow camera" : "Open Settings") {
                    if state.cameraStatus == .notDetermined { state.start() } else { Permissions.openCameraSettings() }
                }
            }

            Step(number: 2, title: "Let it press keys for you",
                 detail: "Turn on Hand Gestures under Privacy & Security › Accessibility. This tick updates by itself.",
                 done: state.accessibilityGranted) {
                Button("Open Accessibility") {
                    Input.askForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }

            Step(number: 3, title: "Try it",
                 detail: "Raise your hand, palm to the camera, and hold it still for a second. You'll hear a tick.",
                 done: state.awake) {
                EmptyView()
            }

            if state.cameraStatus == .authorized {
                CameraPreview(state: state)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onAppear {
                        if !state.running { state.start() }
                        state.previewVisible = true
                    }
            }

            HStack {
                Text("Permissions are also in Settings › Permissions.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(state.awake ? "Done" : "Skip for now", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct Step<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { action() }
        }
    }
}
