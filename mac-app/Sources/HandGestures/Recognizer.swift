import CoreGraphics

/// One frame's hand, in mirrored camera space: 0...1, origin top-left.
struct Hand {
    var pose: Pose
    var center: CGPoint   // palm centre
    var tip: CGPoint      // index fingertip
}

enum GestureEvent: Equatable {
    case wake, sleep
    case trigger(Trigger)
    case scroll(Double)        // pixels, positive = up
    case volume(Int)           // +1 / -1
    case pointer(CGPoint)      // 0...1 fingertip position
    case pointerOn, pointerOff
}

/// Turns a stream of per-frame poses into gesture events: holds, swipes,
/// scrolling, volume and pointer movement. Pure logic, so it is testable.
final class Recognizer {
    var settings: Settings

    let stillTolerance = 0.04
    let poseDebounce = 0.12
    let swipeWindow = 0.5
    let swipeCooldown = 0.8
    let scrollDeadzone = 0.04
    let volumeStep = 0.06

    private(set) var awake = false
    private(set) var pointerMode = false
    private(set) var pose: Pose = .none

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

    init(settings: Settings) { self.settings = settings }

    private static let holdTriggers: [Pose: Trigger] = [
        .thumbsUp: .thumbsUp, .rock: .rock, .shaka: .shaka, .lShape: .lShape, .fist: .fist,
    ]

    private func setPose(_ p: Pose, _ t: Double, _ hand: Hand?) {
        pose = p
        holdStart = t
        holdAnchor = hand?.center
        holdFired = false
        history.removeAll()
        scrollAnchor = (hand != nil && p == .point) ? Double(hand!.tip.y) : nil
        volumeAnchor = (hand != nil && p == .ok) ? Double(hand!.center.y) : nil
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

        // Wake / sleep: open palm held still.
        if pose == .openPalm && !holdFired && held >= settings.wakeSeconds {
            holdFired = true
            if awake { goToSleep(&events) } else { awake = true; events.append(.wake) }
            return events
        }
        guard awake else { return events }

        // Pointer mode: the fingertip drives the cursor; only the toggle works.
        if pointerMode {
            if pose == .three && !holdFired && held >= settings.holdSeconds {
                holdFired = true
                pointerMode = false
                events.append(.pointerOff)
            } else {
                events.append(.pointer(hand.tip))
            }
            return events
        }

        if t < cooldownUntil { return events }

        // Holds.
        if !holdFired && held >= settings.holdSeconds {
            if pose == .three && settings.pointerEnabled {
                holdFired = true
                pointerMode = true
                events.append(.pointerOn)
                return events
            }
            if let trigger = Self.holdTriggers[pose] {
                holdFired = true
                events.append(.trigger(trigger))
                return events
            }
        }

        // Swipes.
        if pose == .openPalm || pose == .v {
            history.append((t, hand.center))
            history.removeAll { t - $0.t > swipeWindow }
            if let first = history.first {
                let dx = Double(hand.center.x - first.p.x), dy = Double(hand.center.y - first.p.y)
                let d = settings.swipeDistance
                var direction: String?
                if abs(dx) > d && abs(dx) > 1.5 * abs(dy) { direction = dx > 0 ? "right" : "left" }
                else if abs(dy) > d && abs(dy) > 1.5 * abs(dx) { direction = dy > 0 ? "down" : "up" }
                if let direction, let trigger = Self.swipeTrigger(pose, direction) {
                    history.removeAll()
                    cooldownUntil = t + swipeCooldown
                    holdFired = true   // a swipe never also counts as a hold
                    events.append(.trigger(trigger))
                    return events
                }
            }
        }

        // Scroll: point, then move the hand up or down from where you started.
        if pose == .point, settings.scrollEnabled, let anchor = scrollAnchor {
            let offset = anchor - Double(hand.tip.y)          // > 0 when the hand is higher
            let excess = abs(offset) - scrollDeadzone
            if excess > 0 {
                var px = excess * settings.scrollSpeed * dt * (offset > 0 ? 1 : -1)
                if settings.invertScroll { px = -px }
                if px != 0 { events.append(.scroll(px)) }
            }
        }

        // Volume: OK sign, then raise or lower the hand.
        if pose == .ok, settings.volumeEnabled, var anchor = volumeAnchor {
            let y = Double(hand.center.y)
            while anchor - y >= volumeStep { anchor -= volumeStep; events.append(.volume(1)) }
            while y - anchor >= volumeStep { anchor += volumeStep; events.append(.volume(-1)) }
            volumeAnchor = anchor
        }
        return events
    }

    private static func swipeTrigger(_ pose: Pose, _ direction: String) -> Trigger? {
        switch (pose, direction) {
        case (.openPalm, "left"): .palmLeft
        case (.openPalm, "right"): .palmRight
        case (.openPalm, "up"): .palmUp
        case (.openPalm, "down"): .palmDown
        case (.v, "left"): .vLeft
        case (.v, "right"): .vRight
        default: nil
        }
    }
}
