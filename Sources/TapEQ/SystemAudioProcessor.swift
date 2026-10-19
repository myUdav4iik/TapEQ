import CoreAudio
import Foundation
import OSLog
import TapEQCore

/// Routes all system audio through the effect chain:
///
/// 1. A muted, global process tap captures every app's output (except ours) and
///    silences those apps at the hardware.
/// 2. A private aggregate device combines that tap (as input) with the current
///    default output device (as output).
/// 3. An IOProc on the aggregate runs the effects and writes the result to the output.
///
/// Setup runs on a private serial queue because the HAL can block for as long as the
/// macOS audio-capture permission prompt is on screen. `@unchecked Sendable`: all
/// mutable state is confined to `queue`.
final class SystemAudioProcessor: @unchecked Sendable {
    struct Route {
        let outputDeviceName: String
        let sampleRate: Double
    }

    private static let logger = Logger(subsystem: "local.poc.TapEQ", category: "audio")

    private let settings: SoundSettings
    private let spectrum: SpectrumBuffer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.poc.TapEQ.audio-setup")

    init(settings: SoundSettings, spectrum: SpectrumBuffer) {
        self.settings = settings
        self.spectrum = spectrum
    }

    /// Builds the tap → effects → output chain on the current default output device.
    func start() async throws -> Route {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.tearDown()
                do {
                    continuation.resume(returning: try self.buildChain())
                } catch {
                    self.tearDown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Tears the chain down synchronously. Destroying the tap un-mutes every app.
    func stop() {
        queue.sync { tearDown() }
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                logIfFailed(AudioDeviceStop(aggregateID, ioProcID), "AudioDeviceStop")
                logIfFailed(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "AudioDeviceDestroyIOProcID")
            }
            logIfFailed(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if tapID != kAudioObjectUnknown {
            logIfFailed(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func buildChain() throws -> Route {
        let outputDevice = try HAL.defaultOutputDevice()
        let outputUID = try HAL.readString(kAudioDevicePropertyDeviceUID, of: outputDevice)
        let outputName = (try? HAL.readString(kAudioObjectPropertyName, of: outputDevice)) ?? outputUID

        // Our own output must stay out of the tap, or it would be captured and replayed forever.
        let ownProcess = try HAL.processObject(for: getpid())
        guard ownProcess != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "Excluding TapEQ from the tap", status: kAudioHardwareBadObjectError)
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        tapDescription.name = "TapEQ system tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .muted
        try HAL.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Creating the system audio tap")

        let tapFormat = try HAL.read(kAudioTapPropertyFormat, of: tapID, initial: AudioStreamBasicDescription())
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32
        else {
            throw CoreAudioError(operation: "Checking the tap's audio format", status: kAudioHardwareUnsupportedOperationError)
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TapEQ",
            kAudioAggregateDeviceUIDKey: HAL.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        try HAL.check(
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
            "Creating the aggregate device"
        )

        let sampleRate = try HAL.read(kAudioDevicePropertyNominalSampleRate, of: aggregateID, initial: Float64(0))
        let renderer = EQRenderer(settings: settings, spectrum: spectrum, sampleRate: sampleRate)

        // A nil queue makes the HAL invoke the block directly on its real-time IO thread.
        try HAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, Self.makeIOBlock(renderer)),
            "Installing the audio callback"
        )
        try HAL.check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")

        Self.logger.info("Routing system audio to \(outputName, privacy: .public) at \(sampleRate) Hz")
        return Route(outputDeviceName: outputName, sampleRate: sampleRate)
    }

    /// Must never be formed inside actor-isolated code: such a closure inherits the
    /// isolation, and Swift traps when the HAL calls it on the IO thread.
    private static func makeIOBlock(_ renderer: EQRenderer) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }
    }

    private func logIfFailed(_ status: OSStatus, _ operation: String) {
        guard status != noErr else { return }
        Self.logger.error("\(operation, privacy: .public) failed: \(status)")
    }
}
