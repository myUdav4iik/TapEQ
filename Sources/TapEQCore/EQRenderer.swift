import CoreAudio

/// Processes one HAL IO cycle: reads the tapped (stereo) system mix, runs the effect
/// chain and writes the result to the output device's buffers.
///
/// `@unchecked Sendable`: once installed in an IOProc, the renderer's mutable state is
/// touched only from the HAL IO thread. The UI reaches it solely through `SoundSettings`
/// (try-lock) and `SpectrumBuffer` (atomic index). `render` never allocates or blocks.
public final class EQRenderer: @unchecked Sendable {
    /// Frames processed per chunk; larger IO buffers are handled in several chunks.
    static let chunkSize = 1_024

    private let settings: SoundSettings
    private let spectrum: SpectrumBuffer?
    private let processor: SoundProcessor
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>

    public init(settings: SoundSettings, spectrum: SpectrumBuffer?, sampleRate: Double) {
        self.settings = settings
        self.spectrum = spectrum
        processor = SoundProcessor(sampleRate: sampleRate)
        left = .allocate(capacity: Self.chunkSize)
        right = .allocate(capacity: Self.chunkSize)
        mono = .allocate(capacity: Self.chunkSize)
        if let parameters = settings.tryRead() { processor.apply(parameters) }
    }

    deinit {
        left.deallocate()
        right.deallocate()
        mono.deallocate()
    }

    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        if let parameters = settings.tryRead() { processor.apply(parameters) }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let sourceLeft = Self.channel(0, in: inputs)
        let sourceRight = Self.channel(1, in: inputs) ?? sourceLeft
        let inputFrames = min(sourceLeft?.frameCount ?? 0, sourceRight?.frameCount ?? 0)
        let outputFrames = outputs.lazy.compactMap(Self.frameCount).max() ?? 0
        let outputChannels = outputs.reduce(0) { $0 + Int($1.mNumberChannels) }

        var start = 0
        while start < outputFrames {
            let count = min(Self.chunkSize, outputFrames - start)
            for frame in 0..<count {
                let source = start + frame
                if let sourceLeft, let sourceRight, source < inputFrames {
                    left[frame] = sourceLeft.samples[source * sourceLeft.stride]
                    right[frame] = sourceRight.samples[source * sourceRight.stride]
                } else {
                    left[frame] = 0
                    right[frame] = 0
                }
            }

            processor.process(left: left, right: right, frameCount: count)
            for frame in 0..<count { mono[frame] = (left[frame] + right[frame]) * 0.5 }
            spectrum?.write(mono, count: count)

            write(outputs, channelCount: outputChannels, from: start, count: count)
            start += count
        }
    }

    /// Stereo goes to the first two channels; a mono device gets the downmix and any
    /// extra channels (e.g. surround layouts) stay silent.
    private func write(_ outputs: UnsafeMutableAudioBufferListPointer, channelCount: Int, from start: Int, count: Int) {
        var firstChannelOfBuffer = 0
        for buffer in outputs {
            let channelsInBuffer = Int(buffer.mNumberChannels)
            defer { firstChannelOfBuffer += channelsInBuffer }
            guard let frameCount = Self.frameCount(buffer), let data = buffer.mData else { continue }
            let destination = data.assumingMemoryBound(to: Float.self)
            let end = min(start + count, frameCount)
            guard start < end else { continue }

            for offset in 0..<channelsInBuffer {
                let source: UnsafeMutablePointer<Float>? = switch firstChannelOfBuffer + offset {
                case 0: channelCount == 1 ? mono : left
                case 1: right
                default: nil
                }
                for frame in start..<end {
                    destination[frame * channelsInBuffer + offset] = source.map { min(max($0[frame - start], -1), 1) } ?? 0
                }
            }
        }
    }

    private static func frameCount(_ buffer: AudioBuffer) -> Int? {
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { return nil }
        return Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
    }

    /// Locates channel `index` across the buffers of an (interleaved or not) buffer list.
    private static func channel(
        _ index: Int,
        in list: UnsafeMutableAudioBufferListPointer
    ) -> (samples: UnsafePointer<Float>, stride: Int, frameCount: Int)? {
        var remaining = index
        for buffer in list {
            let channelsInBuffer = Int(buffer.mNumberChannels)
            if remaining < channelsInBuffer {
                guard let data = buffer.mData, let frameCount = frameCount(buffer) else { return nil }
                let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self)) + remaining
                return (samples, channelsInBuffer, frameCount)
            }
            remaining -= channelsInBuffer
        }
        return nil
    }
}
