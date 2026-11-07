import CoreGraphics

/// One frame's hand, in mirrored camera space: 0...1, origin top-left.
struct Hand {
    var pose: Pose
    var center: CGPoint   // palm centre
    var tip: CGPoint      // index fingertip
    var pinch: Double = .infinity       // thumb tip to index tip, in palm lengths
    var pinchPoint: CGPoint = .zero     // between the thumb and index tips
    var middlePinch: Double = .infinity // thumb tip to middle tip, in palm lengths (index up)
}

enum GestureEvent: Equatable {
    case wake, sleep
    case gesture(GestureRule)  // a hold or swipe with a one-off action
    case engage, release       // the hand picked up / let go of the pointer
    case aim(CGPoint)          // while holding the pointer: the palm's 0...1 position; the pointer moves by its change
    case pinchDown             // fingers closed: hold the pointer where it was aimed
    case click(Int)            // released without moving: 1 = click, 2 = double-click
    case rightClick            // thumb to middle finger: more options
    case dragStart, dragEnd    // moved while pinched: mouse down … mouse up; .aim moves it between
    case scroll(Double)        // pixels; positive scrolls up (the content moves down)
    case volume(Int)           // +1 / -1
    case zoomStart, zoomEnd    // both hands pinched / released
    case zoom(Int)             // +1 expand, -1 shrink, one step at a time
    case scale(Double)         // hands' spread relative to when the pinch began
}

/// Turns a stream of per-frame hands into gesture events.
///
/// Built in, like a mouse: point and hold a beat to pick up the pointer, move the
/// hand to move it, lower the hand or change shape to let go. While holding it, a
/// pinch clicks (however long it's held), twice double-clicks, moved drags; thumb to
/// middle finger right-clicks, like a two-finger click on the trackpad. Both hands
/// pinching zoom. Everything else follows the user's gesture list (holds, swipes,
/// scroll, volume). Pure logic, so it is testable.
final class Recognizer {
    var settings: Settings { didSet { rebuild() } }

    let stillTolerance = 0.04
    let poseDebounce = 0.1
    let swipeWindow = 0.5
    let swipeCooldown = 0.8
    let volumeStep = 0.06
    let scrollNoise = 0.002     // frame fraction per frame below which a resting hand doesn't scroll
    let pinchClose = 0.3        // palm lengths: fingers count as touching below this…
    let pinchRelease = 0.5      // …and as apart again above this
    let dragThreshold = 0.045   // frame fraction the pinch travels before it becomes a drag
    let doubleClickWindow = 0.7 // seconds between the two releases of a double pinch
    let engageDwell = 0.25      // seconds the pointing hand is held still before it picks up the pointer
    let releaseGrace = 0.35     // seconds of another shape before the pointer is let go
    let zoomStep = 1.15         // spread ratio per zoom step


    private(set) var awake = false
    private(set) var pose: Pose = .none
    private(set) var pinched = false
    private(set) var dragging = false
    private(set) var zooming = false
    /// The hand is holding the pointer.
    private(set) var engaged = false
    private var lastPointerShape = 0.0

    // Lookups built from the gesture list; the first rule wins when two clash.
    private var wakePose: Pose = .openPalm
    private var holds: [Pose: GestureRule] = [:]
    private var swipes: [Pose: [Motion: GestureRule]] = [:]
    private var scrollPose: Pose?
    private var volumePose: Pose?

    private var lastSeen: Double?
    private var rawPose: Pose?
    private var rawSince = 0.0
    private var holdStart = 0.0
    private var holdAnchor: CGPoint?
    private var holdFired = false
    private var history: [(t: Double, p: CGPoint)] = []
    private var cooldownUntil = 0.0
    private var scrollLastY: Double?
    private var volumeAnchor: Double?

    // Pinch.
    private var closeFrames = 0
    private var openFrames = 0
    private var pinchStartPoint = CGPoint.zero    // palm centre when the pinch closed
    private var rightFrames = 0
    private var rightSpent = false          // after a right-click, the middle finger must lift first
    private var pinchSpent = false          // after a zoom, fingers must open before the next click
    private var lastClick: (t: Double, p: CGPoint)?

