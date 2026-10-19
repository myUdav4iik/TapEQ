import CoreAudio
import Foundation
import Testing
@testable import TapEQCore

private let sampleRate = 48_000.0

private func decibels(_ linear: Double) -> Double { 20 * log10(linear) }

@Suite("Filters")
struct FilterTests {
    @Test func zeroGainIsIdentity() {
        #expect(BiquadCoefficients.peaking(frequency: 1_000, q: 1, gainDB: 0, sampleRate: sampleRate) == .identity)
        #expect(BiquadCoefficients.lowShelf(frequency: 100, gainDB: 0, sampleRate: sampleRate) == .identity)
    }

    @Test func lowShelfBoostsLowsOnly() {
        let c = BiquadCoefficients.lowShelf(frequency: 100, gainDB: 6, sampleRate: sampleRate)
        #expect(abs(decibels(c.magnitude(at: 10, sampleRate: sampleRate)) - 6) < 0.05)
        #expect(abs(decibels(c.magnitude(at: 10_000, sampleRate: sampleRate))) < 0.05)
    }

    @Test(arguments: [0, 3, 5, 8, 9])
    func graphicBandHitsGainAtItsCenter(band: Int) {
        let frequency = GraphicEQ.frequencies[band]
        let c = BiquadCoefficients.peaking(frequency: frequency, q: GraphicEQ.q, gainDB: -9, sampleRate: sampleRate)
        #expect(abs(decibels(c.magnitude(at: frequency, sampleRate: sampleRate)) + 9) < 0.01)
        // Three octaves away the octave band has little effect.
        let far = frequency < 1_000 ? frequency * 8 : frequency / 8
        #expect(abs(decibels(c.magnitude(at: far, sampleRate: sampleRate))) < 0.6)
    }

    @Test func highPassRejectsLows() {
        let c = BiquadCoefficients.highPass(frequency: 3_500, q: 0.707, sampleRate: sampleRate)
        #expect(decibels(c.magnitude(at: 200, sampleRate: sampleRate)) < -40)
        #expect(abs(decibels(c.magnitude(at: 15_000, sampleRate: sampleRate))) < 0.5)
    }

    @Test func highShelfBoostsHighsOnly() {
        let c = BiquadCoefficients.highShelf(frequency: 4_500, gainDB: 8, sampleRate: sampleRate)
        #expect(abs(decibels(c.magnitude(at: 23_900, sampleRate: sampleRate)) - 8) < 0.1)
        #expect(abs(decibels(c.magnitude(at: 100, sampleRate: sampleRate))) < 0.05)
    }

    @Test func graphicEQHasTenLabelledOctaveBands() {
        #expect(GraphicEQ.bandCount == 10)
        #expect(GraphicEQ.label(forBand: 0) == "32")
        #expect(GraphicEQ.label(forBand: 4) == "500")
        #expect(GraphicEQ.label(forBand: 5) == "1k")
        #expect(GraphicEQ.label(forBand: 9) == "16k")
    }

    @Test func responseCurveIncludesToneShelves() {
        var parameters = SoundParameters()
        parameters[.bassBoost] = 10
        parameters[.clarity] = 10
        parameters[band: 5] = -6
        let frequencies = [20.0, 1_000, 20_000]
        let total = EffectTuning.responseCurve(of: parameters, at: frequencies, includingTone: true)
        let equalizer = EffectTuning.responseCurve(of: parameters, at: frequencies, includingTone: false)
        #expect(abs(total[0] - 15) < 0.3)
        #expect(abs(total[2] - 8) < 0.5)
        #expect(abs(equalizer[1] + 6) < 0.05)
        #expect(abs(equalizer[0]) < 0.2)
    }
}

@Suite("Parameters and presets")
struct ParameterTests {
    @Test func valuesAreClampedToTheirRanges() {
        var parameters = SoundParameters()
        parameters[.clarity] = 42
        parameters[band: 3] = -40
        #expect(parameters[.clarity] == 10)
        #expect(parameters[band: 3] == -12)
    }

    @Test func presetsHaveUniqueNamesAndValidValues() {
        let names = SoundPreset.builtIn.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(SoundPreset.builtIn.first?.parameters == SoundParameters())
        for preset in SoundPreset.builtIn {
            for band in 0..<GraphicEQ.bandCount {
                #expect(GraphicEQ.gainRange.contains(preset.parameters[band: band]))
            }
        }
    }

