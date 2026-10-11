import AppKit
import SwiftUI

nonisolated struct NotchShape: InsettableShape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var displayScale: CGFloat = 2
    /// Set by `strokeBorder` so the rim sits wholly inside the silhouette instead of
    /// straddling the edge and bleeding past the clip.
    var inset: CGFloat = 0
    /// How far the bottom edge bows, in points. Positive lifts the bottom corners so the middle
    /// of the edge hangs lower than they do — a drop of liquid about to fall; negative pulls the
    /// middle up instead. The silhouette never grows past its frame: a positive belly is paid
    /// for by the caller making the frame that much taller, so the fill and the clip agree.
    ///
    /// Only the attention gestures set this, and only for a few hundred milliseconds — it is
    /// the wobble after a pop or a nudge. At rest it is always zero.
    var belly: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topCornerRadius, bottomCornerRadius), belly) }
        set {
            // Capture scale in the view; SwiftUI can interpolate shapes off MainActor.
            let scale = max(1, displayScale)
            topCornerRadius = (newValue.first.first * scale).rounded() / scale
            bottomCornerRadius = (newValue.first.second * scale).rounded() / scale
            // Not snapped: the belly is a continuous wobble, and snapping it to device pixels
            // made the settle visibly step on its way back to flat.
            belly = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var shape = self
        shape.inset += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        // Only the sides and bottom are inset: the top edge is flush with the display bezel,
        // and pulling it down would expose a seam.
        let insetRect = CGRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: max(.zero, rect.width - inset * 2),
            height: max(.zero, rect.height - inset)
        )
        return Path(
            Self.cgPath(
                in: insetRect,
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius,
                belly: belly
            )
        )
    }

    static func cgPath(
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        belly: CGFloat = 0
    ) -> CGPath {
        let path = CGMutablePath()
        appendRim(
            to: path,
            in: rect,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            belly: belly
        )
        // The top edge, closing the silhouette back to where the rim began. It is the one
        // segment that is never visible — see `cgRimPath`.
        path.closeSubpath()
        return path
    }

    /// The silhouette's rim: everything except the top edge, as an *open* path that starts at
    /// the top-left corner and ends at the top-right one.
    ///
    /// This exists so the attention ring can be a trim of a path whose whole length is on
    /// screen. The closed silhouette's top edge runs flush along the display bezel, where on a
    /// notched Mac there is no screen to draw on — and it is the single longest segment in the
    /// path. A light travelling the closed path at constant speed therefore spends ~45% of every
    /// cycle invisible: on the 264x32 resting silhouette the top edge is 264 of ~592 points of
    /// perimeter. Trimming this path instead makes the parameter range and the visible rim the
    /// same thing, so a phase of 0...1 is a light that is always somewhere the user can see.
    static func cgRimPath(
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        appendRim(
            to: path,
            in: rect,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
        return path
    }

    private static func appendRim(
        to path: CGMutablePath,
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        belly: CGFloat = 0
    ) {
        let topRadius = min(
            max(topCornerRadius, .zero),
            min(rect.height * 0.4, rect.width * 0.16)
        )
        // The bottom corners are true circular arcs, tangent to the side wall and to the
        // bottom edge. They used to be quadratics whose control point sat in the corner and
        // whose legs were `bottomRadius` tall but only `bottomRadius - topRadius` wide. A
        // quadratic with unequal legs piles all of its curvature onto the short one, so the
        // side wall ran almost straight down and then turned hard at the very bottom — the
        // corner read as clipped rather than rounded. A circular arc distributes curvature
        // evenly, so `bottomRadius` is a radius in the ordinary sense.
        //
        // Both arcs are measured from the side wall, which the inward top corner has already
        // moved in by `topRadius`; the bottom edge's total horizontal inset is therefore
        // `topRadius + bottomRadius`. The width clamp keeps the two arcs from meeting.
        // A belly lifts the corners (positive) or the middle (negative) of the bottom edge;
        // the arcs are measured to wherever the corners now are.
        let cornerY = rect.maxY - max(belly, .zero)
        let middleY = rect.maxY - max(-belly, .zero)
        let bottomRadius = min(
            max(bottomCornerRadius, .zero),
            min(
                max(.zero, cornerY - rect.minY - topRadius),
                max(.zero, rect.width * 0.5 - topRadius)
            )
        )

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // The upper arcs bend into the silhouette. Their outer endpoints stay flush with
        // the display edge while the side walls begin below and inside the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        // `addArc(tangent1End:tangent2End:radius:)` draws the straight run down the side wall
        // for us, then the quarter circle into the bottom edge.
        path.addArc(
            tangent1End: CGPoint(x: rect.minX + topRadius, y: cornerY),
            tangent2End: CGPoint(x: rect.maxX - topRadius, y: cornerY),
            radius: bottomRadius
        )
        if belly != .zero {
            // One cubic across the run between the arcs. Control points at the quarter marks,
            // lowered by 4/3 of the bow, put the curve's middle exactly `belly` from the corners.
            let start = rect.minX + topRadius + bottomRadius
            let end = rect.maxX - topRadius - bottomRadius
            let span = end - start
            let controlY = cornerY + (middleY - cornerY) * 4 / 3
            path.addCurve(
                to: CGPoint(x: end, y: cornerY),
                control1: CGPoint(x: start + span * 0.25, y: controlY),
                control2: CGPoint(x: end - span * 0.25, y: controlY)
            )
        }
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX - topRadius, y: cornerY),
            tangent2End: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius),
            radius: bottomRadius
        )
        path.addLine(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
    }
}

/// The visible rim of the silhouette, as a `Shape` the attention ring can trim.
///
/// Deliberately a separate type rather than a flag on `NotchShape`: `NotchShape` is the
/// clip and the fill for the whole app, and an open path is neither of those things. It
/// carries the same two radii and the same inset behaviour so the rim sits exactly on the
/// silhouette's edge.
nonisolated struct NotchRimShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var displayScale: CGFloat = 2
    /// Matches `NotchShape.inset`, so a rim stroked at width `w` inset by `w / 2` lands wholly
    /// inside the clip instead of straddling it and being cut in half.
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            let scale = max(1, displayScale)
            topCornerRadius = (newValue.first * scale).rounded() / scale
            bottomCornerRadius = (newValue.second * scale).rounded() / scale
        }
    }

    init(_ shape: NotchShape, inset: CGFloat = 0) {
        topCornerRadius = shape.topCornerRadius
        bottomCornerRadius = shape.bottomCornerRadius
        self.inset = shape.inset + inset
        self.displayScale = shape.displayScale
    }

    func path(in rect: CGRect) -> Path {
        // Only the sides and bottom are inset, for the same reason as `NotchShape.path`.
        let insetRect = CGRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: max(.zero, rect.width - inset * 2),
            height: max(.zero, rect.height - inset)
        )
        return Path(
            NotchShape.cgRimPath(
                in: insetRect,
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius
            )
        )
    }
}
