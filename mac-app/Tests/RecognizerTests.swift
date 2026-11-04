import XCTest
@testable import HandGestures

final class RecognizerTests: XCTestCase {
    final class Driver {
        let rec: Recognizer
        init(_ settings: Settings = Settings()) { rec = Recognizer(settings: settings) }
        var t = 0.0
        var events: [GestureEvent] = []
        @discardableResult
        func frames(_ pose: Pose?, _ seconds: Double, from a: CGPoint = CGPoint(x: 0.5, y: 0.5), to b: CGPoint? = nil, tip: CGPoint? = nil) -> Driver {
            let end = b ?? a
            let n = max(1, Int(seconds * 30))
            for i in 0..<n {
                let f = Double(i) / Double(max(1, n - 1))
                let c = CGPoint(x: a.x + (end.x - a.x) * f, y: a.y + (end.y - a.y) * f)
                let hand = pose.map { Hand(pose: $0, center: c, tip: tip ?? CGPoint(x: c.x, y: c.y - 0.1)) }
                events += rec.update(t: t, hand: hand)
                t += 1.0 / 30
            }
            return self
        }
        /// Everything but scroll and pointer movement, as short names like "thumbsUp.hold".
        var discrete: [String] {
            events.compactMap {
                switch $0 {
                case .wake: "wake"
                case .sleep: "sleep"
                case .gesture(let r): "\(r.pose.rawValue).\(r.motion.rawValue)"
                case .volume(let v): "volume\(v)"
                case .pointerOn: "pointerOn"
                case .pointerOff: "pointerOff"
                case .scroll, .pointer: nil
                }
            }
        }
        func wake() -> Driver { frames(rec.settings.startStopRule.pose, 1.5); frames(Pose.none, 0.3); events.removeAll(); return self }
    }