    @Test func parametersRoundTripThroughJSON() throws {
        let original = SoundPreset.builtIn[1].parameters
        let decoded = try JSONDecoder().decode(SoundParameters.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

/// An `AudioBufferList` whose buffers each hold `channels[i]` interleaved channels.
private final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer

    init(channels: [Int], frameCount: Int, value: (_ channel: Int, _ frame: Int) -> Float = { _, _ in 0 }) {
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        var firstChannel = 0
        for (index, count) in channels.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: count * frameCount)
            for frame in 0..<frameCount {
                for offset in 0..<count {
                    samples[frame * count + offset] = value(firstChannel + offset, frame)
                }
            }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(count),
                mDataByteSize: UInt32(count * frameCount * MemoryLayout<Float>.size),
                mData: samples
            )
            firstChannel += count
        }
    }

    deinit {
        for buffer in list { buffer.mData?.assumingMemoryBound(to: Float.self).deallocate() }
        free(list.unsafeMutablePointer)
    }

    func sample(channel: Int, frame: Int) -> Float {
        var remaining = channel
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            if remaining < count {
                return buffer.mData!.assumingMemoryBound(to: Float.self)[frame * count + remaining]
            }
            remaining -= count
        }
        fatalError("channel \(channel) out of range")
    }

    func render(with renderer: EQRenderer, into output: TestBufferList) {
        renderer.render(input: UnsafePointer(list.unsafePointer), output: output.list.unsafeMutablePointer)
    }
}

private func makeRenderer(_ configure: (inout SoundParameters) -> Void = { _ in }) -> EQRenderer {
    var parameters = SoundParameters()
    configure(&parameters)
    return EQRenderer(settings: SoundSettings(parameters), spectrum: nil, sampleRate: sampleRate)
}

@Suite("Renderer")
struct RendererTests {
    @Test func neutralSettingsPassAudioThroughUnchanged() {
        let renderer = makeRenderer()
        let input = TestBufferList(channels: [1, 1], frameCount: 64) { channel, frame in
            Float(frame) / 100 * (channel == 0 ? 1 : -1)
        }
        let output = TestBufferList(channels: [2], frameCount: 64) { _, _ in .nan }

        input.render(with: renderer, into: output)

        for frame in 0..<64 {
            #expect(output.sample(channel: 0, frame: frame) == Float(frame) / 100)
            #expect(output.sample(channel: 1, frame: frame) == -Float(frame) / 100)
        }
    }

    @Test func extraOutputChannelsAreSilencedAndMonoGetsTheDownmix() {
        let renderer = makeRenderer()
        let input = TestBufferList(channels: [2], frameCount: 32) { channel, _ in channel == 0 ? 0.5 : 0.25 }
        let surround = TestBufferList(channels: [4], frameCount: 32) { _, _ in .nan }
        let mono = TestBufferList(channels: [1], frameCount: 32) { _, _ in .nan }

        input.render(with: renderer, into: surround)
        input.render(with: renderer, into: mono)

        #expect(surround.sample(channel: 2, frame: 10) == 0)
        #expect(surround.sample(channel: 3, frame: 10) == 0)
        #expect(mono.sample(channel: 0, frame: 10) == 0.375)
    }

    @Test func largeBuffersAreProcessedInChunks() {
        let frames = EQRenderer.chunkSize * 2 + 100
        let renderer = makeRenderer()
        let input = TestBufferList(channels: [2], frameCount: frames) { _, frame in Float(frame % 7) / 10 }
        let output = TestBufferList(channels: [2], frameCount: frames) { _, _ in .nan }

        input.render(with: renderer, into: output)

        for frame in stride(from: 0, to: frames, by: 97) {
            #expect(output.sample(channel: 1, frame: frame) == Float(frame % 7) / 10)
        }
    }

    @Test func bassBoostRaisesLowFrequencies() {
        // Bass Boost 4 is a +6 dB low shelf; a constant (0 Hz) signal settles at the full gain.
        #expect(EffectTuning.bassGainDB(4) == 6)
        let renderer = makeRenderer { $0[.bassBoost] = 4 }
        let input = TestBufferList(channels: [2], frameCount: 512) { _, _ in 0.25 }
        let output = TestBufferList(channels: [2], frameCount: 512)

        for _ in 0..<40 { input.render(with: renderer, into: output) }

        let expected = 0.25 * Float(pow(10, 6.0 / 20))
        #expect(abs(output.sample(channel: 0, frame: 511) - expected) < 1e-3)
    }

    @Test func graphicEQBandAffectsItsFrequency() {
        let band = 5 // 1 kHz
        let renderer = makeRenderer { $0[band: band] = 6 }
        let frames = 4_800
        let input = TestBufferList(channels: [2], frameCount: frames) { _, frame in
            0.2 * Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
        }
        let output = TestBufferList(channels: [2], frameCount: frames)

        input.render(with: renderer, into: output)

        var peak: Float = 0
        for frame in (frames / 2)..<frames { peak = max(peak, abs(output.sample(channel: 0, frame: frame))) }
        #expect(abs(decibels(Double(peak / 0.2)) - 6) < 0.2)
    }

    @Test func surroundWidensTheStereoImage() {
        let renderer = makeRenderer { $0[.surround] = 5 }
        let input = TestBufferList(channels: [2], frameCount: 16) { channel, _ in channel == 0 ? 0.4 : 0 }
        let output = TestBufferList(channels: [2], frameCount: 16)

        input.render(with: renderer, into: output)

        // Side signal doubles: L = 0.2 + 0.4, R = 0.2 - 0.4.
        #expect(EffectTuning.stereoWidth(5) == 2)
        #expect(abs(output.sample(channel: 0, frame: 0) - 0.6) < 1e-5)
        #expect(abs(output.sample(channel: 1, frame: 0) + 0.2) < 1e-5)
    }

