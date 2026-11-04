"""Classify one frame's 21 hand landmarks into a named pose.

Landmark indices (MediaPipe): 0 wrist; thumb 1-4; index 5-8; middle 9-12;
ring 13-16; pinky 17-20. Within a finger: MCP, PIP, DIP, TIP.
"""
import numpy as np

WRIST = 0
FINGERS = {  # name: (mcp, pip, dip, tip)
    "index": (5, 6, 7, 8),
    "middle": (9, 10, 11, 12),
    "ring": (13, 14, 15, 16),
    "pinky": (17, 18, 19, 20),
}

POSES = ("open_palm", "fist", "point", "l_shape", "v", "three", "rock",
         "shaka", "thumbs_up", "ok", "none")


def _unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


def _cos(a, b):
    return float(np.dot(_unit(a), _unit(b)))


def palm_size(p):
    return float(np.linalg.norm(p[9] - p[WRIST]))


def finger_extended(p, name):
    mcp, pip, _, tip = FINGERS[name]
    straight = _cos(p[pip] - p[mcp], p[tip] - p[pip]) > 0.5
    reaches_out = np.linalg.norm(p[tip] - p[WRIST]) > 1.1 * np.linalg.norm(p[pip] - p[WRIST])
    return straight and reaches_out


def thumb_extended(p):
    straight = _cos(p[3] - p[2], p[4] - p[3]) > 0.6
    away_from_pinky = np.linalg.norm(p[4] - p[17]) > 1.1 * np.linalg.norm(p[2] - p[17])
    away_from_index = np.linalg.norm(p[4] - p[5]) > 0.55 * palm_size(p)
    return straight and away_from_pinky and away_from_index


def classify(p):
    """p: (21, 3) array with x scaled to match y (x * width / height)."""
    p = np.asarray(p, dtype=float)
    palm = palm_size(p)
    if palm < 1e-6:
        return "none"
    ext = {name: finger_extended(p, name) for name in FINGERS}
    thumb = thumb_extended(p)
    i, m, r, k = ext["index"], ext["middle"], ext["ring"], ext["pinky"]

    if np.linalg.norm(p[4] - p[8]) < 0.3 * palm and m and r and k:
        return "ok"
    if i and m and r and k:
        return "open_palm"
    if i and m and r and not k:
        return "three"
    if i and m and not r and not k:
        return "v"
    if i and k and not m and not r:
        return "rock"
    if k and thumb and not i and not m and not r:
        return "shaka"
    if i and not m and not r and not k:
        # Index alone: an L if the thumb sticks out well away from the index.
        if thumb and _cos(p[4] - p[2], p[8] - p[5]) < 0.64:  # > ~50 degrees apart
            return "l_shape"
        return "point"
    if not (i or m or r or k):
        if thumb and _unit(p[4] - p[2])[1] < -0.7:  # image y grows downward
            return "thumbs_up"
        if not thumb:
            return "fist"
    return "none"
