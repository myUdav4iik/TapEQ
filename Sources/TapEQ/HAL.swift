import CoreAudio
import Foundation
import OSLog

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        if let code = fourCharCode {
            return "\(operation) failed (OSStatus \(status), '\(code)')."
        }
        return "\(operation) failed (OSStatus \(status))."
    }

    private var fourCharCode: String? {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Thin wrappers over the Core Audio HAL property API.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value.
    static func read<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: Value
    ) throws -> Value {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Reading audio property")
        return value
    }

    /// Reads a CFString property (the HAL returns it retained).
    static func readString(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Reading audio property")
        guard let value else { throw CoreAudioError(operation: "Reading audio property", status: kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    /// Reads a variable-length array property.
    static func readArray<Element: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as _: Element.Type
    ) throws -> [Element] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading audio property size")
        var status = noErr
        let elements = [Element](unsafeUninitializedCapacity: Int(size) / MemoryLayout<Element>.stride) { buffer, count in
            count = 0
            guard let base = buffer.baseAddress else { return }
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
            if status == noErr { count = Int(size) / MemoryLayout<Element>.stride }
        }
        try check(status, "Reading audio property")
        return elements
    }

    struct OutputDevice: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
    }

    /// Output devices the user could pick as the system default, excluding TapEQ's own aggregate.
    static func outputDevices() throws -> [OutputDevice] {
        try readArray(kAudioHardwarePropertyDevices, of: systemObject, as: AudioObjectID.self).compactMap { device in
            guard let uid = try? readString(kAudioDevicePropertyDeviceUID, of: device),
                  !uid.hasPrefix(aggregateUIDPrefix),
                  let streams = try? readArray(kAudioDevicePropertyStreams, of: device, scope: kAudioObjectPropertyScopeOutput, as: AudioStreamID.self),
                  !streams.isEmpty,
                  (try? read(kAudioDevicePropertyDeviceCanBeDefaultDevice, of: device, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))) == 1
            else { return nil }
            let name = (try? readString(kAudioObjectPropertyName, of: device)) ?? uid
            return OutputDevice(id: device, name: name)
        }
    }

    static func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = device
        try check(
            AudioObjectSetPropertyData(systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device),
            "Switching the output device"
        )
    }

    /// Calls `handler` on the main actor whenever the system object's property changes.
    /// The listener stays installed for the life of the app.
    static func observeSystemProperty(_ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        var address = address(selector)
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, .main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        if status != noErr {
            Logger(subsystem: "local.poc.TapEQ", category: "audio").error("Listening for property changes failed: \(status)")
        }
    }

    static let aggregateUIDPrefix = "local.poc.TapEQ.aggregate."

    static func defaultOutputDevice() throws -> AudioObjectID {
        let device = try read(kAudioHardwarePropertyDefaultOutputDevice, of: systemObject, initial: AudioObjectID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "Finding the default output device", status: kAudioHardwareBadDeviceError)
        }
        return device
    }

    /// The HAL's process object for `pid`, or `kAudioObjectUnknown` if the HAL doesn't know the process.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "Looking up this app's audio process"
        )
        return object
    }
}