    func testNothingUntilAwake() { XCTAssertEqual(Driver().frames(.thumbsUp, 2).discrete, []) }
    func testWakeAndSleep() {
        XCTAssertEqual(Driver().frames(.openPalm, 1.5).frames(Pose.none, 0.3).frames(.openPalm, 1.5).discrete, ["wake", "sleep"])
    }
    func testHoldFiresOnce() { XCTAssertEqual(Driver().wake().frames(.thumbsUp, 3).discrete, ["thumbsUp.hold"]) }
    func testHoldNeedsStillHand() {
        XCTAssertEqual(Driver().wake().frames(.fist, 1, from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.7, y: 0.5)).discrete, [])
    }
    func testSwipes() {
        XCTAssertEqual(Driver().wake().frames(.openPalm, 0.3, from: CGPoint(x: 0.75, y: 0.5), to: CGPoint(x: 0.3, y: 0.5)).discrete, ["openPalm.swipeLeft"])
        XCTAssertEqual(Driver().wake().frames(.openPalm, 0.3, from: CGPoint(x: 0.5, y: 0.25), to: CGPoint(x: 0.5, y: 0.75)).discrete, ["openPalm.swipeDown"])
        XCTAssertEqual(Driver().wake().frames(.v, 0.3, from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.75, y: 0.5)).discrete, ["v.swipeRight"])
    }
    func testSlowDriftIsNotASwipe() {
        XCTAssertEqual(Driver().wake().frames(.openPalm, 1, from: CGPoint(x: 0.4, y: 0.5), to: CGPoint(x: 0.55, y: 0.5)).discrete, [])
    }
    func testScrollDirection() {
        let up = Driver().wake().frames(.point, 0.3).frames(.point, 0.5, tip: CGPoint(x: 0.5, y: 0.25)).events
            .reduce(0.0) { if case .scroll(let v) = $1 { return $0 + v }; return $0 }
        XCTAssertGreaterThan(up, 0)
    }
    func testVolumeSteps() {
        XCTAssertEqual(Driver().wake().frames(.ok, 0.3, from: CGPoint(x: 0.5, y: 0.6)).frames(.ok, 0.5, from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.42)).discrete, ["volume1", "volume1", "volume1"])
    }
    func testPointerModeSuspendsOthers() {
        let d = Driver().wake().frames(.three, 1).frames(.thumbsUp, 1.5).frames(Pose.none, 0.2).frames(.three, 1)
        XCTAssertEqual(d.discrete, ["pointerOn", "pointerOff"])
    }
    func testSleepsWithoutHand() {
        XCTAssertEqual(Driver().wake().frames(nil, 31).discrete, ["sleep"])
    }

    func testVersionCompare() {
        XCTAssertTrue(Updater.isNewer("1.0.12", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.0.40"))
        XCTAssertFalse(Updater.isNewer("1.0.5", than: "1.0.5"))
        XCTAssertFalse(Updater.isNewer("0.0.0", than: "1.0.1"))
    }

    func testEditedGestureList() {
        var s = Settings()
        s.gestures = [
            GestureRule(pose: .fist, motion: .hold, action: .startStop),
            GestureRule(pose: .v, motion: .hold, action: .reload),
            GestureRule(pose: .rock, motion: .swipeUp, action: .missionControl),
            GestureRule(pose: .three, motion: .moveUpDown, action: .volume),
        ]
        // Open palm no longer wakes it; the fist does.
        XCTAssertEqual(Driver(s).frames(.openPalm, 1.5).discrete, [])
        XCTAssertEqual(Driver(s).wake().frames(.v, 1.5).discrete, ["v.hold"])
        XCTAssertEqual(Driver(s).wake().frames(.rock, 0.3, from: CGPoint(x: 0.5, y: 0.75), to: CGPoint(x: 0.5, y: 0.25)).discrete, ["rock.swipeUp"])
        XCTAssertEqual(Driver(s).wake().frames(.three, 0.3, from: CGPoint(x: 0.5, y: 0.6)).frames(.three, 0.5, from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.48)).discrete, ["volume1", "volume1"])
        // Removed gestures do nothing.
        XCTAssertEqual(Driver(s).wake().frames(.thumbsUp, 2).discrete, [])
    }

    func testFirstOfTwoClashingGesturesWins() {
        var s = Settings()
        s.gestures.append(GestureRule(pose: .thumbsUp, motion: .hold, action: .lockScreen))
        let d = Driver(s).wake().frames(.thumbsUp, 2)
        guard case .gesture(let r) = d.events.first else { return XCTFail("no gesture") }
        XCTAssertEqual(r.action, .dictation)
        XCTAssertNotNil(s.warning(for: s.gestures.last!))
    }

    func testOldSettingsCarryOver() throws {
        let key = Settings.storageKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let old: [String: Any] = [
            "bindings": ["fist": ["action": "mute"], "palmUp": ["action": "appExpose"]],
            "volumeEnabled": false, "holdSeconds": 0.9, "onboarded": true,
        ]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: old), forKey: key)
        let s = Settings.load()
        XCTAssertEqual(s.holdSeconds, 0.9)
        XCTAssertTrue(s.onboarded)
        XCTAssertEqual(s.gestures.first { $0.pose == .fist && $0.motion == .hold }?.action, .mute)
        XCTAssertEqual(s.gestures.first { $0.pose == .openPalm && $0.motion == .swipeUp }?.action, .appExpose)
        XCTAssertNil(s.gestures.first { $0.action == .volume })
        XCTAssertEqual(s.gestures.count, GestureRule.defaults.count - 1)
    }

    func testPoses() {
        typealias P = SIMD2<Double>
        func hand(_ fingers: Set<Int>, thumb: String = "tucked", ok: Bool = false) -> [P] {
            var p = [P](repeating: .zero, count: 21)
            p[0] = P(0.5, 0.8); p[1] = P(0.44, 0.75); p[2] = P(0.37, 0.68)
            let th: [String: (P, P)] = ["tucked": (P(0.42, 0.66), P(0.47, 0.64)), "out": (P(0.32, 0.65), P(0.28, 0.63)), "up": (P(0.35, 0.6), P(0.33, 0.52))]
            (p[3], p[4]) = th[thumb]!
            let mcp = [P(0.44, 0.6), P(0.5, 0.58), P(0.56, 0.6), P(0.61, 0.63)]
            for f in 0..<4 {
                let m = mcp[f], b = 5 + 4 * f
                p[b] = m
                if fingers.contains(f) { p[b+1] = m + P(0, -0.07); p[b+2] = m + P(0, -0.12); p[b+3] = m + P(0, -0.16) }
                else { p[b+1] = m + P(0, -0.045); p[b+2] = m + P(0, -0.01); p[b+3] = m + P(0, 0.02) }
            }
            if ok { p[6] = P(0.43, 0.53); p[7] = P(0.40, 0.52); p[8] = P(0.38, 0.55); p[3] = P(0.35, 0.62); p[4] = P(0.37, 0.56) }
            return p
        }
        let cases: [(Pose, [P])] = [
            (.openPalm, hand([0, 1, 2, 3], thumb: "out")), (.fist, hand([])), (.point, hand([0])),
            (.lShape, hand([0], thumb: "out")), (.v, hand([0, 1])), (.three, hand([0, 1, 2])),
            (.rock, hand([0, 3])), (.shaka, hand([3], thumb: "out")), (.thumbsUp, hand([], thumb: "up")),
            (.ok, hand([1, 2, 3], ok: true)),
        ]
        for (expected, pts) in cases { XCTAssertEqual(PoseClassifier.classify(pts), expected, "\(expected)") }
    }
}
