import XCTest
@testable import HandGestures

final class RecognizerTests: XCTestCase {
    /// Feeds synthetic hands at 30 fps and collects what comes out.
    final class Driver {
        let rec: Recognizer
        var t = 0.0
        var events: [GestureEvent] = []
        init(_ settings: Settings = Settings()) { rec = Recognizer(settings: settings) }

        @discardableResult
        func frames(_ pose: Pose?, _ seconds: Double, from a: CGPoint = CGPoint(x: 0.5, y: 0.5), to b: CGPoint? = nil,
                    typing: Bool = false, middle: Bool = false) -> Driver {
            let end = b ?? a
            let n = max(1, Int(seconds * 30))
            for i in 0..<n {
                let f = Double(i) / Double(max(1, n - 1))
                let c = CGPoint(x: a.x + (end.x - a.x) * f, y: a.y + (end.y - a.y) * f)
                let hand = pose.map { Hand(pose: $0, center: c, tip: CGPoint(x: c.x, y: c.y - 0.1),
                                           pinch: $0 == .pinch ? 0.1 : .infinity, pinchPoint: c,
                                           middlePinch: middle ? 0.1 : .infinity) }
                events += rec.update(t: t, hand: hand, typing: typing)
                t += 1.0 / 30
            }
            return self
        }

        /// Awake, then point and hold still to pick up the pointer.
        func holdingPointer(at p: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Driver {
            _ = wake(); frames(.point, 0.5, from: p); events.removeAll(); return self
        }

        /// The start / stop shape held still, on both hands (or one, if that's the setting).
        @discardableResult
        func showStartStop(_ seconds: Double = 1.5) -> Driver {
            let pose = rec.settings.startStopRule.pose
            guard rec.settings.startStopBothHands else { return frames(pose, seconds) }
            for _ in 0..<Int(seconds * 30) {
                func h(_ x: Double) -> Hand { Hand(pose: pose, center: CGPoint(x: x, y: 0.5), tip: CGPoint(x: x, y: 0.4)) }
                events += rec.update(t: t, hand: h(0.5), other: h(0.85))
                t += 1.0 / 30
            }
            return self
        }

        /// Both hands pinching, their pinch points moving from `a` to `b` apart.
        @discardableResult
        func twoHands(_ seconds: Double, spreadFrom a: Double, to b: Double, pinched: Bool = true) -> Driver {
            let n = max(1, Int(seconds * 30))
            for i in 0..<n {
                let f = Double(i) / Double(max(1, n - 1))
                let half = (a + (b - a) * f) / 2
                func h(_ x: Double) -> Hand {
                    Hand(pose: pinched ? .pinch : .openPalm, center: CGPoint(x: x, y: 0.5), tip: CGPoint(x: x, y: 0.4),
                         pinch: pinched ? 0.1 : 0.9, pinchPoint: CGPoint(x: x, y: 0.5))
                }
                events += rec.update(t: t, hand: h(0.5 - half), other: h(0.5 + half))
                t += 1.0 / 30
            }
            return self
        }

        func wake() -> Driver { showStartStop(); frames(Pose.none, 0.3); events.removeAll(); return self }

        /// Everything except pointer aiming and scrolling, as short names like "thumbsUp.hold".
        var discrete: [String] {
            events.compactMap {
                switch $0 {
                case .wake: "wake"
                case .engage: "engage"
                case .release: "release"
                case .sleep: "sleep"
                case .gesture(let r): "\(r.pose.rawValue).\(r.motion.rawValue)"
                case .volume(let v): "volume\(v)"
                case .pinchDown: "pinchDown"
                case .click(let n): "click\(n)"
                case .rightClick: "rightClick"
                case .dragStart: "dragStart"
                case .dragEnd: "dragEnd"
                case .zoomStart: "zoomStart"
                case .zoomEnd: "zoomEnd"
                case .zoom(let z): "zoom\(z)"
                case .aim, .scroll, .scale: nil
                }
            }
        }

        var aims: Int { events.filter { if case .aim = $0 { return true }; return false }.count }
        var scrolled: Double { events.reduce(0) { if case .scroll(let v) = $1 { return $0 + v }; return $0 } }
    }

