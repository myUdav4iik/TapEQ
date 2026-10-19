import Synchronization

/// Hands parameters from the UI to the real-time audio thread.
///
/// The audio thread only ever *tries* the lock, so a UI update in progress costs it
/// at most one cycle of stale parameters, never a wait.
public final class SoundSettings: Sendable {
    private let parameters: Mutex<SoundParameters>

    public init(_ initial: SoundParameters = SoundParameters()) {
        parameters = Mutex(initial)
    }

    public func update(_ newValue: SoundParameters) {
        parameters.withLock { $0 = newValue }
    }

    /// Non-blocking read for the audio thread; `nil` if the UI holds the lock right now.
    public func tryRead() -> SoundParameters? {
        parameters.withLockIfAvailable { $0 }
    }
}