    // Both-hands start / stop.
    private var bothSince: Double?
    private var bothLastSeen = -1.0
    private var bothAnchors: (CGPoint, CGPoint)?
    private var bothFired = false

    // Two-hand zoom.
    private var zoomCandidateSince: Double?
    private var zoomStartSpread = 0.0
    private var zoomBase = 0.0

    init(settings: Settings) {
        self.settings = settings
        rebuild()
    }

    private func rebuild() {
        wakePose = settings.startStopRule.pose
        holds = [:]; swipes = [:]; scrollPose = nil; volumePose = nil
        var seen = Set<String>()
        for r in settings.gestures where r.action != .none {
            guard seen.insert("\(r.pose.rawValue).\(r.motion.rawValue)").inserted else { continue }
            switch (r.motion, r.action) {
            case (.hold, .startStop): break
            case (.hold, _) where r.action.isDiscrete: holds[r.pose] = r
            case (.moveUpDown, .scroll): scrollPose = r.pose
            case (.moveUpDown, .volume): volumePose = r.pose
            case (let m, _) where m.isSwipe && r.action.isDiscrete: swipes[r.pose, default: [:]][m] = r
            default: break
            }
        }
    }

    // MARK: Helpers

    private func setPose(_ p: Pose, _ t: Double, _ hand: Hand?) {
        pose = p
        holdStart = t
        holdAnchor = hand?.center
        holdFired = false
        history.removeAll()
        scrollLastY = nil
        volumeAnchor = (hand != nil && p == volumePose) ? Double(hand!.center.y) : nil
    }

