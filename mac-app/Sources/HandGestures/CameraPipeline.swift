import AVFoundation
import CoreImage
import Vision

/// What one processed frame produced, delivered on the camera queue.
struct FrameOutput {
    var events: [GestureEvent]
    var pose: Pose
    var handVisible: Bool
    var awake: Bool
    var pointerMode: Bool
    var joints: [CGPoint]?     // mirrored 0...1, origin top-left, for the preview overlay
    var preview: CGImage?
}

/// Camera -> Apple Vision hand pose -> Recognizer, all off the main thread.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "hand-gestures.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var recognizer: Recognizer
    private let clockStart = CACurrentMediaTime()
    private var frameCount = 0

    /// Set from the main thread; read on the camera queue.
    var wantsPreview = false
    var onFrame: ((FrameOutput) -> Void)?

    init(settings: Settings) {
        recognizer = Recognizer(settings: settings)
        super.init()
    }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    /// The saved camera, else the Mac's own camera, else anything.
    static func pickCamera(_ id: String?) -> AVCaptureDevice? {
        let all = cameras()
        if let id, let d = all.first(where: { $0.uniqueID == id }) { return d }
        return all.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? all.first
    }

    func update(settings: Settings) {
        queue.async { self.recognizer.settings = settings }
    }

    func start(cameraID: String?) throws {
        guard let device = Self.pickCamera(cameraID) else {
            throw NSError(domain: "HandGestures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found."])
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "HandGestures", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Can't use \(device.localizedName)."])
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        let t = CACurrentMediaTime() - clockStart
        frameCount += 1

        var joints: [CGPoint]?
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        if (try? handler.perform([request])) != nil,
           let obs = request.results?.first, obs.confidence > 0.5,
           let points = try? obs.recognizedPoints(.all),
           let wrist = points[.wrist], wrist.confidence > 0.3 {
            // Vision: origin bottom-left. Mirror x so your right is right, flip y.
            joints = Self.jointOrder.map { name in
                guard let p = points[name] else { return CGPoint(x: 1 - wrist.location.x, y: 1 - wrist.location.y) }
                return CGPoint(x: 1 - p.location.x, y: 1 - p.location.y)
            }
        }

        var hand: Hand?
        if let j = joints {
            let aspect = width / height
            let scaled = j.map { SIMD2<Double>(Double($0.x) * aspect, Double($0.y)) }
            let palmIdx = [0, 5, 9, 13, 17]
            let cx = palmIdx.map { Double(j[$0].x) }.reduce(0, +) / 5
            let cy = palmIdx.map { Double(j[$0].y) }.reduce(0, +) / 5
            hand = Hand(pose: PoseClassifier.classify(scaled), center: CGPoint(x: cx, y: cy), tip: j[8])
        }

        let events = recognizer.update(t: t, hand: hand)

        var preview: CGImage?
        if wantsPreview && frameCount % 2 == 0 {
            let image = CIImage(cvPixelBuffer: pixels)
            let scale = 360 / width
            let small = image.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
            preview = ciContext.createCGImage(small, from: small.extent)
        }

        onFrame?(FrameOutput(events: events, pose: hand == nil ? .none : recognizer.pose,
                             handVisible: hand != nil, awake: recognizer.awake,
                             pointerMode: recognizer.pointerMode, joints: joints, preview: preview))
    }
}
