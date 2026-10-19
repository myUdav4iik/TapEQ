import SwiftUI
import TapEQCore

/// The live spectrum drawn with block characters, three rows tall.
struct AsciiSpectrum: View {
    let levels: [Float]
    let isActive: Bool

    private static let rows = 3
    private static let blocks: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    var body: some View {
        Text(art)
            .font(Style.mono(11))
            .lineSpacing(0)
            // Never wrap or truncate a row; shrink the whole block instead.
            .lineLimit(Self.rows)
            .minimumScaleFactor(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isActive ? Style.text : Style.border)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
    }

    /// Each column's height in eighths of a row; at least one eighth so silence reads as a baseline.
    private var art: String {
        let heights = levels.map { max(1, Int((CGFloat($0) * CGFloat(Self.rows * 8)).rounded())) }
        return (0..<Self.rows).reversed().map { row in
            String(heights.map { Self.blocks[min(max($0 - row * 8, 0), 8)] })
        }
        .joined(separator: "\n")
    }
}

/// Response graph with one handle per band. Click or drag anywhere in a band's column
/// to set its gain. The dashed curve adds the Bass Boost and Clarity shelves.
struct EQCurveEditor: View {
    @Binding var parameters: SoundParameters
    @State private var activeBand: Int?

    /// Vertical span of the graph, ±dB.
    private let displayRange = 16.0
    private let curvePoints = 120

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let band = activeBand ?? nearestBand(toX: drag.startLocation.x, width: size.width)
                            activeBand = band
                            parameters[band: band] = gain(atY: drag.location.y, height: size.height)
                        }
                        .onEnded { _ in activeBand = nil }
                )
            }
            .frame(height: 104)

            HStack(spacing: 0) {
                ForEach(0..<GraphicEQ.bandCount, id: \.self) { band in
                    Text(GraphicEQ.label(forBand: band))
                        .foregroundStyle(activeBand == band ? Style.text : Style.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(Style.mono(9))

            Text(caption)
                .font(Style.mono(10))
                .foregroundStyle(Style.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityRepresentation {
            VStack {
                ForEach(0..<GraphicEQ.bandCount, id: \.self) { band in
                    Slider(
                        value: Binding(get: { parameters[band: band] }, set: { parameters[band: band] = $0 }),
                        in: GraphicEQ.gainRange,
                        step: 0.5
                    ) {
                        Text("\(GraphicEQ.label(forBand: band)) hertz")
                    }
                }
            }
        }
    }

    private var caption: String {
        guard let activeBand else { return "drag to shape · dashed = with bass/clarity" }
        let gain = parameters[band: activeBand]
        let value = gain == 0 ? "0.0" : String(format: "%+.1f", gain)
        return "\(GraphicEQ.label(forBand: activeBand))hz  \(value)db"
    }

    // MARK: Geometry

    /// Bands sit at the centres of equal-width columns; octave bands are evenly spaced
    /// on a log axis, so position follows log2(frequency).
    private func x(forFrequency frequency: Double, width: CGFloat) -> CGFloat {
        let position = log2(frequency / GraphicEQ.frequencies[0]) + 0.5
        return CGFloat(position / Double(GraphicEQ.bandCount)) * width
    }

    private func y(forDB decibels: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(decibels, -displayRange), displayRange)
        return height / 2 - CGFloat(clamped / displayRange) * (height / 2 - 6)
    }

    private func gain(atY y: CGFloat, height: CGFloat) -> Float {
        let decibels = Double((height / 2 - y) / (height / 2 - 6)) * displayRange
        return (Float(decibels) * 2).rounded() / 2
    }

    private func nearestBand(toX x: CGFloat, width: CGFloat) -> Int {
        let column = Int(x / width * CGFloat(GraphicEQ.bandCount))
        return min(max(column, 0), GraphicEQ.bandCount - 1)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        func horizontalLine(at y: CGFloat) -> Path {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            return line
        }

        for decibels in [-12.0, -6, 6, 12] {
            context.stroke(
                horizontalLine(at: y(forDB: decibels, height: size.height)),
                with: .color(Style.faint), style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
        }
        context.stroke(horizontalLine(at: y(forDB: 0, height: size.height)), with: .color(Style.border), lineWidth: 1)

        // Frequencies spanning the full width (half a column beyond the outer bands).
        let frequencies = (0..<curvePoints).map { index in
            GraphicEQ.frequencies[0] * pow(2, Double(index) / Double(curvePoints - 1) * Double(GraphicEQ.bandCount) - 0.5)
        }
        func path(_ decibels: [Double]) -> Path {
            Path.smoothCurve(through: zip(frequencies, decibels).map { frequency, value in
                CGPoint(x: x(forFrequency: frequency, width: size.width), y: y(forDB: value, height: size.height))
            })
        }

        let toneCurve = EffectTuning.responseCurve(of: parameters, at: frequencies, includingTone: true)
        context.stroke(path(toneCurve), with: .color(Style.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let eqCurve = EffectTuning.responseCurve(of: parameters, at: frequencies, includingTone: false)
        context.stroke(path(eqCurve), with: .color(Style.text), lineWidth: 1.5)

        for band in 0..<GraphicEQ.bandCount {
            let center = CGPoint(
                x: x(forFrequency: GraphicEQ.frequencies[band], width: size.width),
                y: y(forDB: Double(parameters[band: band]), height: size.height)
            )
            let radius: CGFloat = activeBand == band ? 6 : 4
            let handle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(handle, with: .color(Style.text))
        }
    }
}

extension Path {
    /// A smooth curve through `points` (quadratic segments between midpoints).
    static func smoothCurve(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let midpoint = CGPoint(
                x: (points[index].x + points[index + 1].x) / 2,
                y: (points[index].y + points[index + 1].y) / 2
            )
            path.addQuadCurve(to: midpoint, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