    /// Seconds the current pose has been held still; restarts when the hand moves.
    private func heldFor(_ t: Double, _ hand: Hand) -> Double {
        guard let a = holdAnchor else {
            holdStart = t; holdAnchor = hand.center; return 0
        }
        if max(abs(hand.center.x - a.x), abs(hand.center.y - a.y)) > stillTolerance {
            holdStart = t; holdAnchor = hand.center
        }
        return t - holdStart
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    /// Lets go of a pinch without clicking (hand lost, zoom started, going to sleep).
    private func cancelPinch(_ events: inout [GestureEvent]) {
        if dragging { events.append(.dragEnd) }
        pinched = false; dragging = false; closeFrames = 0
    }

    private func releasePointer(_ events: inout [GestureEvent]) {
        if engaged { engaged = false; events.append(.release) }
    }

    private func endZoom(_ events: inout [GestureEvent]) {
        if zooming { zooming = false; pinchSpent = true; events.append(.zoomEnd) }
        zoomCandidateSince = nil
    }

    private func goToSleep(_ events: inout [GestureEvent]) {
        cancelPinch(&events)
        releasePointer(&events)
        endZoom(&events)
        awake = false
        events.append(.sleep)
    }

    /// True once, when both hands have shown the start / stop shape, still, for the wake time.
    /// Brief tracking gaps (under 0.25 s) don't restart the count.
    private func bothHandsHeld(_ t: Double, _ hand: Hand, _ other: Hand?) -> Bool {
        guard let other, hand.pose == wakePose, other.pose == wakePose else {
            if t - bothLastSeen > 0.25 { bothSince = nil; bothFired = false }
            return false
        }
        let moved = bothAnchors.map { a in
            max(abs(hand.center.x - a.0.x), abs(hand.center.y - a.0.y),
                abs(other.center.x - a.1.x), abs(other.center.y - a.1.y)) > stillTolerance * 1.5
        } ?? true
        if bothSince == nil || t - bothLastSeen > 0.25 || moved {
            bothSince = t
            bothAnchors = (hand.center, other.center)
        }
        bothLastSeen = t
        guard !bothFired, let since = bothSince, t - since >= settings.wakeSeconds else { return false }
        bothFired = true
        return true
    }

    // MARK: Update

    /// `other` is a second hand in view, used for both-hands start / stop and zoom.
    /// `typing` is true just after a key press: hands are ignored, like a trackpad
    /// ignoring your palm while you type.
    func update(t: Double, hand: Hand?, other: Hand? = nil, typing: Bool = false) -> [GestureEvent] {
        var events: [GestureEvent] = []

        guard let hand else {
            cancelPinch(&events)      // never leave the mouse button held down
            releasePointer(&events)
            endZoom(&events)
            if awake, let seen = lastSeen, t - seen > settings.sleepAfterSeconds { goToSleep(&events) }
            if pose != .none { setPose(.none, t, nil) }
            rawPose = nil
            return events
        }
        lastSeen = t

        if hand.pose != rawPose { rawPose = hand.pose; rawSince = t }
        if hand.pose != pose && t - rawSince >= poseDebounce { setPose(hand.pose, t, hand) }
        let held = heldFor(t, hand)
        if hand.pinch > pinchRelease { pinchSpent = false }
        if hand.middlePinch > pinchRelease { rightSpent = false }

        // Start / stop: its shape held still — on both hands, unless set to one.
        if settings.startStopBothHands {
            if bothHandsHeld(t, hand, other) {
                if awake { goToSleep(&events) } else { awake = true; events.append(.wake) }
                return events
            }
        } else if pose == wakePose && !holdFired && held >= settings.wakeSeconds {
            holdFired = true
            if awake { goToSleep(&events) } else { awake = true; events.append(.wake) }
            return events
        }
        guard awake else { return events }

        if typing {
            cancelPinch(&events)
            releasePointer(&events)
            endZoom(&events)
            return events
        }

        // Two hands pinching: expand / shrink by pulling apart / pushing together.
        if settings.twoHandZoom, let other {
            let spread = Self.distance(hand.pinchPoint, other.pinchPoint)
            if zooming {
                if hand.pinch < pinchRelease && other.pinch < pinchRelease {
                    if settings.twoHandResizesWindow {
                        events.append(.scale(spread / max(zoomStartSpread, 1e-6)))
                    } else {
                        while spread > zoomBase * zoomStep { zoomBase *= zoomStep; events.append(.zoom(1)) }
                        while spread < zoomBase / zoomStep { zoomBase /= zoomStep; events.append(.zoom(-1)) }
                    }
                } else {
                    endZoom(&events)
                }
                return events
            }
            if hand.pose == .pinch && other.pose == .pinch && hand.pinch < pinchClose && other.pinch < pinchClose {
                let since = zoomCandidateSince ?? t
                zoomCandidateSince = since
                if t - since >= poseDebounce {
                    cancelPinch(&events)
                    zooming = true
                    zoomStartSpread = spread
                    zoomBase = spread
                    events.append(.zoomStart)
                    return events
                }
            } else {
                zoomCandidateSince = nil
            }
        } else {
            endZoom(&events)
        }

        // Pinch: click, double-click or drag (moved). Holding it longer is still a click.
        if settings.pinchGrab {
            if pinched {
                openFrames = hand.pinch > pinchRelease ? openFrames + 1 : 0
                if openFrames >= 2 {                    // fingers apart: let go
                    pinched = false
                    holdFired = true
                    if dragging {
                        dragging = false
                        events.append(.dragEnd)
                    } else {
                        let double = lastClick.map {
                            t - $0.t < doubleClickWindow && Self.distance($0.p, pinchStartPoint) < 0.05
                        } ?? false
                        events.append(.click(double ? 2 : 1))
                        lastClick = double ? nil : (t, pinchStartPoint)
                    }
                    return events
                }
                if !dragging && Self.distance(hand.center, pinchStartPoint) > dragThreshold {
                    dragging = true
                    events.append(.dragStart)
                }
                lastPointerShape = t
                if engaged { events.append(.aim(hand.center)) }
                return events
            }
            // Fingers closing: two frames in a row of a real pinch (not an OK sign or a fist).
            // If the other hand is pinching too, it's the start of a two-hand zoom, not a click.
            let otherPinching = settings.twoHandZoom && other.map { $0.pose == .pinch && $0.pinch < pinchClose } == true
            // With the hand pointer on, only a hand holding the pointer can click.
            let mayClick = engaged || !settings.handPointer

            // Thumb to middle finger, index still up: right-click. The middle tip must be the
            // one touching, well closer to the thumb than the index tip.
            let middleTouch = hand.middlePinch < pinchClose && hand.pinch > max(pinchClose, 2 * hand.middlePinch)
            rightFrames = (mayClick && middleTouch && !rightSpent)
                ? rightFrames + 1 : 0
            if rightFrames >= 2 {
                rightFrames = 0
                rightSpent = true
                closeFrames = 0
                lastPointerShape = t
                events.append(.pinchDown)
                events.append(.rightClick)
                return events
            }
            closeFrames = (mayClick && hand.pose == .pinch && hand.pinch < pinchClose && !pinchSpent && !otherPinching)
                ? closeFrames + 1 : 0
            if closeFrames >= 2 {
                pinched = true
                dragging = false
                openFrames = 0
                closeFrames = 0
                pinchStartPoint = hand.center
                lastPointerShape = t
                events.append(.pinchDown)
                return events
            }
        }

        // The pointer: point and hold a beat to pick it up; it then follows the palm
        // (so pinching doesn't move it) until the hand changes shape for a moment.
        if settings.handPointer {
            let pointing = hand.pose == .point || hand.pose == .pinch || hand.middlePinch < pinchRelease
            if engaged {
                if pointing { lastPointerShape = t }
                if t - lastPointerShape > releaseGrace {
                    releasePointer(&events)
                } else {
                    events.append(.aim(hand.center))
                    return events     // holding the pointer: no other gestures
                }
            } else if pose == .point && held >= engageDwell {
                engaged = true
                lastPointerShape = t
                events.append(.engage)
                events.append(.aim(hand.center))
                return events
            }
        } else {
            releasePointer(&events)
        }

        if t < cooldownUntil { return events }

        // Holds. The start / stop shape waits for its own, longer hold above.
        if !holdFired && held >= settings.holdSeconds && pose != wakePose, let rule = holds[pose] {
            holdFired = true
            events.append(.gesture(rule))
            return events
        }

        // Swipes.
        if let map = swipes[pose] {
            history.append((t, hand.center))
            history.removeAll { t - $0.t > swipeWindow }
            if let first = history.first {
                let dx = Double(hand.center.x - first.p.x), dy = Double(hand.center.y - first.p.y)
                let d = settings.swipeDistance
                var motion: Motion?
                if abs(dx) > d && abs(dx) > 1.5 * abs(dy) { motion = dx > 0 ? .swipeRight : .swipeLeft }
                else if abs(dy) > d && abs(dy) > 1.5 * abs(dx) { motion = dy > 0 ? .swipeDown : .swipeUp }
                if let motion, let rule = map[motion] {
                    history.removeAll()
                    cooldownUntil = t + swipeCooldown
                    holdFired = true   // a swipe never also counts as a hold
                    events.append(.gesture(rule))
                    return events
                }
            }
        }

        // Scroll, like two fingers on a trackpad: the page follows the hand up and down.
        if pose == scrollPose {
            let y = Double(hand.center.y)
            if let last = scrollLastY {
                // Slow movement builds up until it passes the noise of a resting hand.
                if abs(y - last) > scrollNoise {
                    events.append(.scroll((y - last) * settings.scrollSpeed * (settings.invertScroll ? -1 : 1)))
                    scrollLastY = y
                }
            } else {
                scrollLastY = y
            }
        }

        // Volume: hold the shape, then raise or lower the hand.
        if pose == volumePose, var anchor = volumeAnchor {
            let y = Double(hand.center.y)
            while anchor - y >= volumeStep { anchor -= volumeStep; events.append(.volume(1)) }
            while y - anchor >= volumeStep { anchor += volumeStep; events.append(.volume(-1)) }
            volumeAnchor = anchor
        }
        return events
    }
}
