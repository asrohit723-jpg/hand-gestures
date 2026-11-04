"""Turn a stream of per-frame poses into gesture events.

Pure logic, no camera or macOS calls, so it can be tested with synthetic frames.

Events returned by Recognizer.update():
  ("arm", None) / ("disarm", None)
  ("hold", pose)                 pose held still for its configured time (fires once)
  ("swipe", (pose, direction))   direction: left | right | up | down
  ("scroll", pixels)             positive = scroll up
  ("volume", +1 | -1)
  ("pointer", (x, y))            0..1 position for the cursor, pointer mode only
  ("pointer_on", None) / ("pointer_off", None)
"""
from collections import deque
from dataclasses import dataclass


@dataclass
class Hand:
    pose: str
    center: tuple   # palm centre, 0..1 of frame width / height (mirrored view)
    tip: tuple      # index fingertip, same space


class Recognizer:
    def __init__(self, cfg):
        self.arm_hold = cfg["arm"]["hold_seconds"]
        self.idle_disarm = cfg["arm"]["idle_disarm_seconds"]
        self.holds = {pose: h["seconds"] for pose, h in cfg["holds"].items()}
        self.swipe_poses = set(cfg["swipes"])
        sw = cfg["swipe_detection"]
        self.swipe_window = sw["window_seconds"]
        self.swipe_distance = sw["distance"]
        self.swipe_cooldown = sw["cooldown_seconds"]
        self.scroll = cfg["scroll"]
        self.volume = cfg["volume"]
        self.pointer_toggle_pose = cfg["pointer"]["toggle_pose"]
        self.still_tolerance = cfg.get("still_tolerance", 0.04)
        self.pose_debounce = cfg.get("pose_debounce_seconds", 0.12)

        self.armed = False
        self.pointer_mode = False
        self.last_seen = None
        self.last_t = None
        self.raw_pose = None
        self.raw_since = 0.0
        self.pose = "none"         # debounced pose
        self.pose_since = 0.0
        self.hold_start = None
        self.hold_anchor = None
        self.hold_fired = False
        self.history = deque()     # (t, x, y) of the palm centre for swipes
        self.cooldown_until = 0.0
        self.scroll_anchor = None
        self.volume_anchor = None

    # -- helpers -------------------------------------------------------------
    def _set_pose(self, pose, t, hand):
        self.pose = pose
        self.pose_since = t
        self.hold_start = t
        self.hold_anchor = hand.center if hand else None
        self.hold_fired = False
        self.history.clear()
        self.scroll_anchor = hand.tip[1] if hand and pose == self.scroll["pose"] else None
        self.volume_anchor = hand.center[1] if hand and pose == self.volume["pose"] else None

    def _held_for(self, t, hand):
        """Seconds the current pose has been held still; restarts if the hand moves."""
        ax, ay = self.hold_anchor
        if max(abs(hand.center[0] - ax), abs(hand.center[1] - ay)) > self.still_tolerance:
            self.hold_start, self.hold_anchor = t, hand.center
        return t - self.hold_start

    def _disarm(self, events):
        if self.pointer_mode:
            self.pointer_mode = False
            events.append(("pointer_off", None))
        self.armed = False
        events.append(("disarm", None))

    # -- main ----------------------------------------------------------------
    def update(self, t, hand):
        events = []
        dt = 0.0 if self.last_t is None else min(t - self.last_t, 0.2)
        self.last_t = t

        if hand is None:
            if self.armed and self.last_seen is not None and t - self.last_seen > self.idle_disarm:
                self._disarm(events)
            if self.pose != "none":
                self._set_pose("none", t, None)
            self.raw_pose = None
            return events
        self.last_seen = t

        # Debounce: a new pose must persist briefly before it counts.
        if hand.pose != self.raw_pose:
            self.raw_pose, self.raw_since = hand.pose, t
        if hand.pose != self.pose and t - self.raw_since >= self.pose_debounce:
            self._set_pose(hand.pose, t, hand)
        pose = self.pose
        if self.hold_anchor is None:
            self.hold_start, self.hold_anchor = t, hand.center

        held = self._held_for(t, hand)

        # Arm / disarm: open palm held still.
        if pose == "open_palm" and not self.hold_fired and held >= self.arm_hold:
            self.hold_fired = True
            if self.armed:
                self._disarm(events)
            else:
                self.armed = True
                events.append(("arm", None))
            return events
        if not self.armed:
            return events

        # Pointer mode: the index fingertip drives the cursor; only the toggle works.
        if self.pointer_mode:
            if pose == self.pointer_toggle_pose and not self.hold_fired \
                    and held >= self.holds[self.pointer_toggle_pose]:
                self.hold_fired = True
                self.pointer_mode = False
                events.append(("pointer_off", None))
            else:
                events.append(("pointer", hand.tip))
            return events

        if t < self.cooldown_until:
            return events

        # Holds.
        if pose in self.holds and not self.hold_fired and held >= self.holds[pose]:
            self.hold_fired = True
            if pose == self.pointer_toggle_pose:
                self.pointer_mode = True
                events.append(("pointer_on", None))
            else:
                events.append(("hold", pose))
            return events

        # Swipes.
        if pose in self.swipe_poses:
            self.history.append((t, hand.center[0], hand.center[1]))
            while self.history and t - self.history[0][0] > self.swipe_window:
                self.history.popleft()
            _, x0, y0 = self.history[0]
            dx, dy = hand.center[0] - x0, hand.center[1] - y0
            direction = None
            if abs(dx) > self.swipe_distance and abs(dx) > 1.5 * abs(dy):
                direction = "right" if dx > 0 else "left"
            elif abs(dy) > self.swipe_distance and abs(dy) > 1.5 * abs(dx):
                direction = "down" if dy > 0 else "up"
            if direction:
                self.history.clear()
                self.cooldown_until = t + self.swipe_cooldown
                self.hold_fired = True  # a swipe never also counts as a hold
                events.append(("swipe", (pose, direction)))
                return events

        # Scroll: point, then move the hand up or down from where you started.
        if pose == self.scroll["pose"] and self.scroll_anchor is not None:
            offset = self.scroll_anchor - hand.tip[1]          # > 0 when the hand is higher
            excess = abs(offset) - self.scroll["deadzone"]
            if excess > 0:
                pixels = excess * self.scroll["speed"] * dt * (1 if offset > 0 else -1)
                if self.scroll.get("invert"):
                    pixels = -pixels
                if pixels:
                    events.append(("scroll", pixels))

        # Volume: OK sign, then raise or lower the hand.
        if pose == self.volume["pose"] and self.volume_anchor is not None:
            step = self.volume["step"]
            while self.volume_anchor - hand.center[1] >= step:
                self.volume_anchor -= step
                events.append(("volume", +1))
            while hand.center[1] - self.volume_anchor >= step:
                self.volume_anchor += step
                events.append(("volume", -1))

        return events
