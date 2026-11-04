import CoreGraphics

/// One frame's hand, in mirrored camera space: 0...1, origin top-left.
struct Hand {
    var pose: Pose
    var center: CGPoint   // palm centre
    var tip: CGPoint      // index fingertip
    var pinch: Double = .infinity       // thumb tip to index tip, in palm lengths
    var pinchPoint: CGPoint = .zero     // between the thumb and index tips
}

enum GestureEvent: Equatable {
    case wake, sleep
    case gesture(GestureRule)  // a hold or swipe with a one-off action
    case aim(CGPoint)          // 0...1 position the pointer follows
    case pinchDown             // fingers closed: hold the pointer where it was aimed
    case click(Int)            // released without moving: 1 = click, 2 = double-click
    case rightClick            // held still: more options
    case dragStart, dragEnd    // moved while pinched: mouse down … mouse up; .aim moves it between
    case scroll(Double)        // pixels; positive scrolls up (the content moves down)
    case volume(Int)           // +1 / -1
    case zoomStart, zoomEnd    // both hands pinched / released
    case zoom(Int)             // +1 expand, -1 shrink, one step at a time
    case scale(Double)         // hands' spread relative to when the pinch began
}

/// Turns a stream of per-frame hands into gesture events.
///
/// Built in, like a trackpad: a relaxed or pointing hand aims the pointer; a pinch
/// clicks, twice double-clicks, held still right-clicks, moved drags; both hands
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
    let dragThreshold = 0.025   // frame fraction the pinch travels before it becomes a drag
    let doubleClickWindow = 0.45
    let zoomStep = 1.15         // spread ratio per zoom step

    /// Shapes that aim the pointer: a relaxed hand, pointing, or about to pinch.
    static let aimPoses: Set<Pose> = [.none, .point, .pinch]

    private(set) var awake = false
    private(set) var pose: Pose = .none
    private(set) var pinched = false
    private(set) var dragging = false
    private(set) var zooming = false

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
    private var pinchStartT = 0.0
    private var pinchStartPoint = CGPoint.zero
    private var rightClicked = false
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

    private func endZoom(_ events: inout [GestureEvent]) {
        if zooming { zooming = false; pinchSpent = true; events.append(.zoomEnd) }
        zoomCandidateSince = nil
    }

    private func goToSleep(_ events: inout [GestureEvent]) {
        cancelPinch(&events)
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
    func update(t: Double, hand: Hand?, other: Hand? = nil) -> [GestureEvent] {
        var events: [GestureEvent] = []

        guard let hand else {
            cancelPinch(&events)      // never leave the mouse button held down
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

        // Pinch: click, double-click, right-click (held still) or drag (moved).
        if settings.pinchGrab {
            if pinched {
                openFrames = hand.pinch > pinchRelease ? openFrames + 1 : 0
                if openFrames >= 2 {                    // fingers apart: let go
                    pinched = false
                    holdFired = true
                    if dragging {
                        dragging = false
                        events.append(.dragEnd)
                    } else if !rightClicked {
                        let double = lastClick.map {
                            t - $0.t < doubleClickWindow && Self.distance($0.p, pinchStartPoint) < 0.05
                        } ?? false
                        events.append(.click(double ? 2 : 1))
                        lastClick = double ? nil : (t, pinchStartPoint)
                    }
                    return events
                }
                if !dragging && !rightClicked {
                    if Self.distance(hand.pinchPoint, pinchStartPoint) > dragThreshold {
                        dragging = true
                        events.append(.dragStart)
                    } else if t - pinchStartT >= settings.rightClickSeconds {
                        rightClicked = true
                        events.append(.rightClick)
                    }
                }
                if dragging { events.append(.aim(hand.pinchPoint)) }
                return events
            }
            // Fingers closing: two frames in a row of a real pinch (not an OK sign or a fist).
            // If the other hand is pinching too, it's the start of a two-hand zoom, not a click.
            let otherPinching = settings.twoHandZoom && other.map { $0.pose == .pinch && $0.pinch < pinchClose } == true
            closeFrames = (hand.pose == .pinch && hand.pinch < pinchClose && !pinchSpent && !otherPinching) ? closeFrames + 1 : 0
            if closeFrames >= 2 {
                pinched = true
                dragging = false
                rightClicked = false
                openFrames = 0
                closeFrames = 0
                pinchStartT = t
                pinchStartPoint = hand.pinchPoint
                events.append(.pinchDown)
                return events
            }
        }

        // Aim: a relaxed or pointing hand moves the pointer.
        if settings.handPointer && Self.aimPoses.contains(pose) && Self.aimPoses.contains(hand.pose) {
            events.append(.aim(hand.pinchPoint))
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
