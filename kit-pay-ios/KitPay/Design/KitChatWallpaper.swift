import SwiftUI
import UIKit

/// Kit Pay's seamless chat wallpaper.
///
/// A repeating motif tile — the wallpaper style WhatsApp popularised — drawn from Kit's own
/// vocabulary rather than copied artwork: secure chat, the wallet token, a shield, a QR frame,
/// transfers, a banknote, and the geometric chevrons and rings that run through Kit's brand.
///
/// Every motif is stroked nine times, once per neighbouring tile offset, and clipped to the tile.
/// A motif that runs off one edge therefore reappears exactly on the opposite edge, so the tile
/// repeats with no visible seam or grid. The tile is rasterised once per colour scheme and display
/// scale and then tiled by UIKit, so scrolling a long conversation never re-runs the drawing.
enum KitChatWallpaper {
    /// Side of one repeating tile, in points.
    static let tileSide: CGFloat = 168

    enum Motif: CaseIterable {
        case chatBubble
        case walletToken
        case shield
        case qrFrame
        case transfer
        case banknote
        case rings
        case chevrons
        case spark
        case lock
    }

    struct Placement {
        let motif: Motif
        /// Centre of the motif within the tile, in points.
        let center: CGPoint
        /// Bounding side of the motif, in points.
        let side: CGFloat
        /// Rotation in degrees.
        let rotation: CGFloat
        /// Relative weight; the accent motifs sit slightly stronger than the filler ones.
        let emphasis: CGFloat
    }

    /// Hand-placed so the repeat reads as a scatter rather than a grid. Positions are deliberately
    /// off-centre and a few motifs overhang the tile edge, which the wrap pass then completes.
    static let placements: [Placement] = [
        Placement(motif: .chatBubble, center: CGPoint(x: 26, y: 24), side: 34, rotation: -9, emphasis: 1.00),
        Placement(motif: .walletToken, center: CGPoint(x: 96, y: 12), side: 30, rotation: 12, emphasis: 0.92),
        Placement(motif: .chevrons, center: CGPoint(x: 150, y: 40), side: 26, rotation: -22, emphasis: 0.74),
        Placement(motif: .shield, center: CGPoint(x: 62, y: 66), side: 30, rotation: 6, emphasis: 0.86),
        Placement(motif: .transfer, center: CGPoint(x: 130, y: 88), side: 34, rotation: -4, emphasis: 0.94),
        Placement(motif: .spark, center: CGPoint(x: 12, y: 92), side: 22, rotation: 0, emphasis: 0.66),
        Placement(motif: .qrFrame, center: CGPoint(x: 40, y: 128), side: 30, rotation: -14, emphasis: 0.90),
        Placement(motif: .banknote, center: CGPoint(x: 108, y: 148), side: 34, rotation: 8, emphasis: 0.82),
        Placement(motif: .rings, center: CGPoint(x: 162, y: 132), side: 26, rotation: 0, emphasis: 0.70),
        Placement(motif: .lock, center: CGPoint(x: 86, y: 104), side: 22, rotation: -8, emphasis: 0.62),
    ]

    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor
    static func tile(colorScheme: ColorScheme, displayScale: CGFloat) -> UIImage {
        let scale = max(1, displayScale)
        let key = "\(colorScheme == .dark ? "dark" : "light")-\(scale)"
        if let cached = cache[key] { return cached }
        let rendered = render(colorScheme: colorScheme, scale: scale)
        cache[key] = rendered
        return rendered
    }

