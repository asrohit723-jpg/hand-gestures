"""Synthetic-hand tests for pose classification and the gesture state machine.

Run: .venv/bin/python -m unittest discover tests
"""
import os
import unittest

import numpy as np
import yaml

from handgestures.poses import classify
from handgestures.recognizer import Hand, Recognizer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = yaml.safe_load(open(os.path.join(ROOT, "config.yaml")))

WRIST = (0.5, 0.8)
MCP = {"index": (0.44, 0.6), "middle": (0.5, 0.58), "ring": (0.56, 0.6), "pinky": (0.61, 0.63)}
ORDER = ["index", "middle", "ring", "pinky"]


def make_hand(fingers=(), thumb="tucked", ok=False):
    """Front-facing hand, fingers up. fingers: names extended. thumb: tucked|out|up."""
    p = np.zeros((21, 3))
    p[0, :2] = WRIST
    p[1, :2] = (0.44, 0.75)
    p[2, :2] = (0.37, 0.68)
    p[3, :2], p[4, :2] = {
        "tucked": ((0.42, 0.66), (0.47, 0.64)),
        "out": ((0.32, 0.65), (0.28, 0.63)),
        "up": ((0.35, 0.6), (0.33, 0.52)),
    }[thumb]
    for n, name in enumerate(ORDER):
        mx, my = MCP[name]
        base = 5 + 4 * n
        p[base, :2] = (mx, my)
        if name in fingers:
            p[base + 1:base + 4, :2] = [(mx, my - 0.07), (mx, my - 0.12), (mx, my - 0.16)]
        else:
            p[base + 1:base + 4, :2] = [(mx, my - 0.045), (mx, my - 0.01), (mx, my + 0.02)]
    if ok:  # index curls round to meet the thumb tip
        p[6:9, :2] = [(0.43, 0.53), (0.40, 0.52), (0.38, 0.55)]
        p[3, :2], p[4, :2] = (0.35, 0.62), (0.37, 0.56)
    return p


class PoseTests(unittest.TestCase):
    def test_poses(self):
        cases = {
            "open_palm": make_hand(ORDER, "out"),
            "fist": make_hand(),
            "point": make_hand(["index"]),
            "l_shape": make_hand(["index"], "out"),
            "v": make_hand(["index", "middle"]),
            "three": make_hand(["index", "middle", "ring"]),
            "rock": make_hand(["index", "pinky"]),
            "shaka": make_hand(["pinky"], "out"),
            "thumbs_up": make_hand([], "up"),
            "ok": make_hand(["middle", "ring", "pinky"], ok=True),
        }
        for expected, pts in cases.items():
            with self.subTest(expected):
                self.assertEqual(classify(pts), expected)

    def test_four_fingers_without_thumb_is_still_open_palm(self):
        self.assertEqual(classify(make_hand(ORDER, "tucked")), "open_palm")


class Driver:
    """Feeds frames at 30 fps and collects events."""

    def __init__(self):
        self.rec = Recognizer(CFG)
        self.t = 0.0
        self.events = []

    def frames(self, pose, seconds, start=(0.5, 0.5), end=None, tip=None):
        end = end or start
        n = max(1, int(seconds * 30))
        for i in range(n):
            f = i / max(1, n - 1)
            c = (start[0] + (end[0] - start[0]) * f, start[1] + (end[1] - start[1]) * f)
            hand = None if pose is None else Hand(pose, c, tip or (c[0], c[1] - 0.1))
            self.events += self.rec.update(self.t, hand)
            self.t += 1 / 30
        return self

    def kinds(self):
        return [e for e in self.events if e[0] not in ("scroll", "pointer")]

    def arm(self):
        self.frames("open_palm", 1.5).frames("none", 0.3)
        self.events.clear()
        return self


class RecognizerTests(unittest.TestCase):
    def test_nothing_fires_until_armed(self):
        d = Driver().frames("thumbs_up", 2).frames("open_palm", 0.3, (0.7, 0.5), (0.2, 0.5))
        self.assertEqual(d.kinds(), [])

    def test_open_palm_hold_arms_and_disarms(self):
        d = Driver().frames("open_palm", 1.5).frames("none", 0.3).frames("open_palm", 1.5)
        self.assertEqual(d.kinds(), [("arm", None), ("disarm", None)])

    def test_hold_fires_once(self):
        d = Driver().arm().frames("thumbs_up", 3)
        self.assertEqual(d.kinds(), [("hold", "thumbs_up")])

    def test_hold_needs_a_still_hand(self):
        d = Driver().arm().frames("fist", 1.0, (0.3, 0.5), (0.7, 0.5))
        self.assertEqual(d.kinds(), [])

    def test_palm_swipes(self):
        d = Driver().arm().frames("open_palm", 0.3, (0.75, 0.5), (0.3, 0.5))
        self.assertEqual(d.kinds(), [("swipe", ("open_palm", "left"))])
        d = Driver().arm().frames("open_palm", 0.3, (0.5, 0.25), (0.5, 0.75))
        self.assertEqual(d.kinds(), [("swipe", ("open_palm", "down"))])

    def test_v_swipe_right(self):
        d = Driver().arm().frames("v", 0.3, (0.3, 0.5), (0.75, 0.5))
        self.assertEqual(d.kinds(), [("swipe", ("v", "right"))])

    def test_slow_drift_is_not_a_swipe(self):
        d = Driver().arm().frames("open_palm", 1.0, (0.4, 0.5), (0.55, 0.5))
        self.assertEqual(d.kinds(), [])

    def test_scroll_direction_follows_hand(self):
        d = Driver().arm().frames("point", 0.3).frames("point", 0.5, tip=(0.5, 0.25))
        up = sum(v for k, v in d.events if k == "scroll")
        self.assertGreater(up, 0)
        d = Driver().arm().frames("point", 0.3).frames("point", 0.5, tip=(0.5, 0.6))
        down = sum(v for k, v in d.events if k == "scroll")
        self.assertLess(down, 0)

    def test_volume_steps(self):
        d = Driver().arm().frames("ok", 0.3, (0.5, 0.6)).frames("ok", 0.5, (0.5, 0.6), (0.5, 0.42))
        self.assertEqual(d.kinds(), [("volume", 1)] * 3)

    def test_pointer_mode_suspends_other_gestures(self):
        d = Driver().arm().frames("three", 1.0).frames("thumbs_up", 1.5).frames("none", 0.2).frames("three", 1.0)
        self.assertEqual(d.kinds(), [("pointer_on", None), ("pointer_off", None)])
        self.assertTrue(any(k == "pointer" for k, _ in d.events))

    def test_idle_disarm(self):
        d = Driver().arm().frames(None, CFG["arm"]["idle_disarm_seconds"] + 1)
        self.assertEqual(d.kinds(), [("disarm", None)])


if __name__ == "__main__":
    unittest.main()
