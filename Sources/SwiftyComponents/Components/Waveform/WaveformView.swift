import SwiftUI

public struct WaveformView: View {
    public enum Orientation { case horizontal, vertical }

    public let samples: [Float] // expected 0...1
    public var style: WaveformStyle
    public var mirror: Bool
    public var orientation: Orientation
    public var progress: Double? // 0...1
    public var tint: Color?
    public var fillGradient: (top: Color, bottom: Color)?
    public var progressColor: Color?
    public var progressLineWidth: CGFloat?

    public init(
        samples: [Float],
        style: WaveformStyle = .bars(barWidth: 2, spacing: 1, cornerRadius: 1),
        mirror: Bool = true,
        orientation: Orientation = .horizontal,
        progress: Double? = nil,
        tint: Color? = nil,
        fillGradient: (top: Color, bottom: Color)? = nil,
        progressColor: Color? = nil,
        progressLineWidth: CGFloat? = nil
    ) {
        self.samples = samples
        self.style = style
        self.mirror = mirror
        self.orientation = orientation
        self.progress = progress
        self.tint = tint
        self.fillGradient = fillGradient
        self.progressColor = progressColor
        self.progressLineWidth = progressLineWidth
    }

    public var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let clamped = samples.map { max(0, min(1, $0)) }
            let tintColor = tint ?? Color.accentColor
            let midY = size.height / 2
            let baselineY: CGFloat = mirror ? midY : size.height
            let ampRange: CGFloat = mirror ? midY : size.height

            switch style {
            case let .bars(barWidth, spacing, cornerRadius):
                let count = clamped.count
                let cell = max(1, floor(size.width / CGFloat(count)))
                let width = max(1, min(barWidth, cell - spacing))
                var path = Path()
                for i in 0..<count {
                    let x = CGFloat(i) * cell + (cell - width) / 2
                    let h = max(1, CGFloat(clamped[i]) * (mirror ? midY : size.height))
                    let rect: CGRect
                    if mirror {
                        rect = CGRect(x: x, y: midY - h, width: width, height: h * 2)
                    } else {
                        rect = CGRect(x: x, y: size.height - h, width: width, height: h)
                    }
                    if cornerRadius > 0 {
                        path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
                    } else {
                        path.addRect(rect)
                    }
                }
                context.fill(path, with: .color(tintColor))

            case let .outline(smooth: smooth, lineWidth):
                let count = clamped.count
                let pointsTop: [CGPoint] = (0..<count).map { i in
                    let x = CGFloat(i) / CGFloat(max(1, count - 1)) * size.width
                    let y = baselineY - CGFloat(clamped[i]) * ampRange
                    return CGPoint(x: x, y: y)
                }
                let top: Path = smooth ? Self.catmullRomPath(pointsTop) : Self.polylinePath(pointsTop)
                context.stroke(top, with: .color(tintColor), lineWidth: lineWidth)
                if mirror {
                    let pointsBottom: [CGPoint] = (0..<count).map { i in
                        let x = CGFloat(i) / CGFloat(max(1, count - 1)) * size.width
                        let y = midY + CGFloat(clamped[i]) * midY
                        return CGPoint(x: x, y: y)
                    }
                    let bottom: Path = smooth ? Self.catmullRomPath(pointsBottom) : Self.polylinePath(pointsBottom)
                    context.stroke(bottom, with: .color(tintColor.opacity(0.9)), lineWidth: lineWidth)
                }

            case let .filled(smooth: smooth):
                // Filled under top envelope; mirror fills both sides
                let count = clamped.count
                let pointsTop: [CGPoint] = (0..<count).map { i in
                    let x = CGFloat(i) / CGFloat(max(1, count - 1)) * size.width
                    let y = baselineY - CGFloat(clamped[i]) * ampRange
                    return CGPoint(x: x, y: y)
                }
                let pathTop: Path = smooth
                    ? Self.catmullRomFillPath(pointsTop, baselineY: baselineY)
                    : Self.polylineFillPath(pointsTop, baselineY: baselineY)
                if let g = fillGradient {
                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [g.top, g.bottom]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                    context.fill(pathTop, with: shading)
                } else {
                    context.fill(pathTop, with: .color(tintColor.opacity(0.85)))
                }

                if mirror {
                    let pointsBottom: [CGPoint] = (0..<count).map { i in
                        let x = CGFloat(i) / CGFloat(max(1, count - 1)) * size.width
                        let y = midY + CGFloat(clamped[i]) * midY
                        return CGPoint(x: x, y: y)
                    }
                    let pathBottom: Path = smooth
                        ? Self.catmullRomFillPath(pointsBottom, baselineY: midY)
                        : Self.polylineFillPath(pointsBottom, baselineY: midY)
                    if let g = fillGradient {
                        let shading = GraphicsContext.Shading.linearGradient(
                            Gradient(colors: [g.top, g.bottom]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)
                        )
                        context.fill(pathBottom, with: shading)
                    } else {
                        context.fill(pathBottom, with: .color(tintColor.opacity(0.5)))
                    }
                }
            }

            if let p = progress {
                let x = max(0, min(1, p)) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                let pc = progressColor ?? Color.secondary.opacity(0.6)
                context.stroke(line, with: .color(pc), lineWidth: progressLineWidth ?? 1)
            }
        }
        .accessibilityIdentifier("Waveform.Canvas")
    }
}

// MARK: - Path helpers
extension WaveformView {
    static func polylinePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }

    /// Catmull-Rom to cubic Bezier conversion for a smooth path through points.
    /// Endpoint handling clamps tangents by repeating end points.
    static func catmullRomPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        let n = points.count
        guard n > 1 else { return path }
        path.move(to: points[0])
        for i in 0..<(n - 1) {
            let p0 = i == 0 ? points[0] : points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < n ? points[i + 2] : points[i + 1]
            // Catmull-Rom to Bezier control points (tension = 0.5)
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6.0,
                y: p1.y + (p2.y - p0.y) / 6.0
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6.0,
                y: p2.y - (p3.y - p1.y) / 6.0
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    static func polylineFillPath(_ points: [CGPoint], baselineY: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: baselineY))
        path.addLine(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.addLine(to: CGPoint(x: last.x, y: baselineY))
        path.closeSubpath()
        return path
    }

    static func catmullRomFillPath(_ points: [CGPoint], baselineY: CGFloat) -> Path {
        var path = Path()
        let n = points.count
        guard n > 1 else { return path }
        let first = points[0]
        let last = points[n - 1]
        path.move(to: CGPoint(x: first.x, y: baselineY))
        path.addLine(to: first)
        for i in 0..<(n - 1) {
            let p0 = i == 0 ? points[0] : points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < n ? points[i + 2] : points[i + 1]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6.0,
                y: p1.y + (p2.y - p0.y) / 6.0
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6.0,
                y: p2.y - (p3.y - p1.y) / 6.0
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.addLine(to: CGPoint(x: last.x, y: baselineY))
        path.closeSubpath()
        return path
    }
}