    // MARK: Start / stop

    func testNothingUntilAwake() {
        XCTAssertEqual(Driver().frames(.thumbsUp, 2).frames(.pinch, 0.3).discrete, [])
        XCTAssertEqual(Driver().frames(.point, 1).aims, 0)
    }

    func testBothPalmsStartAndStop() {
        XCTAssertEqual(Driver().showStartStop().frames(Pose.none, 0.3).showStartStop().discrete, ["wake", "sleep"])
    }

    func testOnePalmDoesNotStartOrStop() {
        XCTAssertEqual(Driver().frames(.openPalm, 3).discrete, [])
        XCTAssertEqual(Driver().wake().frames(.openPalm, 3).discrete, [])
    }

    func testHoldingBothPalmsFiresOnce() {
        XCTAssertEqual(Driver().showStartStop(4).discrete, ["wake"])
    }

    func testOneHandStartStopWhenBothHandsIsOff() {
        var s = Settings(); s.startStopBothHands = false
        XCTAssertEqual(Driver(s).frames(.openPalm, 1.5).discrete, ["wake"])
    }

    func testSleepsWithoutHand() {
        XCTAssertEqual(Driver().wake().frames(nil, 31).discrete, ["sleep"])
    }

    // MARK: Pointer and clicks

    func testRelaxedOrRaisedHandDoesNothing() {
        // The glitch this design fixes: a hand just lifted near the laptop must not move the pointer.
        for pose: Pose in [.none, .openPalm, .v, .fist, .thumbsUp, .ok] {
            let d = Driver().wake().frames(pose, 1, from: CGPoint(x: 0.3, y: 0.6), to: CGPoint(x: 0.7, y: 0.4))
            XCTAssertEqual(d.aims, 0, "\(pose)")
            XCTAssertFalse(d.discrete.contains("engage"), "\(pose)")
        }
    }

    func testPointingAndHoldingStillPicksUpThePointer() {
        let d = Driver().wake().frames(.point, 0.6)
        XCTAssertEqual(d.discrete, ["engage"])
        XCTAssertGreaterThan(d.aims, 5)
    }

    func testPointingWhileMovingDoesNotPickItUp() {
        let d = Driver().wake().frames(.point, 0.6, from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.8, y: 0.5))
        XCTAssertFalse(d.discrete.contains("engage"))
        XCTAssertEqual(d.aims, 0)
    }