    @Test func surroundWidensMonoSourcesAndStaysMonoCompatible() {
        let renderer = makeRenderer { $0[.surround] = 10 }
        let frames = 9_600
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<frames).map { _ in Float.random(in: -0.1...0.1, using: &generator) }
        // Identical left and right: a mono source with no side signal at all.
        let input = TestBufferList(channels: [2], frameCount: frames) { _, frame in noise[frame] }
        let output = TestBufferList(channels: [2], frameCount: frames)

        input.render(with: renderer, into: output)

        var midEnergy: Float = 0, sideEnergy: Float = 0
        for frame in (frames / 2)..<frames {
            let left = output.sample(channel: 0, frame: frame)
            let right = output.sample(channel: 1, frame: frame)
            // Summed back to mono, the widening cancels out.
            #expect(abs((left + right) / 2 - noise[frame]) < 1e-5)
            midEnergy += pow((left + right) / 2, 2)
            sideEnergy += pow((left - right) / 2, 2)
        }
        // The synthesized side signal is clearly audible (> -12 dB relative to mid).
        #expect(10 * log10(sideEnergy / midEnergy) > -12)
    }

    @Test(arguments: [(Float(2), -16.0, -8.0), (5, -10, -4), (10, -6, 0)])
    func ambienceIsClearlyAudible(amount: Float, minimumDB: Double, maximumDB: Double) {
        let renderer = makeRenderer { $0[.ambience] = amount }
        let frames = 96_000
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<frames).map { _ in Float.random(in: -0.1...0.1, using: &generator) }
        let input = TestBufferList(channels: [2], frameCount: frames) { _, frame in noise[frame] }
        let output = TestBufferList(channels: [2], frameCount: frames)

        input.render(with: renderer, into: output)

        // Everything but the reverb is neutral, so output minus input is the wet signal.
        var dry: Float = 0, wet: Float = 0
        for frame in (frames / 2)..<frames {
            let difference = output.sample(channel: 0, frame: frame) - noise[frame]
            dry += noise[frame] * noise[frame]
            wet += difference * difference
        }
        let wetToDry = 10 * log10(Double(wet / dry))
        #expect(wetToDry > minimumDB)
        #expect(wetToDry < maximumDB)
    }

    @Test func limiterKeepsBoostedOutputUnderTheCeiling() {
        let renderer = makeRenderer {
            $0[.dynamicBoost] = 10
            $0[.bassBoost] = 10
        }
        let frames = 9_600
        let input = TestBufferList(channels: [2], frameCount: frames) { _, frame in
            0.9 * Float(sin(2 * Double.pi * 60 * Double(frame) / sampleRate))
        }
        let output = TestBufferList(channels: [2], frameCount: frames)

        input.render(with: renderer, into: output)

        var peak: Float = 0
        for frame in 0..<frames { peak = max(peak, abs(output.sample(channel: 0, frame: frame))) }
        #expect(peak <= SoundProcessor.limiterCeiling + 1e-6)
        #expect(peak > 0.9)
    }

    @Test func dynamicBoostLiftsQuietSoundsMoreThanLoudOnes() {
        func gainDB(forAmplitude amplitude: Float) -> Double {
            let renderer = makeRenderer { $0[.dynamicBoost] = 10 }
            let frames = 24_000
            let input = TestBufferList(channels: [2], frameCount: frames) { _, frame in
                amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
            let output = TestBufferList(channels: [2], frameCount: frames)
            input.render(with: renderer, into: output)
            var peak: Float = 0
            for frame in (frames / 2)..<frames { peak = max(peak, abs(output.sample(channel: 0, frame: frame))) }
            return decibels(Double(peak / amplitude))
        }

        let quiet = gainDB(forAmplitude: 0.02) // about -34 dBFS: below the threshold
        let loud = gainDB(forAmplitude: 0.5) // about -6 dBFS: well above it
        #expect(abs(quiet - 15) < 0.5)
        #expect(loud < quiet - 8)
        #expect(loud > 0)
    }

    @Test func spectrumAnalyzerFindsATone() {
        let spectrum = SpectrumBuffer()
        let renderer = EQRenderer(settings: SoundSettings(), spectrum: spectrum, sampleRate: sampleRate)
        let input = TestBufferList(channels: [2], frameCount: 4_096) { _, frame in
            0.5 * Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
        }
        let output = TestBufferList(channels: [2], frameCount: 4_096)
        input.render(with: renderer, into: output)

        let bars = SpectrumAnalyzer(barCount: 48).update(from: spectrum, sampleRate: sampleRate)
        let loudest = bars.indices.max { bars[$0] < bars[$1] }!
        // 1 kHz sits a bit past the middle of a 30 Hz – 18 kHz log axis.
        let expected = Int(log(1_000 / 30.0) / log(18_000 / 30.0) * 48)
        #expect(abs(loudest - expected) <= 1)
        #expect(bars[loudest] > 0.8)
        #expect(bars[0] < 0.3)
    }
}

