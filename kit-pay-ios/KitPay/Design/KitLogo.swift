import SwiftUI

/// The Kit brand logo, converted from the master SVG into native paths so it renders crisply at
/// any size and inherits Kit's palette. The chat-bubble mark keeps its green sweep exactly as in
/// the source asset (`#34B98B` == `KitColor.green`).
enum KitLogoGeometry {
    /// The full "Kit" lockup: bubble mark plus the K-i-t letterforms.
    static let fullViewBox = CGSize(width: 72.67, height: 26.67)
    /// Just the bubble mark, for circular badges and compact headers. The converted outer
    /// Bézier reaches x ≈ 38.663 and y = 26.69; keep those extrema inside the local view box so
    /// the right and bottom edges are not clipped when the mark is rendered on its own.
    static let markViewBox = CGSize(width: 38.67, height: 26.70)

    static func transform(in rect: CGRect, viewBox: CGSize) -> (CGPoint) -> CGPoint {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let offsetX = rect.minX + (rect.width - viewBox.width * scale) / 2
        let offsetY = rect.minY + (rect.height - viewBox.height * scale) / 2
        return { point in
            CGPoint(x: offsetX + point.x * scale, y: offsetY + point.y * scale)
        }
    }
}

/// The "K", "i", and "t" letterforms.
struct KitLogoLettersShape: Shape {
    var viewBox: CGSize = KitLogoGeometry.fullViewBox

    func path(in rect: CGRect) -> Path {
        let t = KitLogoGeometry.transform(in: rect, viewBox: viewBox)
        var p = Path()
        // K
        p.move(to: t(CGPoint(x: 47.400, y: 4.790)))
        p.addLine(to: t(CGPoint(x: 49.750, y: 4.790)))
        p.addLine(to: t(CGPoint(x: 49.750, y: 10.080)))
        p.addCurve(to: t(CGPoint(x: 49.660, y: 13.230)), control1: t(CGPoint(x: 49.750, y: 11.230)), control2: t(CGPoint(x: 49.700, y: 12.400)))
        p.addLine(to: t(CGPoint(x: 57.910, y: 4.770)))
        p.addLine(to: t(CGPoint(x: 60.850, y: 4.770)))
        p.addLine(to: t(CGPoint(x: 53.970, y: 11.650)))
        p.addLine(to: t(CGPoint(x: 61.400, y: 21.910)))
        p.addLine(to: t(CGPoint(x: 58.660, y: 21.910)))
        p.addLine(to: t(CGPoint(x: 52.340, y: 13.170)))
        p.addLine(to: t(CGPoint(x: 49.740, y: 15.720)))
        p.addLine(to: t(CGPoint(x: 49.740, y: 21.910)))
        p.addLine(to: t(CGPoint(x: 47.390, y: 21.910)))
        p.addLine(to: t(CGPoint(x: 47.390, y: 4.790)))
        p.closeSubpath()
        // i
        p.move(to: t(CGPoint(x: 62.290, y: 4.780)))
        p.addLine(to: t(CGPoint(x: 64.520, y: 4.780)))
        p.addLine(to: t(CGPoint(x: 64.520, y: 7.260)))
        p.addLine(to: t(CGPoint(x: 62.290, y: 7.260)))
        p.addLine(to: t(CGPoint(x: 62.290, y: 4.780)))
        p.closeSubpath()
        p.move(to: t(CGPoint(x: 62.330, y: 9.540)))
        p.addLine(to: t(CGPoint(x: 64.470, y: 9.540)))
        p.addLine(to: t(CGPoint(x: 64.470, y: 21.890)))
        p.addLine(to: t(CGPoint(x: 62.330, y: 21.890)))
        p.addLine(to: t(CGPoint(x: 62.330, y: 9.540)))
        p.closeSubpath()
        // t
        p.move(to: t(CGPoint(x: 66.070, y: 9.060)))
        p.addLine(to: t(CGPoint(x: 68.000, y: 9.060)))
        p.addLine(to: t(CGPoint(x: 68.000, y: 5.170)))
        p.addLine(to: t(CGPoint(x: 70.120, y: 5.170)))
        p.addLine(to: t(CGPoint(x: 70.120, y: 9.060)))
        p.addLine(to: t(CGPoint(x: 72.670, y: 9.060)))
        p.addLine(to: t(CGPoint(x: 72.670, y: 10.720)))
        p.addLine(to: t(CGPoint(x: 70.120, y: 10.720)))
        p.addLine(to: t(CGPoint(x: 70.120, y: 18.510)))
        p.addCurve(to: t(CGPoint(x: 71.380, y: 19.660)), control1: t(CGPoint(x: 70.120, y: 19.410)), control2: t(CGPoint(x: 70.600, y: 19.660)))
        p.addCurve(to: t(CGPoint(x: 72.460, y: 19.500)), control1: t(CGPoint(x: 71.750, y: 19.660)), control2: t(CGPoint(x: 72.230, y: 19.570)))
        p.addLine(to: t(CGPoint(x: 72.530, y: 19.500)))
        p.addLine(to: t(CGPoint(x: 72.530, y: 21.290)))
        p.addCurve(to: t(CGPoint(x: 70.810, y: 21.500)), control1: t(CGPoint(x: 71.960, y: 21.430)), control2: t(CGPoint(x: 71.360, y: 21.500)))
        p.addCurve(to: t(CGPoint(x: 68.010, y: 18.990)), control1: t(CGPoint(x: 69.150, y: 21.480)), control2: t(CGPoint(x: 68.010, y: 20.810)))
        p.addLine(to: t(CGPoint(x: 68.010, y: 10.710)))
        p.addLine(to: t(CGPoint(x: 66.080, y: 10.710)))
        p.addLine(to: t(CGPoint(x: 66.080, y: 9.050)))
        p.closeSubpath()
        return p
    }
}

