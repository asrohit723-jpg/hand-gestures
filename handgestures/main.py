"""Camera loop: read frames, find the hand, recognise gestures, run actions.

  python -m handgestures            run quietly in the background
  python -m handgestures --preview  show the camera with the detected pose
  python -m handgestures --dry-run  print actions instead of performing them
"""
import argparse
import os
import sys
import time

import cv2
import mediapipe as mp
import numpy as np
import yaml
from mediapipe.tasks.python import BaseOptions, vision

from . import macos
from .actions import Actions
from .poses import classify
from .recognizer import Hand, Recognizer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, "models", "hand_landmarker.task")
CONNECTIONS = [(c.start, c.end) for c in vision.HandLandmarksConnections.HAND_CONNECTIONS]


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def to_hand(landmarks, aspect):
    pts = np.array([[lm.x, lm.y, lm.z] for lm in landmarks])
    scaled = pts * [aspect, 1.0, aspect]        # make x and y the same unit
    center = pts[[0, 5, 9, 13, 17], :2].mean(axis=0)
    return Hand(pose=classify(scaled), center=tuple(center), tip=tuple(pts[8, :2])), pts


def draw(frame, pts, hand, rec):
    h, w = frame.shape[:2]
    if pts is not None:
        xy = [(int(x * w), int(y * h)) for x, y, _ in pts]
        for a, b in CONNECTIONS:
            cv2.line(frame, xy[a], xy[b], (200, 200, 200), 2)
        for p in xy:
            cv2.circle(frame, p, 3, (0, 180, 255), -1)
    state = "POINTER" if rec.pointer_mode else ("LISTENING" if rec.armed else "off - hold open palm")
    colour = (60, 200, 60) if rec.armed else (80, 80, 255)
    cv2.putText(frame, state, (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, colour, 2)
    cv2.putText(frame, f"pose: {rec.pose}", (10, 58), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)


def list_cameras():
    """Open each camera briefly and report its size and brightness, saving a snapshot."""
    found = False
    for i in range(5):
        cap = cv2.VideoCapture(i)
        if not cap.isOpened():
            continue
        frame = None
        for _ in range(30):                  # let exposure settle
            ok, f = cap.read()
            if ok:
                frame = f
        cap.release()
        if frame is None:
            continue
        found = True
        path = f"/tmp/hand-gestures-camera-{i}.jpg"
        cv2.imwrite(path, frame)
        h, w = frame.shape[:2]
        print(f"camera {i}: {w}x{h}, brightness {frame.mean():.0f}/255, snapshot {path}")
    if not found:
        print("No camera could be opened. Allow camera access for this app in System Settings "
              "> Privacy & Security > Camera.")
    else:
        print("Open the snapshots to see which is which, then run with --camera N "
              "or set camera: N in config.yaml.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Control your Mac with hand gestures.")
    ap.add_argument("--config", default=os.path.join(ROOT, "config.yaml"))
    ap.add_argument("--preview", action="store_true", help="show the camera window")
    ap.add_argument("--dry-run", action="store_true", help="print actions, don't perform them")
    ap.add_argument("--camera", type=int, help="camera number (see --list-cameras)")
    ap.add_argument("--list-cameras", action="store_true", help="show each camera's number and brightness")
    args = ap.parse_args()

    with open(args.config) as f:
        cfg = yaml.safe_load(f)
    if args.list_cameras:
        return list_cameras()
    if args.camera is not None:
        cfg["camera"] = args.camera

    if not args.dry_run and not macos.accessibility_trusted():
        log("Accessibility permission is missing, so gestures can't press keys. Add the app "
            "you run this from (e.g. Terminal) in System Settings > Privacy & Security > "
            "Accessibility, then restart it.")

    rec = Recognizer(cfg)
    actions = Actions(cfg["actions"], dry_run=args.dry_run, log=log)
    sounds = cfg.get("sounds", True) and not args.dry_run
    screen_w, screen_h = macos.screen_size()
    margin = cfg["pointer"]["margin"]
    smoothing = cfg["pointer"]["smoothing"]
    cursor = None
    pending_scroll = 0.0

    cap = cv2.VideoCapture(cfg.get("camera", 0))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, cfg.get("camera_width", 640))
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, cfg.get("camera_height", 360))
    if not cap.isOpened():
        log("Can't open the camera. Allow camera access for the app you run this from in "
            "System Settings > Privacy & Security > Camera.")
        return 1

    landmarker = vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=MODEL),
        running_mode=vision.RunningMode.VIDEO,
        num_hands=1,
        min_hand_detection_confidence=0.6,
        min_tracking_confidence=0.5,
    ))
    log("Running. Hold an open palm still for a moment to start listening. Ctrl+C to quit.")

    start = time.monotonic()
    last_ts = -1
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                time.sleep(0.05)
                continue
            frame = cv2.flip(frame, 1)                     # mirror, so your right is right
            h, w = frame.shape[:2]
            t = time.monotonic() - start
            ts = max(int(t * 1000), last_ts + 1)
            last_ts = ts
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            result = landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), ts)

            hand, pts = None, None
            if result.hand_landmarks:
                hand, pts = to_hand(result.hand_landmarks[0], w / h)

            for kind, value in rec.update(t, hand):
                if kind == "arm":
                    log("listening")
                    sounds and macos.sound("Tink", 0.4)
                elif kind == "disarm":
                    log("stopped listening")
                    sounds and macos.sound("Bottle", 0.4)
                elif kind == "hold":
                    sounds and macos.sound("Pop")
                    actions.run(cfg["holds"][value]["action"], value)
                elif kind == "swipe":
                    pose, direction = value
                    name = cfg["swipes"][pose].get(direction)
                    if name:
                        sounds and macos.sound("Pop")
                        actions.run(name, f"{pose} swipe {direction}")
                elif kind == "scroll":
                    pending_scroll += value
                    if abs(pending_scroll) >= 1:
                        if not args.dry_run:
                            macos.scroll(pending_scroll)
                        pending_scroll -= int(pending_scroll)
                elif kind == "volume":
                    log(f"volume {'up' if value > 0 else 'down'}")
                    if not args.dry_run:
                        macos.media("volume_up" if value > 0 else "volume_down")
                elif kind == "pointer_on":
                    log("pointer mode on")
                    sounds and macos.sound("Morse", 0.4)
                    cursor = None
                elif kind == "pointer_off":
                    log("pointer mode off")
                    sounds and macos.sound("Morse", 0.4)
                elif kind == "pointer":
                    x = (value[0] - margin) / (1 - 2 * margin)
                    y = (value[1] - margin) / (1 - 2 * margin)
                    target = (min(max(x, 0), 1) * screen_w, min(max(y, 0), 1) * screen_h)
                    cursor = target if cursor is None else (
                        cursor[0] * smoothing + target[0] * (1 - smoothing),
                        cursor[1] * smoothing + target[1] * (1 - smoothing))
                    if not args.dry_run:
                        macos.move_cursor(*cursor)

            if args.preview:
                draw(frame, pts, hand, rec)
                cv2.imshow("hand gestures", frame)
                if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                    break
    except KeyboardInterrupt:
        pass
    finally:
        cap.release()
        cv2.destroyAllWindows()
        landmarker.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