    @MainActor
    private static func render(colorScheme: ColorScheme, scale: CGFloat) -> UIImage {
        let side = tileSide
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        let stroke = strokeColor(for: colorScheme)
        let lineWidth: CGFloat = colorScheme == .dark ? 1.5 : 1.4

        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.clip(to: CGRect(x: 0, y: 0, width: side, height: side))
            cgContext.setLineCap(.round)
            cgContext.setLineJoin(.round)

            for placement in placements {
                let path = path(for: placement.motif)
                for dx in -1...1 {
                    for dy in -1...1 {
                        let origin = CGPoint(
                            x: placement.center.x + CGFloat(dx) * side,
                            y: placement.center.y + CGFloat(dy) * side
                        )
                        // Skip wrapped copies that cannot touch the tile at all.
                        let reach = placement.side
                        guard origin.x > -reach, origin.x < side + reach,
                              origin.y > -reach, origin.y < side + reach
                        else { continue }
                        draw(
                            path: path,
                            at: origin,
                            side: placement.side,
                            rotation: placement.rotation,
                            in: cgContext,
                            color: stroke.withAlphaComponent(
                                stroke.cgColor.alpha * placement.emphasis
                            ),
                            lineWidth: lineWidth
                        )
                    }
                }
            }
        }
    }

    private static func draw(
        path: UIBezierPath,
        at center: CGPoint,
        side: CGFloat,
        rotation: CGFloat,
        in context: CGContext,
        color: UIColor,
        lineWidth: CGFloat
    ) {
        // Motifs are authored in a 0...100 design box, so one transform places any of them.
        let scale = side / 100
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: rotation * .pi / 180)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -50, y: -50)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth / scale)
        context.addPath(path.cgPath)
        context.strokePath()
        context.restoreGState()
    }

    private static func strokeColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark
            ? UIColor(red: 140 / 255, green: 232 / 255, blue: 197 / 255, alpha: 0.13)
            : UIColor(red: 28 / 255, green: 138 / 255, blue: 104 / 255, alpha: 0.17)
    }

    /// Base colour behind the motifs. Light mode is a barely-there mint so green bubbles sit on a
    /// related ground; dark mode is a deep green-black rather than pure grey.
    static func canvasColors(for colorScheme: ColorScheme) -> [Color] {
        colorScheme == .dark
            ? [
                Color(red: 10 / 255, green: 26 / 255, blue: 23 / 255),
                Color(red: 13 / 255, green: 33 / 255, blue: 29 / 255),
                Color(red: 9 / 255, green: 22 / 255, blue: 26 / 255),
            ]
            : [
                Color(red: 244 / 255, green: 251 / 255, blue: 247 / 255),
                Color(red: 233 / 255, green: 247 / 255, blue: 240 / 255),
                Color(red: 240 / 255, green: 248 / 255, blue: 250 / 255),
            ]
    }

    // MARK: - Motif geometry, authored in a 0...100 box

    static func path(for motif: Motif) -> UIBezierPath {
        switch motif {
        case .chatBubble: chatBubblePath()
        case .walletToken: walletTokenPath()
        case .shield: shieldPath()
        case .qrFrame: qrFramePath()
        case .transfer: transferPath()
        case .banknote: banknotePath()
        case .rings: ringsPath()
        case .chevrons: chevronsPath()
        case .spark: sparkPath()
        case .lock: lockPath()
        }
    }

    private static func chatBubblePath() -> UIBezierPath {
        let path = UIBezierPath(
            roundedRect: CGRect(x: 6, y: 12, width: 88, height: 58),
            cornerRadius: 20
        )
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: 30, y: 68))
        tail.addLine(to: CGPoint(x: 26, y: 92))
        tail.addLine(to: CGPoint(x: 52, y: 69))
        path.append(tail)
        return path
    }

    private static func walletTokenPath() -> UIBezierPath {
        let path = UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 88, height: 88))
        let bars = UIBezierPath()
        bars.move(to: CGPoint(x: 32, y: 44))
        bars.addLine(to: CGPoint(x: 68, y: 44))
        bars.move(to: CGPoint(x: 32, y: 58))
        bars.addLine(to: CGPoint(x: 68, y: 58))
        bars.move(to: CGPoint(x: 62, y: 28))
        bars.addLine(to: CGPoint(x: 38, y: 74))
        path.append(bars)
        return path
    }

    private static func shieldPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 50, y: 6))
        path.addLine(to: CGPoint(x: 90, y: 22))
        path.addLine(to: CGPoint(x: 90, y: 52))
        path.addCurve(
            to: CGPoint(x: 50, y: 96),
            controlPoint1: CGPoint(x: 90, y: 76),
            controlPoint2: CGPoint(x: 72, y: 90)
        )
        path.addCurve(
            to: CGPoint(x: 10, y: 52),
            controlPoint1: CGPoint(x: 28, y: 90),
            controlPoint2: CGPoint(x: 10, y: 76)
        )
        path.addLine(to: CGPoint(x: 10, y: 22))
        path.close()
        let check = UIBezierPath()
        check.move(to: CGPoint(x: 33, y: 50))
        check.addLine(to: CGPoint(x: 45, y: 63))
        check.addLine(to: CGPoint(x: 69, y: 36))
        path.append(check)
        return path
    }

    private static func qrFramePath() -> UIBezierPath {
        let path = UIBezierPath()
        let arm: CGFloat = 26
        // Three corner brackets, the way a scanner frames a merchant code.
        path.move(to: CGPoint(x: 8, y: 8 + arm))
        path.addLine(to: CGPoint(x: 8, y: 8))
        path.addLine(to: CGPoint(x: 8 + arm, y: 8))

        path.move(to: CGPoint(x: 92 - arm, y: 8))
        path.addLine(to: CGPoint(x: 92, y: 8))
        path.addLine(to: CGPoint(x: 92, y: 8 + arm))

        path.move(to: CGPoint(x: 8, y: 92 - arm))
        path.addLine(to: CGPoint(x: 8, y: 92))
        path.addLine(to: CGPoint(x: 8 + arm, y: 92))

        path.append(
            UIBezierPath(roundedRect: CGRect(x: 40, y: 40, width: 22, height: 22), cornerRadius: 5)
        )
        return path
    }

    private static func transferPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 14, y: 38))
        path.addLine(to: CGPoint(x: 80, y: 38))
        path.move(to: CGPoint(x: 66, y: 24))
        path.addLine(to: CGPoint(x: 82, y: 38))
        path.addLine(to: CGPoint(x: 66, y: 52))

        path.move(to: CGPoint(x: 86, y: 66))
        path.addLine(to: CGPoint(x: 20, y: 66))
        path.move(to: CGPoint(x: 34, y: 52))
        path.addLine(to: CGPoint(x: 18, y: 66))
        path.addLine(to: CGPoint(x: 34, y: 80))
        return path
    }

    private static func banknotePath() -> UIBezierPath {
        let path = UIBezierPath(
            roundedRect: CGRect(x: 6, y: 26, width: 88, height: 48),
            cornerRadius: 10
        )
        path.append(UIBezierPath(ovalIn: CGRect(x: 38, y: 36, width: 24, height: 28)))
        let ticks = UIBezierPath()
        ticks.move(to: CGPoint(x: 20, y: 42))
        ticks.addLine(to: CGPoint(x: 20, y: 58))
        ticks.move(to: CGPoint(x: 80, y: 42))
        ticks.addLine(to: CGPoint(x: 80, y: 58))
        path.append(ticks)
        return path
    }

    private static func ringsPath() -> UIBezierPath {
        let path = UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 84, height: 84))
        path.append(UIBezierPath(ovalIn: CGRect(x: 30, y: 30, width: 40, height: 40)))
        return path
    }

    private static func chevronsPath() -> UIBezierPath {
        let path = UIBezierPath()
        for index in 0..<3 {
            let offset = CGFloat(index) * 26
            path.move(to: CGPoint(x: 30, y: 14 + offset))
            path.addLine(to: CGPoint(x: 62, y: 27 + offset))
            path.addLine(to: CGPoint(x: 30, y: 40 + offset))
        }
        return path
    }

    private static func sparkPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 50, y: 2))
        path.addCurve(
            to: CGPoint(x: 98, y: 50),
            controlPoint1: CGPoint(x: 56, y: 34),
            controlPoint2: CGPoint(x: 66, y: 44)
        )
        path.addCurve(
            to: CGPoint(x: 50, y: 98),
            controlPoint1: CGPoint(x: 66, y: 56),
            controlPoint2: CGPoint(x: 56, y: 66)
        )
        path.addCurve(
            to: CGPoint(x: 2, y: 50),
            controlPoint1: CGPoint(x: 44, y: 66),
            controlPoint2: CGPoint(x: 34, y: 56)
        )
        path.addCurve(
            to: CGPoint(x: 50, y: 2),
            controlPoint1: CGPoint(x: 34, y: 44),
            controlPoint2: CGPoint(x: 44, y: 34)
        )
        path.close()
        return path
    }

    private static func lockPath() -> UIBezierPath {
        let path = UIBezierPath(
            roundedRect: CGRect(x: 20, y: 44, width: 60, height: 48),
            cornerRadius: 12
        )
        let shackle = UIBezierPath()
        shackle.move(to: CGPoint(x: 33, y: 44))
        shackle.addLine(to: CGPoint(x: 33, y: 30))
        shackle.addCurve(
            to: CGPoint(x: 67, y: 30),
            controlPoint1: CGPoint(x: 33, y: 10),
            controlPoint2: CGPoint(x: 67, y: 10)
        )
        shackle.addLine(to: CGPoint(x: 67, y: 44))
        path.append(shackle)
        return path
    }
}

/// The chat surface behind message bubbles.
///
/// Reduce Transparency and Increase Contrast users get the flat brand canvas instead of the
/// pattern, so bubble edges never have to compete with wallpaper strokes.
struct KitChatWallpaperView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale

    private var showsPattern: Bool {
        !reduceTransparency && colorSchemeContrast != .increased
    }

    var body: some View {
        ZStack {
            if showsPattern {
                LinearGradient(
                    colors: KitChatWallpaper.canvasColors(for: colorScheme),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(
                    uiImage: KitChatWallpaper.tile(
                        colorScheme: colorScheme,
                        displayScale: displayScale
                    )
                )
                .resizable(resizingMode: .tile)
                // A soft vignette keeps the pattern quietest exactly where bubbles cluster.
                .mask {
                    RadialGradient(
                        colors: [.white.opacity(0.55), .white],
                        center: .center,
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            } else {
                KitColor.canvas
            }
        }
        .accessibilityHidden(true)
    }
}
