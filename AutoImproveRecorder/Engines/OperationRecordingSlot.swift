import Foundation

/// Holds the recording handle of at most one operation. Capture callbacks,
/// the workflow and cancellation reach the handle through its operation
/// number, so a call that carries an old number does nothing.
///
/// The lock guards only the stored pair. Handles are always called with the
/// lock released.
final class OperationRecordingSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (operation: UInt64, handle: any RecordingSessionHandle)?

    /// Stores `handle` for `operation` and cancels the handle it replaces.
    func replace(operation: UInt64, with handle: any RecordingSessionHandle) {
        lock.lock()
        let previous = current?.handle
        current = (operation, handle)
        lock.unlock()
        previous?.cancel()
    }

    /// Passes the event to the stored handle when `operation` is its number.
    func receive(_ event: AudioCaptureEvent, operation: UInt64) {
        lock.lock()
        let handle = current?.operation == operation ? current?.handle : nil
        lock.unlock()
        handle?.receive(event)
    }

    /// Removes and returns the stored handle when `operation` is its number.
    /// Of several concurrent calls, one gets the handle.
    func take(operation: UInt64) -> (any RecordingSessionHandle)? {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.operation == operation else { return nil }
        self.current = nil
        return current.handle
    }

    /// Removes the stored handle when `operation` is its number and cancels it.
    func cancel(operation: UInt64) {
        take(operation: operation)?.cancel()
    }
}
