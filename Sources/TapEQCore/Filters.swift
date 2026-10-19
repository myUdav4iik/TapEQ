import Foundation

/// The 10 octave bands of the graphic equalizer.
public enum GraphicEQ {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    public static var bandCount: Int { frequencies.count }

    public static let gainRange: ClosedRange<Float> = -12...12

    /// Bandwidth of one octave.
    static let q = 2.0.squareRoot()

    /// Short axis label, e.g. "64", "1k", "16k".
    public static func label(forBand index: Int) -> String {
        let frequency = frequencies[index]
        return frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }
}

/// Normalized biquad coefficients (a0 == 1), designed with the RBJ Audio EQ Cookbook formulas.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    public static func peaking(frequency: Double, q: Double, gainDB: Float, sampleRate: Double) -> Self {
        guard gainDB != 0 else { return .identity }
        let a = pow(10, Double(gainDB) / 40)
        let (cosW0, sinW0) = angularTerms(frequency, sampleRate)
        let alpha = sinW0 / (2 * q)
        return Self(
            b0: 1 + alpha * a, b1: -2 * cosW0, b2: 1 - alpha * a,
            a0: 1 + alpha / a, a1: -2 * cosW0, a2: 1 - alpha / a
        )
    }

    /// Low shelf with a slope of 1.
    public static func lowShelf(frequency: Double, gainDB: Float, sampleRate: Double) -> Self {
        guard gainDB != 0 else { return .identity }
        let a = pow(10, Double(gainDB) / 40)
        let (cosW0, sinW0) = angularTerms(frequency, sampleRate)
        let k = 2 * a.squareRoot() * (sinW0 / 2 * 2.0.squareRoot())
        return Self(
            b0: a * ((a + 1) - (a - 1) * cosW0 + k),
            b1: 2 * a * ((a - 1) - (a + 1) * cosW0),
            b2: a * ((a + 1) - (a - 1) * cosW0 - k),
            a0: (a + 1) + (a - 1) * cosW0 + k,
            a1: -2 * ((a - 1) + (a + 1) * cosW0),
            a2: (a + 1) + (a - 1) * cosW0 - k
        )
    }

    /// High shelf with a slope of 1.
    public static func highShelf(frequency: Double, gainDB: Float, sampleRate: Double) -> Self {
        guard gainDB != 0 else { return .identity }
        let a = pow(10, Double(gainDB) / 40)
        let (cosW0, sinW0) = angularTerms(frequency, sampleRate)
        let k = 2 * a.squareRoot() * (sinW0 / 2 * 2.0.squareRoot())
        return Self(
            b0: a * ((a + 1) + (a - 1) * cosW0 + k),
            b1: -2 * a * ((a - 1) + (a + 1) * cosW0),
            b2: a * ((a + 1) + (a - 1) * cosW0 - k),
            a0: (a + 1) - (a - 1) * cosW0 + k,
            a1: 2 * ((a - 1) - (a + 1) * cosW0),
            a2: (a + 1) - (a - 1) * cosW0 - k
        )
    }

    public static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Self {
        let (cosW0, sinW0) = angularTerms(frequency, sampleRate)
        let alpha = sinW0 / (2 * q)
        return Self(
            b0: (1 + cosW0) / 2, b1: -(1 + cosW0), b2: (1 + cosW0) / 2,
            a0: 1 + alpha, a1: -2 * cosW0, a2: 1 - alpha
        )
    }

    /// Linear magnitude of the filter's response at `frequency`.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let numeratorReal = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numeratorImag = -(b1 * sin(w) + b2 * sin(2 * w))
        let denominatorReal = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denominatorImag = -(a1 * sin(w) + a2 * sin(2 * w))
        return (numeratorReal * numeratorReal + numeratorImag * numeratorImag).squareRoot()
            / (denominatorReal * denominatorReal + denominatorImag * denominatorImag).squareRoot()
    }

    /// cos/sin of the normalized angular frequency, kept safely below Nyquist.
    private static func angularTerms(_ frequency: Double, _ sampleRate: Double) -> (Double, Double) {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        return (cos(w0), sin(w0))
    }
}

/// A biquad that filters a stereo pair (transposed direct form II, double-precision state).
struct StereoBiquad {
    var coefficients = BiquadCoefficients.identity
    private var left1 = 0.0, left2 = 0.0, right1 = 0.0, right2 = 0.0

    init(_ coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    @inline(__always)
    mutating func process(_ left: inout Double, _ right: inout Double) {
        let c = coefficients
        let l = c.b0 * left + left1
        left1 = c.b1 * left - c.a1 * l + left2
        left2 = c.b2 * left - c.a2 * l
        left = l

        let r = c.b0 * right + right1
        right1 = c.b1 * right - c.a1 * r + right2
        right2 = c.b2 * right - c.a2 * r
        right = r
    }

    mutating func reset() {
        left1 = 0; left2 = 0; right1 = 0; right2 = 0
    }
}

/// A single-channel biquad (transposed direct form II, double-precision state).
struct MonoBiquad {
    var coefficients: BiquadCoefficients
    private var z1 = 0.0, z2 = 0.0

    init(_ coefficients: BiquadCoefficients) {
        self.coefficients = coefficients
    }

    @inline(__always)
    mutating func process(_ input: Double) -> Double {
        let c = coefficients
        let output = c.b0 * input + z1
        z1 = c.b1 * input - c.a1 * output + z2
        z2 = c.b2 * input - c.a2 * output
        return output
    }

    mutating func reset() {
        z1 = 0; z2 = 0
    }
}
