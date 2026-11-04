import Foundation

/// The One Euro filter (Casiez et al., CHI 2012): smooths a jittery signal heavily
/// when it moves slowly and lightly when it moves fast, so a hand-driven pointer is
/// steady at rest yet doesn't lag behind quick moves.
struct OneEuroFilter {
    var minCutoff = 1.5     // Hz: lower = steadier at rest
    var beta = 0.004        // how quickly the cutoff opens up with speed (per screen point/s)
    var derivativeCutoff = 1.0

    private var value: Double?
    private var speed = 0.0
    private var lastTime: Double?

    mutating func reset(to v: Double) {
        value = v
        speed = 0
    }

    mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let prev = value, let last = lastTime else {
            value = x; lastTime = t
            return x
        }
        let dt = max(t - last, 1e-3)
        lastTime = t
        let a = Self.alpha(derivativeCutoff, dt)
        speed = a * ((x - prev) / dt) + (1 - a) * speed
        let b = Self.alpha(minCutoff + beta * abs(speed), dt)
        let next = b * x + (1 - b) * prev
        value = next
        return next
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
