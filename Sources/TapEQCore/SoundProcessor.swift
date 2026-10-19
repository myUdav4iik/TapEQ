import Foundation

/// How far each effect slider (0–10) pushes the sound. Kept in one place so the DSP,
/// the response-curve display and the tests agree.
public enum EffectTuning {
    public static let bassShelfFrequency = 120.0
    public static let clarityShelfFrequency = 4_500.0

    /// Low-shelf gain: up to +15 dB.
    public static func bassGainDB(_ amount: Float) -> Float { amount * 1.5 }
    /// High-shelf gain: up to +8 dB, on top of the harmonic exciter.
    public static func clarityShelfDB(_ amount: Float) -> Float { amount * 0.8 }
    /// Level of the saturated highs blended back in.
    static func clarityExciterMix(_ amount: Float) -> Float { amount * 0.08 }
    /// Side-signal multiplier for the source's own stereo: up to 3x.
    public static func stereoWidth(_ amount: Float) -> Float { 1 + amount * 0.2 }
    /// Level of the synthesized side signal that widens mono content: up to 0.6.
    public static func synthesizedSideGain(_ amount: Float) -> Float { amount * 0.06 }
    /// Delay of the synthesized side signal (Haas range, so it reads as width, not echo).
    static let surroundDelaySeconds = 0.018
    /// Bass stays centred: only the mid signal above this is used to synthesize width.
    static let surroundHighPassFrequency = 300.0
    /// Reverb send level.
    /// A square-root curve: noticeable from the first steps without drowning the dry sound at 10.
    static func ambienceMix(_ amount: Float) -> Float { 0.3 * amount.squareRoot() }
    /// Reverb comb feedback: the room grows (longer tail) as the slider goes up.
    static func ambienceFeedback(_ amount: Float) -> Float { 0.8 + amount * 0.012 }
    /// Make-up gain of the boost compressor: up to +15 dB for quiet material.
    public static func boostDB(_ amount: Float) -> Float { amount * 1.5 }

    /// Steady-state response (dB) at each of `frequencies`, for drawing. With `includingTone`
    /// the bass and clarity shelves are added to the EQ; the level-dependent stages
    /// (exciter, boost, limiter) are always left out.
    public static func responseCurve(
        of parameters: SoundParameters,
        at frequencies: [Double],
        includingTone: Bool,
        sampleRate: Double = 48_000
    ) -> [Double] {
        var filters = (0..<GraphicEQ.bandCount).map { band in
            BiquadCoefficients.peaking(
                frequency: GraphicEQ.frequencies[band], q: GraphicEQ.q, gainDB: parameters[band: band], sampleRate: sampleRate
            )
        }
        if includingTone {
            filters.append(.lowShelf(frequency: bassShelfFrequency, gainDB: bassGainDB(parameters[.bassBoost]), sampleRate: sampleRate))
            filters.append(.highShelf(frequency: clarityShelfFrequency, gainDB: clarityShelfDB(parameters[.clarity]), sampleRate: sampleRate))
        }
        filters.removeAll { $0 == .identity }
        return frequencies.map { frequency in
            20 * log10(filters.reduce(1) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) })
        }
    }
}

/// The stereo effect chain:
/// bass shelf → 10-band EQ → clarity (shelf + exciter) → surround → ambience
/// → dynamic boost (compressor + make-up gain) → limiter.
///
/// Not thread-safe: owned by one thread (the HAL IO thread in the app). `process`
/// never allocates; all memory is set up in `init`.
final class SoundProcessor {
    /// Peak level the limiter holds the output under (≈ -0.4 dBFS).
    static let limiterCeiling: Float = 0.95
    /// Boost compressor ratio above its threshold.
    static let boostRatio: Float = 4

    private let sampleRate: Double
    private var bass = StereoBiquad()
    private var clarityShelf = StereoBiquad()
    private let eqBands: UnsafeMutableBufferPointer<StereoBiquad>
    /// Indices of EQ bands with non-zero gain; only these are run.
    private let activeBands: UnsafeMutableBufferPointer<Int>
    private var activeBandCount = 0
    private var clarityHighPass: StereoBiquad
    private let reverb: Reverb
    /// Pseudo-stereo (Lauridsen): a delayed, high-passed copy of the mid signal is added to
    /// the left and subtracted from the right. It widens even mono sources and cancels
    /// out again when the output is summed to mono.
    private let surroundDelay: UnsafeMutableBufferPointer<Float>
    private var surroundDelayIndex = 0
    private var surroundHighPass: MonoBiquad

