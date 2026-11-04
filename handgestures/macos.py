"""Low-level macOS input: key combos, media keys, scrolling, cursor, frontmost app.

Posting events needs Accessibility permission for the app that runs this
(Terminal, iTerm, ...): System Settings > Privacy & Security > Accessibility.
"""
import subprocess
import time

import Quartz
from AppKit import NSEvent

MODIFIERS = {  # name: (keycode, event flag)
    "cmd": (55, Quartz.kCGEventFlagMaskCommand),
    "shift": (56, Quartz.kCGEventFlagMaskShift),
    "opt": (58, Quartz.kCGEventFlagMaskAlternate),
    "ctrl": (59, Quartz.kCGEventFlagMaskControl),
    "fn": (63, Quartz.kCGEventFlagMaskSecondaryFn),
}
MODIFIERS["alt"] = MODIFIERS["opt"]
MODIFIERS["command"] = MODIFIERS["cmd"]
MODIFIERS["control"] = MODIFIERS["ctrl"]

KEYS = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
    "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "escape": 53, "esc": 53, "f1": 122, "f2": 120, "f3": 99,
    "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111, "home": 115, "pageup": 116, "forwarddelete": 117,
    "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
}
# Arrow and navigation keys only switch Spaces / open Mission Control when they
# carry the flags a real keyboard sends with them.
NAV_FLAGS = Quartz.kCGEventFlagMaskSecondaryFn | Quartz.kCGEventFlagMaskNumericPad
NAV_KEYS = {"left", "right", "up", "down", "home", "end", "pageup", "pagedown", "forwarddelete"}

MEDIA = {"volume_up": 0, "volume_down": 1, "mute": 7, "play": 16, "next": 17,
         "previous": 18, "fast_forward": 19, "rewind": 20}


def _post(event):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def _key_event(code, down, flags):
    ev = Quartz.CGEventCreateKeyboardEvent(None, code, down)
    Quartz.CGEventSetFlags(ev, flags)
    return ev


def press(combo):
    """Press a combo such as "cmd+shift+]", "ctrl+left", "fn+space" or "return".

    Modifiers are pressed as real key-downs (not just flags) so that things like
    Cmd+Tab and Fn-based hotkeys behave as if typed.
    """
    parts = [p.strip().lower() for p in combo.split("+")]
    *mods, key = parts
    if key in MODIFIERS and not mods:      # a lone modifier, e.g. "fn"
        mods, key = [key], None
    flags = 0
    for m in mods:
        code, flag = MODIFIERS[m]
        flags |= flag
        _post(_key_event(code, True, flags))
    if key is not None:
        code = KEYS[key]
        key_flags = flags | (NAV_FLAGS if key in NAV_KEYS else 0)
        _post(_key_event(code, True, key_flags))
        time.sleep(0.02)
        _post(_key_event(code, False, key_flags))
    for m in reversed(mods):
        code, flag = MODIFIERS[m]
        flags &= ~flag
        _post(_key_event(code, False, flags))


def media(name):
    """Media / volume keys, which also show the system HUD."""
    key = MEDIA[name]
    for down in (True, False):
        state = 0xA00 if down else 0xB00
        ev = NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
            14, (0, 0), state, 0, 0, None, 8, (key << 16) | state, -1)
        _post(ev.CGEvent())


def scroll(pixels):
    ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitPixel, 1, int(round(pixels)))
    _post(ev)


def screen_size():
    b = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
    return b.size.width, b.size.height


def move_cursor(x, y):
    ev = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (x, y), Quartz.kCGMouseButtonLeft)
    _post(ev)


def frontmost_app():
    """Name of the app owning the front-most normal window.

    Read from the window list because NSWorkspace's answer goes stale in a
    process without a run loop.
    """
    opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowLayer") == 0:
            return w.get("kCGWindowOwnerName", "")
    return ""


def sound(name, volume=0.25):
    subprocess.Popen(["afplay", "-v", str(volume), f"/System/Library/Sounds/{name}.aiff"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def accessibility_trusted():
    from ApplicationServices import AXIsProcessTrusted
    return bool(AXIsProcessTrusted())
