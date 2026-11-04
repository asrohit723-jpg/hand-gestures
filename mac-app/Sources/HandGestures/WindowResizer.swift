import ApplicationServices
import CoreGraphics

/// Resizes the window under the cursor around its centre (two-hand pinch, "resize" mode).
enum WindowResizer {
    private static var window: AXUIElement?
    private static var startFrame = CGRect.zero

    /// Finds the window under a point. Returns false when there isn't one it can resize.
    @discardableResult
    static func begin(at point: CGPoint) -> Bool {
        window = nil
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return false }
        for _ in 0..<25 {
            if attribute(current, kAXRoleAttribute) as? String == kAXWindowRole as String { window = current; break }
            if let w = attribute(current, kAXWindowAttribute) { window = (w as! AXUIElement); break }
            guard let parent = attribute(current, kAXParentAttribute) else { break }
            current = parent as! AXUIElement
        }
        guard let window, let origin = origin(of: window), let size = size(of: window) else { window = nil; return false }
        startFrame = CGRect(origin: origin, size: size)
        return true
    }

    static func scale(_ factor: Double) {
        guard let window else { return }
        let f = min(max(factor, 0.3), 4)
        var size = CGSize(width: startFrame.width * f, height: startFrame.height * f)
        var origin = CGPoint(x: startFrame.midX - size.width / 2, y: startFrame.midY - size.height / 2)
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
    }

    static func end() { window = nil }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func origin(of e: AXUIElement) -> CGPoint? {
        guard let v = attribute(e, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(of e: AXUIElement) -> CGSize? {
        guard let v = attribute(e, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
