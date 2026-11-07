# Hand gestures for macOS

**Use the app:** `~/Applications/Hand Gestures.app`. It lives in the menu bar and the Dock;
open it from Spotlight or with ⌃⌥H. Gestures are set in its Settings window. The source is in
`mac-app/`.

### Gestures (recommended set)

The app copies what people already know: the trackpad and Vision Pro.

| Gesture | Does |
|---|---|
| ✋✋ Both palms open, held still | Start / stop listening |
| ☝️ Point and hold still a moment | Pick up the pointer (a ring appears) |
| ☝️ Point and move | Move the pointer, like a mouse: slow = precise, quick = far |
| 👇 Lower your hand or change shape | Let go (the pointer stays put) |
| 🤏 Pinch thumb and index, while holding the pointer | Click (however long you hold it) |
| 🤏 Pinch twice | Double-click (opens files and apps) |
| Thumb to middle finger, index still up | Right-click |
| 🤏 Pinch and move | Drag (files, windows, across screens) |
| 🤏🤏 Both hands pinch, apart / together | Zoom in / out (or resize the window) |
| ✌️ Two fingers, move up / down | Scroll |
| ✌️ Two fingers, swipe right / left | Back / forward |
| ✋ Palm swipe left / right | Next / previous desktop |
| ✋ Palm swipe up / down | Mission Control / app windows |
| 👍 Thumbs up, hold | Dictation on / off (Wispr) |
| 🤘 Rock sign, hold | Paste last dictation + Enter |
| ✊ Fist, hold | Escape |
| 3️⃣ Three fingers, hold | Play / pause |
| 🤙 Shaka, hold | Switch to last app |
| 📸 L shape, hold | Screenshot an area |
| 👌 OK sign, move up / down | Volume |

A relaxed or raised hand never moves the pointer, and hands are ignored for a second after any key press. Everything except the pointer and pinch can be changed in Settings › Gestures; the pointer, clicks and scrolling are tuned in Settings › Pointer & Clicks.

### Updating

Push a change under `mac-app/` to `main`. GitHub Actions
(`.github/workflows/release.yml`) tests it, builds it, signs it with the app's own certificate
and publishes a release `v1.0.<run>`. The app checks GitHub every few hours, and you can also
use Settings › About › Check Now. It then shows **Update now**, which swaps the app in place and
relaunches. Every release is signed with the same certificate, so macOS keeps Camera and
Accessibility access, and the app refuses any download not signed with it.

- **Certificate:** made once with `mac-app/scripts/make-signing-cert.sh`. The private key lives in
  `~/.hand-gestures-signing/` and in the repo secrets `MAC_P12` and `MAC_P12_PASSWORD`. Keep that
  folder. With a new certificate, the next update would need permissions granted again.
- **Local builds:** `mac-app/build.sh` makes ad-hoc signed builds (version 0.0.0) for trying
  changes. Installing one replaces the signed app, so macOS asks for permissions again until the
  next update.

## Python prototype

The original prototype, kept for reference. It needs the hand model:
`curl -L -o models/hand_landmarker.task https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task`


Control the Mac with hand gestures from the built-in camera. Everything runs on the Mac:
MediaPipe finds 21 points on your hand, simple rules turn them into poses and swipes, and
`config.yaml` decides what each one does.

## Start it

```bash
~/hand-gestures/.venv/bin/hand-gestures --preview
```

Or double-click **Hand Gestures.command** in Finder. Run it from macOS **Terminal** (not from
inside Claude). The first time, allow both of these for Terminal under System Settings >
Privacy & Security, then restart Terminal:

- **Camera**, so it can see your hand.
- **Accessibility**, so it can press keys and move the cursor.

Options:

- `--preview` shows the camera with the detected pose. Press `q` to close.
- `--dry-run` prints what would happen and performs nothing. Use it while you learn the gestures.

## Gestures

First, **hold an open palm still for about a second** to start listening (you hear a *tink*). Do
the same to stop listening. It also stops by itself after 30 seconds with no hand in view.

Swipe left means next or forward and swipe right means previous or back, like a phone.

| Gesture | Action |
|---|---|
| 👍 Thumbs up, hold | Wispr Flow hands-free dictation on/off (Fn+Space) |
| 🤘 Index + pinky up, hold | Paste the last Wispr transcript, then Enter |
| ☝️ Point, then move the hand up/down | Scroll; the further you move, the faster it scrolls |
| ✋ Palm swipe left / right | Next / previous browser tab, slide (Keynote, PowerPoint, Preview) or skip in a video (QuickTime, IINA, VLC) |
| ✋ Palm swipe down | Reload (Cmd+R) |
| ✋ Palm swipe up | Mission Control |
| ✌️ V swipe left / right | Next / previous desktop |
| 🤙 Thumb + pinky out, hold | Switch to the last app (Cmd+Tab) |
| 👆👍 L shape (thumb + index), hold | Screenshot an area to the clipboard |
| 🤟 Three fingers, hold | Laser pointer on/off: your index fingertip moves the cursor |
| ✊ Fist, hold | Play / pause |
| 👌 OK sign, then raise/lower the hand | Volume up / down |

In pointer mode every other gesture is paused until you hold three fingers again.

## Change things

Edit `config.yaml` and restart:

- **Swap an action:** for example, set `fist` to `{keys: "cmd+w"}`.
- **Add an action:** use `{shell: ...}` or `{applescript: ...}`.
- **Add an app** to the swipe `by_app` lists.
- **Tune it:**
  - the `seconds` of a hold
  - the swipe `distance`
  - `scroll.speed` (set `scroll.invert: true` if scrolling goes the wrong way)
  - `pointer.smoothing`

## Tests

```bash
.venv/bin/python -m unittest discover tests
```

The tests feed synthetic hands through the pose rules and the gesture state machine, so they
check the logic, not the camera.

## Files

- `handgestures/poses.py`: which fingers are up gives the pose.
- `handgestures/recognizer.py`: arming, holds, swipes, scroll, volume and pointer, over time.
- `handgestures/macos.py`: key combos, media keys, scroll, cursor and the frontmost app.
- `handgestures/actions.py`: runs the actions named in `config.yaml`.
- `handgestures/main.py`: the camera loop.
- `models/hand_landmarker.task`: Google's MediaPipe hand model.