/// The chat-bubble mark: outer bubble with the rounded inner cut-out (even-odd fill).
struct KitLogoMarkShape: Shape {
    var viewBox: CGSize = KitLogoGeometry.fullViewBox

    func path(in rect: CGRect) -> Path {
        let t = KitLogoGeometry.transform(in: rect, viewBox: viewBox)
        var p = Path()
        // Inner cut-out
        p.move(to: t(CGPoint(x: 19.370, y: 20.030)))
        p.addCurve(to: t(CGPoint(x: 24.170, y: 20.030)), control1: t(CGPoint(x: 20.970, y: 20.030)), control2: t(CGPoint(x: 22.570, y: 20.040)))
        p.addCurve(to: t(CGPoint(x: 30.180, y: 15.450)), control1: t(CGPoint(x: 26.830, y: 20.000)), control2: t(CGPoint(x: 29.430, y: 18.010)))
        p.addCurve(to: t(CGPoint(x: 23.670, y: 6.670)), control1: t(CGPoint(x: 31.480, y: 11.000)), control2: t(CGPoint(x: 28.340, y: 6.750)))
        p.addCurve(to: t(CGPoint(x: 14.880, y: 6.670)), control1: t(CGPoint(x: 20.740, y: 6.620)), control2: t(CGPoint(x: 17.810, y: 6.640)))
        p.addCurve(to: t(CGPoint(x: 9.980, y: 8.760)), control1: t(CGPoint(x: 12.970, y: 6.690)), control2: t(CGPoint(x: 11.270, y: 7.360)))
        p.addCurve(to: t(CGPoint(x: 8.680, y: 15.970)), control1: t(CGPoint(x: 8.040, y: 10.860)), control2: t(CGPoint(x: 7.570, y: 13.350)))
        p.addCurve(to: t(CGPoint(x: 14.710, y: 20.020)), control1: t(CGPoint(x: 9.780, y: 18.570)), control2: t(CGPoint(x: 11.880, y: 19.920)))
        p.addCurve(to: t(CGPoint(x: 19.380, y: 20.030)), control1: t(CGPoint(x: 16.260, y: 20.070)), control2: t(CGPoint(x: 17.820, y: 20.030)))
        p.closeSubpath()
        // Outer bubble
        p.move(to: t(CGPoint(x: 21.390, y: 5.380)))
        p.addCurve(to: t(CGPoint(x: 21.200, y: 3.520)), control1: t(CGPoint(x: 21.280, y: 4.660)), control2: t(CGPoint(x: 21.100, y: 4.110)))
        p.addCurve(to: t(CGPoint(x: 25.740, y: 0.010)), control1: t(CGPoint(x: 21.580, y: 1.220)), control2: t(CGPoint(x: 23.270, y: -0.120)))
        p.addCurve(to: t(CGPoint(x: 34.810, y: 4.000)), control1: t(CGPoint(x: 29.260, y: 0.190)), control2: t(CGPoint(x: 32.310, y: 1.510)))
        p.addCurve(to: t(CGPoint(x: 36.560, y: 20.490)), control1: t(CGPoint(x: 39.180, y: 8.340)), control2: t(CGPoint(x: 39.930, y: 15.340)))
        p.addCurve(to: t(CGPoint(x: 25.220, y: 26.690)), control1: t(CGPoint(x: 33.900, y: 24.550)), control2: t(CGPoint(x: 30.130, y: 26.690)))
        p.addLine(to: t(CGPoint(x: 13.110, y: 26.690)))
        p.addCurve(to: t(CGPoint(x: 0.050, y: 15.000)), control1: t(CGPoint(x: 6.530, y: 26.670)), control2: t(CGPoint(x: 0.810, y: 21.560)))
        p.addCurve(to: t(CGPoint(x: 11.290, y: 0.160)), control1: t(CGPoint(x: -0.770, y: 7.830)), control2: t(CGPoint(x: 4.170, y: 1.320)))
        p.addCurve(to: t(CGPoint(x: 18.410, y: 2.440)), control1: t(CGPoint(x: 14.070, y: -0.290)), control2: t(CGPoint(x: 16.470, y: 0.310)))
        p.addCurve(to: t(CGPoint(x: 20.800, y: 4.840)), control1: t(CGPoint(x: 19.170, y: 3.270)), control2: t(CGPoint(x: 20.000, y: 4.040)))
        p.addCurve(to: t(CGPoint(x: 21.400, y: 5.370)), control1: t(CGPoint(x: 20.950, y: 4.990)), control2: t(CGPoint(x: 21.120, y: 5.130)))
        p.closeSubpath()
        return p
    }
}

