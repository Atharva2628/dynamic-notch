import SwiftUI

/// The notch outline: concave fillets where it meets the top edge, so it flares into the
/// menu bar like the hardware notch, and rounded bottom corners. The body is inset from
/// the frame by `fillet` on each side.
struct NotchShape: Shape {
    var fillet: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fillet, bottomRadius) }
        set { fillet = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(fillet, rect.width / 4, rect.height / 2))
        let r = max(0, min(bottomRadius, (rect.width - 2 * f) / 2, rect.height - f))
        let left = rect.minX + f, right = rect.maxX - f
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + f), control: CGPoint(x: left, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: r)
        p.addLine(to: CGPoint(x: right, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
