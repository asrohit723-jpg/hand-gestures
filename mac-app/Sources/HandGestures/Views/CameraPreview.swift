import SwiftUI

/// Live camera with the tracked hand drawn on top.
struct CameraPreview: View {
    @ObservedObject var state: AppState

    private static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (0, 17), (17, 18), (18, 19), (19, 20),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = state.preview {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                if let img = state.preview {
                    ForEach(Array((state.joints ?? []).enumerated()), id: \.offset) { _, joints in
                        skeleton(joints, in: geo.size, imageAspect: Double(img.width) / Double(img.height))
                    }
                }
                VStack {
                    HStack {
                        badge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
    }

    private var badge: some View {
        let (text, colour): (String, Color) =
            state.pointerMode ? ("Pointer", .orange) : state.awake ? ("Listening", .green) : ("Paused", .gray)
        return HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Joints are 0...1 of the camera frame; the image is aspect-filled, so map through the crop.
    private func skeleton(_ j: [CGPoint], in size: CGSize, imageAspect: Double) -> some View {
        let viewAspect = size.width / size.height
        var drawW = size.width, drawH = size.height
        if imageAspect > viewAspect { drawW = size.height * imageAspect } else { drawH = size.width / imageAspect }
        let ox = (size.width - drawW) / 2, oy = (size.height - drawH) / 2
        let pt = { (p: CGPoint) in CGPoint(x: ox + p.x * drawW, y: oy + p.y * drawH) }
        let colour: Color = state.awake ? .green : .white

        return Canvas { ctx, _ in
            var path = Path()
            for (a, b) in Self.bones where a < j.count && b < j.count {
                path.move(to: pt(j[a]))
                path.addLine(to: pt(j[b]))
            }
            ctx.stroke(path, with: .color(colour.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for p in j {
                let c = pt(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)),
                         with: .color(colour))
            }
        }
        .allowsHitTesting(false)
    }
}
