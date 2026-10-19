import Foundation

public struct SoundPreset: Identifiable, Sendable {
    public let name: String
    public let parameters: SoundParameters

    public var id: String { name }

    /// Built-in presets. The EQ curves are given as a few (Hz, dB) anchor points and
    /// interpolated across the bands on a log-frequency axis.
    public static let builtIn: [SoundPreset] = [
        SoundPreset(name: "Flat", effects: [:], curve: [(20, 0)]),
        SoundPreset(
            name: "Music",
            effects: [.clarity: 3, .ambience: 2, .surround: 3, .dynamicBoost: 3, .bassBoost: 4],
            curve: [(32, 3), (64, 3), (250, 0), (1_000, -1), (4_000, 1), (16_000, 4)]
        ),
        SoundPreset(
            name: "Movies",
            effects: [.clarity: 3, .ambience: 4, .surround: 6, .dynamicBoost: 5, .bassBoost: 4],
            curve: [(32, 4), (125, 1), (500, -1), (2_000, 3), (4_000, 3), (16_000, 1)]
        ),
        SoundPreset(
            name: "Gaming",
            effects: [.clarity: 5, .ambience: 1, .surround: 7, .dynamicBoost: 4, .bassBoost: 2],
            curve: [(32, 1), (250, -2), (1_000, 0), (2_000, 3), (4_000, 5), (8_000, 2), (16_000, 0)]
        ),
        SoundPreset(
            name: "Voice",
            effects: [.clarity: 4, .dynamicBoost: 6],
            curve: [(32, -10), (125, -6), (250, -2), (1_000, 1), (2_000, 4), (4_000, 3), (16_000, -3)]
        ),
        SoundPreset(
            name: "Bass",
            effects: [.clarity: 2, .dynamicBoost: 3, .bassBoost: 8],
            curve: [(32, 6), (64, 6), (125, 3), (250, 0), (16_000, 0)]
        ),
    ]

    public init(name: String, parameters: SoundParameters) {
        self.name = name
        self.parameters = parameters
    }

    init(name: String, effects: [Effect: Float], curve anchors: [(hz: Double, db: Float)]) {
        let gains = GraphicEQ.frequencies.map { Self.interpolate(anchors, at: $0) }
        self.init(name: name, parameters: SoundParameters(effects: effects, eqGains: gains))
    }

    private static func interpolate(_ anchors: [(hz: Double, db: Float)], at frequency: Double) -> Float {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if frequency <= first.hz { return first.db }
        if frequency >= last.hz { return last.db }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where frequency <= upper.hz {
            let t = Float(log(frequency / lower.hz) / log(upper.hz / lower.hz))
            // Round to the sliders' 0.5 dB step.
            return ((lower.db + (upper.db - lower.db) * t) * 2).rounded() / 2
        }
        return last.db
    }
}
