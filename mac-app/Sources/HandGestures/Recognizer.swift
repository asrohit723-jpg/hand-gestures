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
    case scroll(Double)        // pixels, positive = up
    case volume(Int)           // +1 / -1
    case pointer(CGPoint)      // 0...1 palm position
    case pointerOn, pointerOff
    case grabStart, grabEnd    // pinch closed / opened: mouse down / up
    case grabMove(CGVector)    // hand moved while pinched, 0...1 of the frame
    case zoomStart, zoomEnd    // both hands pinched / released
    case zoom(Int)             // +1 expand, -1 shrink, one step at a time
    case scale(Double)         // hands' spread relative to when the pinch began
}

/// Turns a stream of per-frame poses into gesture events, following the user's
/// gesture list: holds, swipes, scrolling, volume and pointer movement.
/// Pure logic, so it is testable.
final class Recognizer {
    var settings: Settings { didSet { rebuild() } }

    let stillTolerance = 0.04
    let poseDebounce = 0.12
    let swipeWindow = 0.5
    let swipeCooldown = 0.8
    let moveDeadzone = 0.04
    let volumeStep = 0.06
    let pinchRelease = 0.5     // palm lengths: a pinch opens past this (it closes at 0.3)
    let zoomStep = 1.15        // spread ratio per zoom step

    private(set) var awake = false
    private(set) var pointerMode = false
    private(set) var pose: Pose = .none
    private(set) var grabbing = false
    private(set) var zooming = false

    // Lookups built from the gesture list; the first rule wins when two clash.
    private var wakePose: Pose = .openPalm
    private var pointerPose: Pose?
    private var holds: [Pose: GestureRule] = [:]
    private var swipes: [Pose: [Motion: GestureRule]] = [:]
    private var scrollPose: Pose?
    private var volumePose: Pose?

    // Both-hands start / stop: when both hands began showing the shape, where, and
    // whether this showing already fired (it must be lowered before it fires again).
    private var bothSince: Double?
    private var bothLastSeen = -1.0
    private var bothAnchors: (CGPoint, CGPoint)?
    private var bothFired = false

    private var lastSeen: Double?
    private var lastT: Double?
    private var rawPose: Pose?
    private var rawSince = 0.0
    private var holdStart = 0.0
    private var holdAnchor: CGPoint?
    private var holdFired = false
    private var history: [(t: Double, p: CGPoint)] = []
    private var cooldownUntil = 0.0
    private var scrollAnchor: Double?
    private var volumeAnchor: Double?
    private var grabLast: CGPoint?
    /// A pinch that already grabbed (or zoomed) can't grab again until the hand changes shape.
    private var pinchSpent = false
    private var pinchOpenFrames = 0
    private var zoomCandidateSince: Double?
    private var zoomStartSpread = 0.0
    private var zoomBase = 0.0

    init(settings: Settings) {
        self.settings = settings
        rebuild()
    }

    private func rebuild() {
        wakePose = settings.startStopRule.pose
        pointerPose = nil; holds = [:]; swipes = [:]; scrollPose = nil; volumePose = nil
        var seen = Set<String>()
        for r in settings.gestures where r.action != .none {
            guard seen.insert("\(r.pose.rawValue).\(r.motion.rawValue)").inserted else { continue }
            switch (r.motion, r.action) {
            case (.hold, .startStop): break
            case (.hold, .pointer): pointerPose = r.pose
            case (.hold, _) where r.action.isDiscrete: holds[r.pose] = r
            case (.moveUpDown, .scroll): scrollPose = r.pose
            case (.moveUpDown, .volume): volumePose = r.pose
            case (let m, _) where m.isSwipe && r.action.isDiscrete: swipes[r.pose, default: [:]][m] = r
            default: break
            }
        }
    }

