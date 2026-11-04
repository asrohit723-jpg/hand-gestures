import simd

/// Classifies 21 hand joints into a Pose.
///
/// Joint order: 0 wrist; thumb 1-4 (CMC, MP, IP, tip); index 5-8; middle 9-12;
/// ring 13-16; little 17-20 (MCP, PIP, DIP, tip). Points are in a space where x
/// and y use the same unit, with y growing downward.
enum PoseClassifier {
    typealias P = SIMD2<Double>

    static let fingers: [(mcp: Int, pip: Int, tip: Int)] = [(5, 6, 8), (9, 10, 12), (13, 14, 16), (17, 18, 20)]

    static func cosine(_ a: P, _ b: P) -> Double {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 1e-9, lb > 1e-9 else { return 0 }
        return simd_dot(a, b) / (la * lb)
    }

    static func dist(_ a: P, _ b: P) -> Double { simd_distance(a, b) }

    static func fingerExtended(_ p: [P], _ f: (mcp: Int, pip: Int, tip: Int)) -> Bool {
        let straight = cosine(p[f.pip] - p[f.mcp], p[f.tip] - p[f.pip]) > 0.5
        let reachesOut = dist(p[f.tip], p[0]) > 1.1 * dist(p[f.pip], p[0])
        return straight && reachesOut
    }

    static func thumbExtended(_ p: [P], palm: Double) -> Bool {
        let straight = cosine(p[3] - p[2], p[4] - p[3]) > 0.6
        let awayFromLittle = dist(p[4], p[17]) > 1.1 * dist(p[2], p[17])
        let awayFromIndex = dist(p[4], p[5]) > 0.55 * palm
        return straight && awayFromLittle && awayFromIndex
    }

    /// Thumb tip to index tip, in palm lengths. Small = pinching.
    static func pinchRatio(_ p: [P]) -> Double {
        guard p.count == 21 else { return .infinity }
        let palm = dist(p[9], p[0])
        return palm > 1e-6 ? dist(p[4], p[8]) / palm : .infinity
    }

    static func classify(_ p: [P]) -> Pose {
        guard p.count == 21 else { return .none }
        let palm = dist(p[9], p[0])
        guard palm > 1e-6 else { return .none }
        let ext = fingers.map { fingerExtended(p, $0) }
        let (i, m, r, k) = (ext[0], ext[1], ext[2], ext[3])
        let thumb = thumbExtended(p, palm: palm)

        // Thumb and index tips touching. With the other fingers up it's an OK sign;
        // otherwise a pinch, as long as the index reaches out past its knuckle
        // (in a fist the tips can touch too, but the index is curled into the palm).
        if pinchRatio(p) < 0.3 {
            if m && r && k { return .ok }
            if dist(p[8], p[0]) > dist(p[5], p[0]) { return .pinch }
        }
        if i && m && r && k { return .openPalm }
        if i && m && r && !k { return .three }
        if i && m && !r && !k { return .v }
        if i && k && !m && !r { return .rock }
        if k && thumb && !i && !m && !r { return .shaka }
        if i && !m && !r && !k {
            // Index alone: an L when the thumb sticks out well away from it (> ~50°).
            if thumb && cosine(p[4] - p[2], p[8] - p[5]) < 0.64 { return .lShape }
            return .point
        }
        if !(i || m || r || k) {
            let thumbDir = p[4] - p[2]
            if thumb && simd_length(thumbDir) > 0 && thumbDir.y / simd_length(thumbDir) < -0.7 { return .thumbsUp }
            // A real fist has every fingertip tucked in, no further from the wrist than
            // its knuckle. A relaxed, half-curled hand doesn't, so it stays "none" and
            // can move the pointer without firing the fist's action.
            let tucked = fingers.allSatisfy { dist(p[$0.tip], p[0]) <= 1.05 * dist(p[$0.mcp], p[0]) }
            if !thumb && tucked { return .fist }
        }
        return .none
    }
}
