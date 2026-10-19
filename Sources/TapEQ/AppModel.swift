import CoreAudio
import Foundation
import Observation
import ServiceManagement
import TapEQCore

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case off
        case starting
        case running(outputDeviceName: String, sampleRate: Double)
        case failed(String)
    }

    enum LoginItemState: Equatable {
        case off
        case on
        /// Registered, but the user must allow it under System Settings → Login Items.
        case needsApproval
    }

    static let visualizerBarCount = 40

    private(set) var status: Status = .off
    private(set) var spectrum: [Float] = Array(repeating: 0, count: visualizerBarCount)
    private(set) var outputDevices: [HAL.OutputDevice] = []
    private(set) var defaultOutputID = AudioObjectID(kAudioObjectUnknown)
    /// Name of the preset the controls currently match, or `nil` once edited ("Custom").
    private(set) var presetName: String?

    private(set) var loginItem: LoginItemState = .off
    private(set) var loginItemError: String?

    /// Whether the menu bar panel is open; the visualizer only runs while it is.
    var isPanelVisible = false {
        didSet {
            updateVisualizer()
            // The user may have changed it in System Settings while the panel was closed.
            if isPanelVisible { refreshLoginItem() }
        }
    }

    var parameters: SoundParameters {
        didSet {
            guard parameters != oldValue else { return }
            settings.update(parameters)
            if let presetName, SoundPreset.builtIn.first(where: { $0.name == presetName })?.parameters != parameters {
                self.presetName = nil
            }
            save()
        }
    }

    @ObservationIgnored private let settings: SoundSettings
    @ObservationIgnored private let spectrumBuffer = SpectrumBuffer()
    @ObservationIgnored private let analyzer = SpectrumAnalyzer(barCount: visualizerBarCount)
    @ObservationIgnored private lazy var processor = SystemAudioProcessor(settings: settings, spectrum: spectrumBuffer)
    @ObservationIgnored private var visualizerTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Bumped by every start/stop so a slow start that was superseded is discarded.
    @ObservationIgnored private var generation = 0

    init() {
        let saved = defaults.data(forKey: Keys.parameters)
            .flatMap { try? JSONDecoder().decode(SoundParameters.self, from: $0) }
        let initial = saved ?? SoundPreset.builtIn[1].parameters
        parameters = initial
        settings = SoundSettings(initial)
        presetName = saved == nil ? SoundPreset.builtIn[1].name : defaults.string(forKey: Keys.preset)

        refreshOutputDevices()
        refreshLoginItem()
        HAL.observeSystemProperty(kAudioHardwarePropertyDevices) { [weak self] in
            self?.refreshOutputDevices()
        }
        HAL.observeSystemProperty(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.defaultOutputChanged()
        }

        if defaults.bool(forKey: Keys.powerOn) { start() }
    }

    var isOn: Bool {
        if case .running = status { return true }
        return false
    }

    /// On, or on its way there (the power switch's state).
    var isPoweredOn: Bool {
        switch status {
        case .running, .starting: true
        case .off, .failed: false
        }
    }

    func togglePower() {
        let turningOn = status == .off || isFailed
        turningOn ? start() : stop()
        defaults.set(turningOn, forKey: Keys.powerOn)
    }

    func stop() {
        generation += 1
        processor.stop()
        status = .off
        restartVisualizer()
    }

    func apply(_ preset: SoundPreset) {
        parameters = preset.parameters
        presetName = preset.name
        save()
    }

    func resetEQ() {
        var flat = parameters
        for band in 0..<GraphicEQ.bandCount { flat[band: band] = 0 }
        parameters = flat
    }

    func selectOutputDevice(_ device: AudioObjectID) {
        do {
            try HAL.setDefaultOutputDevice(device)
        } catch where status == .off {
            status = .failed(error.localizedDescription)
        } catch {
            // Processing keeps running on the previous device; nothing else to update.
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshLoginItem() {
        loginItem = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func start() {
        generation += 1
        let attempt = generation
        status = .starting
        Task {
            do {
                let route = try await processor.start()
                guard attempt == generation else { return }
                status = .running(outputDeviceName: route.outputDeviceName, sampleRate: route.sampleRate)
                restartVisualizer()
            } catch {
                guard attempt == generation else { return }
                stop()
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// The aggregate device is bound to one output device, so follow the system default.
    private func defaultOutputChanged() {
        defaultOutputID = (try? HAL.defaultOutputDevice()) ?? AudioObjectID(kAudioObjectUnknown)
        if isOn || status == .starting { start() }
    }

    private func refreshOutputDevices() {
        outputDevices = (try? HAL.outputDevices()) ?? []
        defaultOutputID = (try? HAL.defaultOutputDevice()) ?? AudioObjectID(kAudioObjectUnknown)
    }

    private func restartVisualizer() {
        visualizerTask?.cancel()
        visualizerTask = nil
        analyzer.reset()
        spectrum = Array(repeating: 0, count: Self.visualizerBarCount)
        updateVisualizer()
    }

    private func updateVisualizer() {
        guard isPanelVisible, case let .running(_, sampleRate) = status else {
            visualizerTask?.cancel()
            visualizerTask = nil
            return
        }
        guard visualizerTask == nil else { return }
        visualizerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                self.spectrum = self.analyzer.update(from: self.spectrumBuffer, sampleRate: sampleRate)
            }
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(parameters), forKey: Keys.parameters)
        defaults.set(presetName, forKey: Keys.preset)
    }

    private enum Keys {
        // v2: 10-band EQ layout (earlier builds stored 31 bands).
        static let parameters = "soundParameters.v2"
        static let preset = "presetName.v2"
        static let powerOn = "powerOn"
    }
}