    private var applied: SoundParameters?
    private var bassActive = false
    private var clarityShelfActive = false
    private var clarityMix: Float = 0
    private var stereoWidth: Float = 1
    private var synthesizedSideGain: Float = 0
    private var ambienceMix: Float = 0
    private var boostDB: Float = 0
    private var compressorEnvelope: Float = 0
    private let compressorAttack: Float
    private let compressorRelease: Float
    private var limiterGain: Float = 1
    private let limiterRelease: Float

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        eqBands = .allocate(capacity: GraphicEQ.bandCount)
        eqBands.initialize(repeating: StereoBiquad())
        activeBands = .allocate(capacity: GraphicEQ.bandCount)
        activeBands.initialize(repeating: 0)
        clarityHighPass = StereoBiquad(.highPass(frequency: 3_500, q: 0.707, sampleRate: sampleRate))
        reverb = Reverb(sampleRate: sampleRate)
        surroundDelay = .allocate(capacity: max(1, Int(EffectTuning.surroundDelaySeconds * sampleRate)))
        surroundDelay.initialize(repeating: 0)
        surroundHighPass = MonoBiquad(.highPass(
            frequency: EffectTuning.surroundHighPassFrequency, q: 0.707, sampleRate: sampleRate
        ))
        compressorAttack = Self.smoothing(seconds: 0.005, sampleRate: sampleRate)
        compressorRelease = Self.smoothing(seconds: 0.2, sampleRate: sampleRate)
        limiterRelease = Self.smoothing(seconds: 0.15, sampleRate: sampleRate)
    }

    deinit {
        eqBands.deallocate()
        activeBands.deallocate()
        surroundDelay.deallocate()
    }

    /// One-pole smoothing coefficient for a time constant.
    private static func smoothing(seconds: Double, sampleRate: Double) -> Float {
        Float(exp(-1 / (seconds * sampleRate)))
    }

    /// Recomputes filter coefficients and gains when the parameters changed.
    func apply(_ parameters: SoundParameters) {
        guard parameters != applied else { return }
        let previous = applied
        applied = parameters

        let bassDB = EffectTuning.bassGainDB(parameters[.bassBoost])
        bass.coefficients = .lowShelf(frequency: EffectTuning.bassShelfFrequency, gainDB: bassDB, sampleRate: sampleRate)
        if !bassActive && bassDB > 0 { bass.reset() }
        bassActive = bassDB > 0

        activeBandCount = 0
        for band in 0..<GraphicEQ.bandCount {
            let gain = parameters[band: band]
            eqBands[band].coefficients = .peaking(
                frequency: GraphicEQ.frequencies[band], q: GraphicEQ.q, gainDB: gain, sampleRate: sampleRate
            )
            guard gain != 0 else { continue }
            if previous.map({ $0[band: band] == 0 }) ?? true { eqBands[band].reset() }
            activeBands[activeBandCount] = band
            activeBandCount += 1
        }

        let clarity = parameters[.clarity]
        let shelfDB = EffectTuning.clarityShelfDB(clarity)
        clarityShelf.coefficients = .highShelf(frequency: EffectTuning.clarityShelfFrequency, gainDB: shelfDB, sampleRate: sampleRate)
        if !clarityShelfActive && shelfDB > 0 { clarityShelf.reset() }
        clarityShelfActive = shelfDB > 0
        clarityMix = EffectTuning.clarityExciterMix(clarity)

        stereoWidth = EffectTuning.stereoWidth(parameters[.surround])
        let newSideGain = EffectTuning.synthesizedSideGain(parameters[.surround])
        if synthesizedSideGain == 0 && newSideGain > 0 {
            surroundDelay.update(repeating: 0)
            surroundHighPass.reset()
        }
        synthesizedSideGain = newSideGain
        let newAmbience = EffectTuning.ambienceMix(parameters[.ambience])
        if ambienceMix == 0 && newAmbience > 0 { reverb.reset() }
        ambienceMix = newAmbience
        reverb.setFeedback(EffectTuning.ambienceFeedback(parameters[.ambience]))
        boostDB = EffectTuning.boostDB(parameters[.dynamicBoost])
    }

    /// Processes `frameCount` frames in place.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        for frame in 0..<frameCount {
            var l = Double(left[frame])
            var r = Double(right[frame])

            if bassActive { bass.process(&l, &r) }
            for index in 0..<activeBandCount {
                eqBands[activeBands[index]].process(&l, &r)
            }

            if clarityMix > 0 {
                // Exciter: saturate the highs to add harmonics, then blend them back in.
                var highL = l, highR = r
                clarityHighPass.process(&highL, &highR)
                l += Double(clarityMix * tanhf(Float(highL) * 3))
                r += Double(clarityMix * tanhf(Float(highR) * 3))
            }
            if clarityShelfActive { clarityShelf.process(&l, &r) }

            var outL = Float(l)
            var outR = Float(r)

            if stereoWidth != 1 || synthesizedSideGain > 0 {
                let mid = (outL + outR) * 0.5
                var side = (outL - outR) * 0.5 * stereoWidth
                if synthesizedSideGain > 0 {
                    let delayed = surroundDelay[surroundDelayIndex]
                    surroundDelay[surroundDelayIndex] = Float(surroundHighPass.process(Double(mid)))
                    surroundDelayIndex = surroundDelayIndex + 1 == surroundDelay.count ? 0 : surroundDelayIndex + 1
                    side += delayed * synthesizedSideGain
                }
                outL = mid + side
                outR = mid - side
            }

            if ambienceMix > 0 {
                let wet = reverb.process(left: outL, right: outR)
                outL += wet.left * ambienceMix
                outR += wet.right * ambienceMix
            }

            if boostDB > 0 {
                // Upward-leaning compressor: the threshold sits `boostDB` below full scale,
                // so quiet material gets the full make-up gain and loud material little of it.
                let level = max(abs(outL), abs(outR))
                let coefficient = level > compressorEnvelope ? compressorAttack : compressorRelease
                compressorEnvelope = level + (compressorEnvelope - level) * coefficient
                let envelopeDB = 20 * log10f(max(compressorEnvelope, 1e-6))
                let overshoot = max(0, envelopeDB + boostDB)
                let gain = powf(10, (boostDB - overshoot * (1 - 1 / Self.boostRatio)) / 20)
                outL *= gain
                outR *= gain
            }

            // Peak limiter: instant attack (no overshoot), smooth release.
            let peak = max(abs(outL), abs(outR))
            let target = peak > Self.limiterCeiling ? Self.limiterCeiling / peak : 1
            limiterGain = target < limiterGain ? target : target + (limiterGain - target) * limiterRelease
            outL *= limiterGain
            outR *= limiterGain

            left[frame] = outL
            right[frame] = outR
        }
    }
}
