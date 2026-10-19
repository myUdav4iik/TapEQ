/// The effect sliders, each ranging over `Effect.range`.
public enum Effect: Int, CaseIterable, Identifiable, Sendable {
    case clarity
    case ambience
    case surround
    case dynamicBoost
    case bassBoost

    public static let range: ClosedRange<Float> = 0...10

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .clarity: "Clarity"
        case .ambience: "Ambience"
        case .surround: "Surround Sound"
        case .dynamicBoost: "Dynamic Boost"
        case .bassBoost: "Bass Boost"
        }
    }
}

/// Every user-facing processing parameter. A plain value type with no heap storage,
/// so the audio thread can copy it without allocating.
public struct SoundParameters: Equatable, Sendable, Codable {
    /// Effect amounts, indexed by `Effect.rawValue`.
    private var effects = SIMD8<Float>()
    /// Graphic EQ gains in dB, indexed by band (lanes past `GraphicEQ.bandCount` are unused).
    private var eqGains = SIMD16<Float>()

    public init() {}

    public init(effects: [Effect: Float], eqGains: [Float]) {
        for (effect, value) in effects { self[effect] = value }
        for (band, gain) in eqGains.prefix(GraphicEQ.bandCount).enumerated() { self[band: band] = gain }
    }

    public subscript(effect: Effect) -> Float {
        get { effects[effect.rawValue] }
        set { effects[effect.rawValue] = min(max(newValue, Effect.range.lowerBound), Effect.range.upperBound) }
    }

    public subscript(band band: Int) -> Float {
        get { eqGains[band] }
        set { eqGains[band] = min(max(newValue, GraphicEQ.gainRange.lowerBound), GraphicEQ.gainRange.upperBound) }
    }
}