    func testTheHeldPointerFollowsTheHand() {
        let d = Driver().holdingPointer().frames(.point, 0.5, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.7, y: 0.5))
        XCTAssertGreaterThan(d.aims, 10)
        XCTAssertEqual(d.discrete, [])
    }

    func testChangingShapeOrLoweringTheHandLetsGo() {
        XCTAssertEqual(Driver().holdingPointer().frames(.openPalm, 0.6).discrete, ["release"])
        XCTAssertEqual(Driver().holdingPointer().frames(nil, 0.1).discrete, ["release"])
        // A brief flicker of another shape doesn't drop it.
        XCTAssertEqual(Driver().holdingPointer().frames(Pose.none, 0.15).frames(.point, 0.3).discrete, [])
    }

    func testTypingPausesTheHand() {
        XCTAssertEqual(Driver().holdingPointer().frames(.point, 0.2, typing: true).discrete, ["release"])
        XCTAssertFalse(Driver().wake().frames(.point, 1, typing: true).discrete.contains("engage"))
        XCTAssertEqual(Driver().wake().frames(.thumbsUp, 2, typing: true).discrete, [])
    }

    func testGestureShapesDoNotMoveThePointer() {
        for pose: Pose in [.v, .openPalm, .fist, .thumbsUp, .ok] {
            XCTAssertEqual(Driver().wake().frames(pose, 0.6).aims, 0, "\(pose)")
        }
    }

    func testPinchWithoutHoldingThePointerDoesNotClick() {
        XCTAssertEqual(Driver().wake().frames(.pinch, 0.3).frames(Pose.none, 0.3).discrete, [])
    }

    func testHandPointerOffLetsAPinchClickAtTheTrackpadPointer() {
        var s = Settings(); s.handPointer = false
        let d = Driver(s).wake().frames(.point, 0.5)
        XCTAssertEqual(d.aims, 0)
        XCTAssertEqual(Driver(s).wake().frames(.pinch, 0.2).frames(Pose.none, 0.2).discrete, ["pinchDown", "click1"])
    }

    func testQuickPinchClicks() {
        XCTAssertEqual(Driver().holdingPointer().frames(.pinch, 0.2).frames(.point, 0.2).discrete, ["pinchDown", "click1"])
    }

    func testTwoQuickPinchesDoubleClick() {
        let d = Driver().holdingPointer().frames(.pinch, 0.15).frames(.point, 0.12).frames(.pinch, 0.15).frames(.point, 0.2)
        XCTAssertEqual(d.discrete, ["pinchDown", "click1", "pinchDown", "click2"])
    }

    func testSlowSecondPinchIsASingleClick() {
        let d = Driver().holdingPointer().frames(.pinch, 0.15).frames(.point, 0.8).frames(.pinch, 0.15).frames(.point, 0.2)
        XCTAssertEqual(d.discrete, ["pinchDown", "click1", "pinchDown", "click1"])
    }

    func testAnOrdinaryDoublePinchDoubleClicks() {
        // A relaxed double pinch: each pinch a quarter second, a quarter second apart.
        let d = Driver().holdingPointer().frames(.pinch, 0.25).frames(.point, 0.25).frames(.pinch, 0.25).frames(.point, 0.2)
        XCTAssertEqual(d.discrete, ["pinchDown", "click1", "pinchDown", "click2"])
    }

    func testALongPinchIsStillALeftClick() {
        // Holding the pinch must never turn into a right-click.
        XCTAssertEqual(Driver().holdingPointer().frames(.pinch, 1.5).frames(.point, 0.2).discrete, ["pinchDown", "click1"])
    }

    func testASmallDriftWhilePinchingStillClicks() {
        let d = Driver().holdingPointer()
            .frames(.pinch, 0.3, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.53, y: 0.51))
            .frames(.point, 0.2, from: CGPoint(x: 0.53, y: 0.51))
        XCTAssertEqual(d.discrete, ["pinchDown", "click1"])
    }

    func testThumbToMiddleFingerRightClicksOnce() {
        let d = Driver().holdingPointer().frames(.point, 0.6, middle: true).frames(.point, 0.3)
        XCTAssertEqual(d.discrete, ["pinchDown", "rightClick"])
        // Lifting the middle finger and touching again right-clicks again.
        d.events.removeAll()
        d.frames(.point, 0.3, middle: true)
        XCTAssertEqual(d.discrete, ["pinchDown", "rightClick"])
    }

    func testThumbToMiddleFingerWithoutThePointerDoesNothing() {
        XCTAssertEqual(Driver().wake().frames(Pose.none, 0.5, middle: true).discrete, [])
    }

    func testPinchAndMoveDrags() {
        let d = Driver().holdingPointer(at: CGPoint(x: 0.4, y: 0.5))
            .frames(.pinch, 0.15, from: CGPoint(x: 0.4, y: 0.5))
            .frames(.pinch, 0.5, from: CGPoint(x: 0.4, y: 0.5), to: CGPoint(x: 0.7, y: 0.4))
            .frames(.point, 0.2, from: CGPoint(x: 0.7, y: 0.4))
        XCTAssertEqual(d.discrete, ["pinchDown", "dragStart", "dragEnd"])
        XCTAssertGreaterThan(d.aims, 5)    // the dragged thing follows the hand
    }

    func testLosingTheHandMidDragLetsGo() {
        let d = Driver().holdingPointer().frames(.pinch, 0.15).frames(.pinch, 0.3, to: CGPoint(x: 0.7, y: 0.5)).frames(nil, 0.1)
        XCTAssertEqual(d.discrete, ["pinchDown", "dragStart", "dragEnd", "release"])
    }

    func testOKSignNeverClicks() {
        let d = Driver().holdingPointer()
        for _ in 0..<20 {
            d.events += d.rec.update(t: d.t, hand: Hand(pose: .ok, center: CGPoint(x: 0.5, y: 0.5), tip: .zero,
                                                       pinch: 0.1, pinchPoint: CGPoint(x: 0.5, y: 0.5)))
            d.t += 1.0 / 30
        }
        XCTAssertFalse(d.discrete.contains("pinchDown"))
    }

    func testPinchOffDoesNothing() {
        var s = Settings(); s.pinchGrab = false
        XCTAssertEqual(Driver(s).holdingPointer().frames(.pinch, 1).frames(.point, 0.2).discrete, [])
    }

    // MARK: Two hands

    func testTwoHandPinchZooms() {
        let d = Driver().wake().twoHands(0.2, spreadFrom: 0.2, to: 0.2).twoHands(0.6, spreadFrom: 0.2, to: 0.4)
            .twoHands(0.2, spreadFrom: 0.4, to: 0.4, pinched: false)
        XCTAssertEqual(d.discrete.first, "zoomStart")
        XCTAssertEqual(d.discrete.last, "zoomEnd")
        XCTAssertEqual(d.discrete.filter { $0 == "zoom1" }.count, 4)
        XCTAssertFalse(d.discrete.contains("click1"))
    }

    func testTwoHandPinchResizesWindow() {
        var s = Settings(); s.twoHandResizesWindow = true
        let d = Driver(s).wake().twoHands(0.2, spreadFrom: 0.2, to: 0.2).twoHands(0.5, spreadFrom: 0.2, to: 0.3)
        let last = d.events.compactMap { if case .scale(let f) = $0 { return f }; return nil }.last
        XCTAssertEqual(last ?? 0, 1.5, accuracy: 0.05)
    }

    // MARK: The gesture list

    func testHoldFiresOnce() {
        XCTAssertEqual(Driver().wake().frames(.thumbsUp, 3).discrete, ["thumbsUp.hold"])
    }

    func testHoldNeedsStillHand() {
        XCTAssertEqual(Driver().wake().frames(.fist, 1, from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.7, y: 0.5)).discrete, [])
    }

    func testTrackpadStyleSwipes() {
        // Whole hand: desktops left / right, Mission Control up, app windows down.
        XCTAssertEqual(Driver().wake().frames(.openPalm, 0.3, from: CGPoint(x: 0.75, y: 0.5), to: CGPoint(x: 0.3, y: 0.5)).discrete, ["openPalm.swipeLeft"])
        XCTAssertEqual(Driver().wake().frames(.openPalm, 0.3, from: CGPoint(x: 0.5, y: 0.75), to: CGPoint(x: 0.5, y: 0.25)).discrete, ["openPalm.swipeUp"])
        // Two fingers: back / forward.
        XCTAssertEqual(Driver().wake().frames(.v, 0.3, from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.75, y: 0.5)).discrete, ["v.swipeRight"])
        let defaults = Settings().gestures
        XCTAssertEqual(defaults.first { $0.pose == .v && $0.motion == .swipeRight }?.action, .back)
        XCTAssertEqual(defaults.first { $0.pose == .openPalm && $0.motion == .swipeLeft }?.action, .desktopNext)
    }

    func testSlowDriftIsNotASwipe() {
        XCTAssertEqual(Driver().wake().frames(.openPalm, 1, from: CGPoint(x: 0.4, y: 0.5), to: CGPoint(x: 0.55, y: 0.5)).discrete, [])
    }

    func testTwoFingersScrollWithTheHand() {
        let down = Driver().wake().frames(.v, 0.2).frames(.v, 0.5, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.7))
        XCTAssertGreaterThan(down.scrolled, 0)            // hand down: the page comes down with it
        let up = Driver().wake().frames(.v, 0.2).frames(.v, 0.5, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.3))
        XCTAssertLessThan(up.scrolled, 0)
        XCTAssertEqual(Driver().wake().frames(.v, 1).scrolled, 0)   // a still hand doesn't scroll
    }

    func testVolumeSteps() {
        XCTAssertEqual(Driver().wake().frames(.ok, 0.3, from: CGPoint(x: 0.5, y: 0.6)).frames(.ok, 0.5, from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.42)).discrete, ["volume1", "volume1", "volume1"])
    }

    func testEditedGestureList() {
        var s = Settings()
        s.gestures = [
            GestureRule(pose: .fist, motion: .hold, action: .startStop),
            GestureRule(pose: .v, motion: .hold, action: .reload),
            GestureRule(pose: .rock, motion: .swipeUp, action: .missionControl),
            GestureRule(pose: .three, motion: .moveUpDown, action: .volume),
        ]
        XCTAssertEqual(Driver(s).frames(.openPalm, 1.5).discrete, [])
        XCTAssertEqual(Driver(s).wake().frames(.v, 1.5).discrete, ["v.hold"])
        XCTAssertEqual(Driver(s).wake().frames(.rock, 0.3, from: CGPoint(x: 0.5, y: 0.75), to: CGPoint(x: 0.5, y: 0.25)).discrete, ["rock.swipeUp"])
        XCTAssertEqual(Driver(s).wake().frames(.three, 0.3, from: CGPoint(x: 0.5, y: 0.6)).frames(.three, 0.5, from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.48)).discrete, ["volume1", "volume1"])
        XCTAssertEqual(Driver(s).wake().frames(.thumbsUp, 2).discrete, [])
    }

    func testFirstOfTwoClashingGesturesWins() {
        var s = Settings()
        s.gestures.append(GestureRule(pose: .thumbsUp, motion: .hold, action: .lockScreen))
        let d = Driver(s).wake().frames(.thumbsUp, 2)
        guard case .gesture(let r) = d.events.first(where: { if case .gesture = $0 { return true }; return false })
        else { return XCTFail("no gesture") }
        XCTAssertEqual(r.action, .dictation)
        XCTAssertNotNil(s.warning(for: s.gestures.last!))
    }

    func testVersionCompare() {
        XCTAssertTrue(Updater.isNewer("1.0.12", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.0.40"))
        XCTAssertFalse(Updater.isNewer("1.0.5", than: "1.0.5"))
        XCTAssertFalse(Updater.isNewer("0.0.0", than: "1.0.1"))
    }

    // MARK: Upgrading saved settings

    private func withSaved(_ object: [String: Any], _ check: (Settings) -> Void) throws {
        let key = Settings.storageKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        check(Settings.load())
    }

    func testUntouchedOldListBecomesTheRecommendedSet() throws {
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GestureRule.legacyDefaults))
        try withSaved(["gestures": old, "holdSeconds": 0.9, "onboarded": true]) { s in
            XCTAssertTrue(GestureRule.sameList(s.gestures, GestureRule.defaults))
            XCTAssertFalse(s.offerRecommended)
            XCTAssertEqual(s.holdSeconds, 0.9)
            XCTAssertTrue(s.onboarded)
        }
    }

    func testCustomisedOldListIsKeptAndTheNewSetOffered() throws {
        var custom = GestureRule.legacyDefaults
        custom[1].action = .lockScreen
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(custom))
        try withSaved(["gestures": old]) { s in
            XCTAssertTrue(GestureRule.sameList(s.gestures, custom))
            XCTAssertTrue(s.offerRecommended)
        }
    }

    func testFirstVersionSettingsCarryOver() throws {
        let old: [String: Any] = [
            "bindings": ["fist": ["action": "mute"], "palmUp": ["action": "appExpose"]],
            "volumeEnabled": false, "holdSeconds": 0.9, "onboarded": true,
        ]
        try withSaved(old) { s in
            XCTAssertEqual(s.holdSeconds, 0.9)
            XCTAssertEqual(s.gestures.first { $0.pose == .fist && $0.motion == .hold }?.action, .mute)
            XCTAssertNil(s.gestures.first { $0.action == .volume })
            XCTAssertTrue(s.offerRecommended)
        }
    }

    // MARK: Hand shapes

    func testPoses() {
        typealias P = SIMD2<Double>
        func hand(_ fingers: Set<Int>, thumb: String = "tucked", ok: Bool = false, relaxed: Bool = false) -> [P] {
            var p = [P](repeating: .zero, count: 21)
            p[0] = P(0.5, 0.8); p[1] = P(0.44, 0.75); p[2] = P(0.37, 0.68)
            let th: [String: (P, P)] = ["tucked": (P(0.42, 0.66), P(0.47, 0.64)), "out": (P(0.32, 0.65), P(0.28, 0.63)), "up": (P(0.35, 0.6), P(0.33, 0.52))]
            (p[3], p[4]) = th[thumb]!
            let mcp = [P(0.44, 0.6), P(0.5, 0.58), P(0.56, 0.6), P(0.61, 0.63)]
            for f in 0..<4 {
                let m = mcp[f], b = 5 + 4 * f
                p[b] = m
                if fingers.contains(f) { p[b+1] = m + P(0, -0.07); p[b+2] = m + P(0, -0.12); p[b+3] = m + P(0, -0.16) }
                else if relaxed { p[b+1] = m + P(0, -0.06); p[b+2] = m + P(0, -0.08); p[b+3] = m + P(0.01, -0.08) }
                else { p[b+1] = m + P(0, -0.045); p[b+2] = m + P(0, -0.01); p[b+3] = m + P(0, 0.02) }
            }
            if ok { p[6] = P(0.43, 0.53); p[7] = P(0.40, 0.52); p[8] = P(0.38, 0.55); p[3] = P(0.35, 0.62); p[4] = P(0.37, 0.56) }
            return p
        }
        let cases: [(Pose, [P])] = [
            (.openPalm, hand([0, 1, 2, 3], thumb: "out")), (.fist, hand([])), (.point, hand([0])),
            (.lShape, hand([0], thumb: "out")), (.v, hand([0, 1])), (.three, hand([0, 1, 2])),
            (.rock, hand([0, 3])), (.shaka, hand([3], thumb: "out")), (.thumbsUp, hand([], thumb: "up")),
            (.ok, hand([1, 2, 3], ok: true)), (.pinch, hand([], ok: true)),
            (.none, hand([], relaxed: true)),   // a relaxed, half-curled hand is not a fist
        ]
        for (expected, pts) in cases { XCTAssertEqual(PoseClassifier.classify(pts), expected, "\(expected)") }

        // Right-click: thumb meets the middle fingertip reaching out, index still up.
        var middle = hand([0])
        middle[10] = P(0.5, 0.52); middle[11] = P(0.49, 0.5); middle[12] = P(0.47, 0.53)
        middle[3] = P(0.42, 0.6); middle[4] = P(0.465, 0.545)
        XCTAssertLessThan(PoseClassifier.middlePinchRatio(middle), 0.3)
        XCTAssertEqual(PoseClassifier.classify(middle), .point)       // keeps holding the pointer
        XCTAssertGreaterThan(PoseClassifier.pinchRatio(middle), 0.3)  // and isn't a left-click
        // A plain point (thumb resting on the curled middle finger), a fist and an open palm never are.
        for (name, pts) in [("point", hand([0])), ("fist", hand([])), ("palm", hand([0, 1, 2, 3], thumb: "out"))] {
            XCTAssertGreaterThan(PoseClassifier.middlePinchRatio(pts), 0.5, name)
        }
    }
}
