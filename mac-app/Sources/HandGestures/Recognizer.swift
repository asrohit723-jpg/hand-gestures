import CoreGraphics

/// One frame's hand, in mirrored camera space: 0...1, origin top-left.
struct Hand {
    var pose: Pose
    var center: CGPoint   // palm centre
    var tip: CGPoint      // index fingertip
}

enum GestureEvent: Equatable {
    case wake, sleep
    case gesture(GestureRule)  // a hold or swipe with a one-off action
    case scroll(Double)        // pixels, positive = up
    case volume(Int)           // +1 / -1
    case pointer(CGPoint)      // 0...1 fingertip position
    case pointerOn, pointerOff
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

    private(set) var awake = false
    private(set) var pointerMode = false
    private(set) var pose: Pose = .none

    // Lookups built from the gesture list; the first rule wins when two clash.
    private var wakePose: Pose = .openPalm
    private var pointerPose: Pose?
    private var holds: [Pose: GestureRule] = [:]
    private var swipes: [Pose: [Motion: GestureRule]] = [:]
    private var scrollPose: Pose?
    private var volumePose: Pose?

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

    private func goToSleep(_ events: inout [GestureEvent]) {
        if pointerMode { pointerMode = false; events.append(.pointerOff) }
        awake = false
        events.append(.sleep)
    }

    func update(t: Double, hand: Hand?) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let dt = lastT.map { min(t - $0, 0.2) } ?? 0
        lastT = t

        guard let hand else {
            if awake, let seen = lastSeen, t - seen > settings.sleepAfterSeconds { goToSleep(&events) }
            if pose != .none { setPose(.none, t, nil) }
            rawPose = nil
            return events
        }
        lastSeen = t

        if hand.pose != rawPose { rawPose = hand.pose; rawSince = t }
        if hand.pose != pose && t - rawSince >= poseDebounce { setPose(hand.pose, t, hand) }
        let held = heldFor(t, hand)

        // Start / stop: its shape held still.
        if pose == wakePose && !holdFired && held >= settings.wakeSeconds {
            holdFired = true
            if awake { goToSleep(&events) } else { awake = true; events.append(.wake) }
            return events
        }
        guard awake else { return events }

        // Pointer mode: the fingertip drives the cursor; only the toggle works.
        if pointerMode {
            if pose == pointerPose && !holdFired && held >= settings.holdSeconds {
                holdFired = true
                pointerMode = false
                events.append(.pointerOff)
            } else {
                events.append(.pointer(hand.tip))
            }
            return events
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
