import Accelerate
import Synchronization

/// Single-producer ring buffer of the processed mono signal, for the visualizer.
///
/// The audio thread writes, the UI reads the most recent window. A reader that races
/// a writer may see a few samples from the next cycle; that's harmless for a display.
public final class SpectrumBuffer: @unchecked Sendable {
    static let capacity = 8_192 // power of two
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)

    public init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { storage.deallocate() }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let start = writeIndex.load(ordering: .relaxed)
        for offset in 0..<count {
            storage[(start + offset) & (Self.capacity - 1)] = samples[offset]
        }
        writeIndex.store(start + count, ordering: .releasing)
    }

    /// Copies the latest `destination.count` samples, oldest first.
    func copyLatest(into destination: UnsafeMutableBufferPointer<Float>) {
        let end = writeIndex.load(ordering: .acquiring)
        let count = min(destination.count, Self.capacity)
        for offset in 0..<count {
            destination[offset] = storage[(end - count + offset) & (Self.capacity - 1)]
        }
    }
}

/// Turns the latest audio into log-spaced bar heights (0...1) for the visualizer.
/// Main-thread use only.
public final class SpectrumAnalyzer {
    private static let log2n: vDSP_Length = 11
    private static let size = 1 << 11
    private static let floorDB: Float = -72

    public let barCount: Int
    private let setup: FFTSetup
    private let window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var bars: [Float]

    public init(barCount: Int) {
        self.barCount = barCount
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for a fixed, valid size")
        }
        self.setup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        samples = Array(repeating: 0, count: Self.size)
        real = Array(repeating: 0, count: Self.size / 2)
        imaginary = Array(repeating: 0, count: Self.size / 2)
        magnitudes = Array(repeating: 0, count: Self.size / 2)
        bars = Array(repeating: 0, count: barCount)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Analyzes the newest audio in `buffer`; bars rise instantly and fall smoothly.
    public func update(from buffer: SpectrumBuffer, sampleRate: Double) -> [Float] {
        samples.withUnsafeMutableBufferPointer { buffer.copyLatest(into: $0) }
        vDSP.multiply(samples, window, result: &samples)

        let half = Self.size / 2
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let binWidth = sampleRate / Double(Self.size)
        let lowest = 30.0
        let highest = min(18_000, sampleRate / 2)
        // A full-scale sine lands at roughly (size / 2)^2 in the squared magnitudes.
        let reference = Float(half * half)

        for bar in 0..<barCount {
            let lower = lowest * pow(highest / lowest, Double(bar) / Double(barCount))
            let upper = lowest * pow(highest / lowest, Double(bar + 1) / Double(barCount))
            let firstBin = min(half - 1, max(1, Int(lower / binWidth)))
            let lastBin = min(half - 1, max(firstBin, Int(upper / binWidth)))
            var peak: Float = 0
            for bin in firstBin...lastBin { peak = max(peak, magnitudes[bin]) }

            let decibels = 10 * log10(max(peak / reference, 1e-12))
            let height = min(max((decibels - Self.floorDB) / -Self.floorDB, 0), 1)
            bars[bar] = max(height, bars[bar] * 0.82)
        }
        return bars
    }

    public func reset() {
        for index in bars.indices { bars[index] = 0 }
    }
}