    private func setPose(_ p: Pose, _ t: Double, _ hand: Hand?) {
        pose = p
        holdStart = t
        holdAnchor = hand?.center
        holdFired = false
        pinchSpent = false
        history.removeAll()
        scrollAnchor = (hand != nil && p == scrollPose) ? Double(hand!.tip.y) : nil
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

    private func endGrab(_ events: inout [GestureEvent]) {
        if grabbing { grabbing = false; grabLast = nil; events.append(.grabEnd) }
        pinchSpent = true
    }

    private func endZoom(_ events: inout [GestureEvent]) {
        if zooming { zooming = false; pinchSpent = true; events.append(.zoomEnd) }
        zoomCandidateSince = nil
    }

    /// True once a pinch has stayed open for two frames (so one noisy frame doesn't drop it).
    private func pinchOpened(_ hand: Hand) -> Bool {
        pinchOpenFrames = hand.pinch > pinchRelease ? pinchOpenFrames + 1 : 0
        return pinchOpenFrames >= 2
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

    private func goToSleep(_ events: inout [GestureEvent]) {
        endGrab(&events)
        endZoom(&events)
        if pointerMode { pointerMode = false; events.append(.pointerOff) }
        awake = false
        events.append(.sleep)
    }

    /// `other` is a second hand in view, used only for two-hand pinch.
    func update(t: Double, hand: Hand?, other: Hand? = nil) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let dt = lastT.map { min(t - $0, 0.2) } ?? 0
        lastT = t

        guard let hand else {
            endGrab(&events)      // never leave the mouse button held down
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
            let spread = hypot(Double(hand.pinchPoint.x - other.pinchPoint.x), Double(hand.pinchPoint.y - other.pinchPoint.y))
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
            if hand.pose == .pinch && other.pose == .pinch {
                let since = zoomCandidateSince ?? t
                zoomCandidateSince = since
                if t - since >= poseDebounce {
                    endGrab(&events)
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

        // Pointer mode: the fingertip drives the cursor; only the toggle works.
        if pointerMode {
            if pose == pointerPose && !holdFired && held >= settings.holdSeconds {
                holdFired = true
                pointerMode = false
                events.append(.pointerOff)
            } else {
                if settings.pinchGrab {
                    if grabbing { if pinchOpened(hand) { endGrab(&events) } }
                    else if pose == .pinch && !pinchSpent { grabbing = true; pinchOpenFrames = 0; events.append(.grabStart) }
                }
                events.append(.pointer(hand.center))
            }
            return events
        }

        // Pinch: grab what's under the cursor and drag it with the hand.
        if settings.pinchGrab {
            if grabbing {
                if pinchOpened(hand) {
                    endGrab(&events)
                    holdFired = true
                } else {
                    if let last = grabLast {
                        events.append(.grabMove(CGVector(dx: hand.center.x - last.x, dy: hand.center.y - last.y)))
                    }
                    grabLast = hand.center
                }
                return events
            }
            if pose == .pinch && !pinchSpent {
                grabbing = true
                grabLast = hand.center
                pinchOpenFrames = 0
                events.append(.grabStart)
                return events
            }
        }

        if t < cooldownUntil { return events }

        // Holds. The start / stop shape waits for its own, longer hold above.
        if !holdFired && held >= settings.holdSeconds && pose != wakePose {
            if pose == pointerPose {
                holdFired = true
                pointerMode = true
                events.append(.pointerOn)
                return events
            }
            if let rule = holds[pose] {
                holdFired = true
                events.append(.gesture(rule))
                return events
            }
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

        // Scroll: hold the shape, then move the hand up or down from where you started.
        if pose == scrollPose, let anchor = scrollAnchor {
            let offset = anchor - Double(hand.tip.y)          // > 0 when the hand is higher
            let excess = abs(offset) - moveDeadzone
            if excess > 0 {
                var px = excess * settings.scrollSpeed * dt * (offset > 0 ? 1 : -1)
                if settings.invertScroll { px = -px }
                if px != 0 { events.append(.scroll(px)) }
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