/// The diagonal sweep that colors the lower-left of the bubble green (clipped to the mark).
struct KitLogoAccentShape: Shape {
    var viewBox: CGSize = KitLogoGeometry.fullViewBox

    func path(in rect: CGRect) -> Path {
        let t = KitLogoGeometry.transform(in: rect, viewBox: viewBox)
        var p = Path()
        p.move(to: t(CGPoint(x: 5.840, y: 1.880)))
        p.addLine(to: t(CGPoint(x: 30.650, y: 26.700)))
        p.addLine(to: t(CGPoint(x: 17.600, y: 34.520)))
        p.addLine(to: t(CGPoint(x: -11.630, y: 27.620)))
        p.addLine(to: t(CGPoint(x: -6.700, y: 3.000)))
        p.addLine(to: t(CGPoint(x: 5.840, y: 1.880)))
        p.closeSubpath()
        return p
    }
}

/// The full "Kit" lockup. `tint` drives the letterforms and the bubble ring; the green sweep is
/// always brand green.
struct KitLogoView: View {
    var tint: Color = KitColor.navy

    var body: some View {
        ZStack {
            KitLogoMarkShape()
                .fill(tint, style: FillStyle(eoFill: true))
            KitLogoAccentShape()
                .fill(KitColor.green)
                .clipShape(KitLogoMarkShape(), style: FillStyle(eoFill: true))
            KitLogoLettersShape()
                .fill(tint)
        }
        .aspectRatio(
            KitLogoGeometry.fullViewBox.width / KitLogoGeometry.fullViewBox.height,
            contentMode: .fit
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kit")
    }
}

/// The bubble mark alone — the circular-badge treatment used on lock and PIN screens.
struct KitLogoMarkView: View {
    var tint: Color = KitColor.navy

    var body: some View {
        ZStack {
            KitLogoMarkShape(viewBox: KitLogoGeometry.markViewBox)
                .fill(tint, style: FillStyle(eoFill: true))
            KitLogoAccentShape(viewBox: KitLogoGeometry.markViewBox)
                .fill(KitColor.green)
                .clipShape(
                    KitLogoMarkShape(viewBox: KitLogoGeometry.markViewBox),
                    style: FillStyle(eoFill: true)
                )
        }
        .aspectRatio(
            KitLogoGeometry.markViewBox.width / KitLogoGeometry.markViewBox.height,
            contentMode: .fit
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kit")
    }
}
