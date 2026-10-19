import Foundation

/// A Schroeder/Moorer room reverb (pre-delay → eight parallel damped combs → four series
/// all-passes per channel), used for the Ambience effect. All delay memory is allocated
/// up front.
final class Reverb {
    // Classic tunings at 44.1 kHz; the right channel is offset to decorrelate.
    private static let combLengths = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allPassLengths = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let inputGain: Float = 0.015
    private static let preDelaySeconds = 0.02

    private let preDelay: UnsafeMutableBufferPointer<Float>
    private var preDelayIndex = 0
    private var leftCombs: [Comb]
    private var rightCombs: [Comb]
    private var leftAllPasses: [AllPass]
    private var rightAllPasses: [AllPass]

    init(sampleRate: Double) {
        let scale = sampleRate / 44_100
        func scaled(_ length: Int, spread: Int = 0) -> Int { max(1, Int(Double(length + spread) * scale)) }
        preDelay = .allocate(capacity: max(1, Int(Self.preDelaySeconds * sampleRate)))
        preDelay.initialize(repeating: 0)
        leftCombs = Self.combLengths.map { Comb(length: scaled($0)) }
        rightCombs = Self.combLengths.map { Comb(length: scaled($0, spread: Self.stereoSpread)) }
        leftAllPasses = Self.allPassLengths.map { AllPass(length: scaled($0)) }
        rightAllPasses = Self.allPassLengths.map { AllPass(length: scaled($0, spread: Self.stereoSpread)) }
    }

    deinit {
        preDelay.deallocate()
        for index in leftCombs.indices { leftCombs[index].deallocate(); rightCombs[index].deallocate() }
        for index in leftAllPasses.indices { leftAllPasses[index].deallocate(); rightAllPasses[index].deallocate() }
    }

    /// Comb feedback: higher means a bigger room with a longer tail (keep below 1).
    func setFeedback(_ feedback: Float) {
        for index in leftCombs.indices {
            leftCombs[index].feedback = feedback
            rightCombs[index].feedback = feedback
        }
    }

    /// Returns the wet signal for one stereo frame.
    @inline(__always)
    func process(left: Float, right: Float) -> (left: Float, right: Float) {
        let input = preDelay[preDelayIndex]
        preDelay[preDelayIndex] = (left + right) * Self.inputGain
        preDelayIndex = preDelayIndex + 1 == preDelay.count ? 0 : preDelayIndex + 1

        var wetLeft: Float = 0
        var wetRight: Float = 0
        for index in leftCombs.indices {
            wetLeft += leftCombs[index].process(input)
            wetRight += rightCombs[index].process(input)
        }
        for index in leftAllPasses.indices {
            wetLeft = leftAllPasses[index].process(wetLeft)
            wetRight = rightAllPasses[index].process(wetRight)
        }
        return (wetLeft, wetRight)
    }

    func reset() {
        preDelay.update(repeating: 0)
        for index in leftCombs.indices { leftCombs[index].clear(); rightCombs[index].clear() }
        for index in leftAllPasses.indices { leftAllPasses[index].clear(); rightAllPasses[index].clear() }
    }
}

private struct Comb {
    private static let damping: Float = 0.2

    var feedback: Float = 0.84
    private let buffer: UnsafeMutableBufferPointer<Float>
    private var index = 0
    private var lowPassed: Float = 0

    init(length: Int) {
        buffer = .allocate(capacity: length)
        buffer.initialize(repeating: 0)
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let output = buffer[index]
        lowPassed = output * (1 - Self.damping) + lowPassed * Self.damping
        buffer[index] = input + lowPassed * feedback
        index = index + 1 == buffer.count ? 0 : index + 1
        return output
    }

    mutating func clear() {
        buffer.update(repeating: 0)
        lowPassed = 0
    }

    func deallocate() { buffer.deallocate() }
}

private struct AllPass {
    private let buffer: UnsafeMutableBufferPointer<Float>
    private var index = 0

    init(length: Int) {
        buffer = .allocate(capacity: length)
        buffer.initialize(repeating: 0)
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let delayed = buffer[index]
        buffer[index] = input + delayed * 0.5
        index = index + 1 == buffer.count ? 0 : index + 1
        return delayed - input
    }

    mutating func clear() { buffer.update(repeating: 0) }

    func deallocate() { buffer.deallocate() }
}
