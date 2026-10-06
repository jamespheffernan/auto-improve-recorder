import XCTest
@testable import AutoImproveRecorderCore

final class OperationRecordingSlotTests: XCTestCase {
    func testReplaceCancelsTheHandleItReplaces() {
        let slot = OperationRecordingSlot()
        let first = HandleSpy()
        let second = HandleSpy()
        let third = HandleSpy()

        slot.replace(operation: 1, with: first)
        XCTAssertEqual(first.cancelCount, 0)
        slot.replace(operation: 2, with: second)
        XCTAssertEqual(first.cancelCount, 1)
        // The same operation begins again after a microphone restart.
        slot.replace(operation: 2, with: third)
        XCTAssertEqual(second.cancelCount, 1)
        XCTAssertEqual(third.cancelCount, 0)
    }

    func testReceiveReachesOnlyTheCurrentOperationInOrder() {
        let slot = OperationRecordingSlot()
        let first = HandleSpy()
        let second = HandleSpy()

        slot.receive(Self.event(0), operation: 1)
        slot.replace(operation: 1, with: first)
        slot.receive(Self.event(10), operation: 1)
        slot.receive(Self.event(11), operation: 2)
        slot.receive(Self.event(12), operation: 1)
        slot.replace(operation: 2, with: second)
        slot.receive(Self.event(13), operation: 1)
        slot.receive(Self.event(20), operation: 2)

        XCTAssertEqual(first.received, [10, 12])
        XCTAssertEqual(second.received, [20])
    }

    func testTakeReturnsTheHandleOnceAndOnlyForItsOperation() {
        let slot = OperationRecordingSlot()
        let handle = HandleSpy()
        slot.replace(operation: 7, with: handle)

        XCTAssertNil(slot.take(operation: 6))
        XCTAssertTrue(slot.take(operation: 7) === handle)
        XCTAssertNil(slot.take(operation: 7))
        slot.receive(Self.event(1), operation: 7)

        XCTAssertEqual(handle.received, [])
        XCTAssertEqual(handle.cancelCount, 0)
    }

    func testCancelThenReceiveIsInertAndASecondCancelDoesNothing() {
        let slot = OperationRecordingSlot()
        let handle = HandleSpy()
        slot.replace(operation: 3, with: handle)

        slot.cancel(operation: 3)
        slot.cancel(operation: 3)
        slot.receive(Self.event(1), operation: 3)

        XCTAssertEqual(handle.cancelCount, 1)
        XCTAssertEqual(handle.received, [])
        XCTAssertNil(slot.take(operation: 3))
    }

    func testAStaleOperationNumberDoesNothing() {
        let slot = OperationRecordingSlot()
        let handle = HandleSpy()
        slot.replace(operation: 5, with: handle)

        slot.cancel(operation: 4)
        slot.receive(Self.event(1), operation: 4)
        XCTAssertNil(slot.take(operation: 4))

        XCTAssertEqual(handle.cancelCount, 0)
        XCTAssertEqual(handle.received, [])
        XCTAssertTrue(slot.take(operation: 5) === handle)
    }

    // MARK: Concurrent calls

    func testConcurrentTakesHandOutTheHandleOnce() {
        for round in 0..<200 {
            let slot = OperationRecordingSlot()
            let handle = HandleSpy()
            slot.replace(operation: 1, with: handle)
            let winners = Counter()

            DispatchQueue.concurrentPerform(iterations: 16) { index in
                if index.isMultiple(of: 2) {
                    if slot.take(operation: 1) != nil { winners.increment() }
                } else {
                    slot.cancel(operation: 1)
                }
            }

            // One caller removed the handle: either a take, or a cancel that
            // then cancelled it exactly once.
            XCTAssertEqual(winners.value + handle.cancelCount, 1, "round \(round)")
        }
    }

    func testConcurrentReplaceReceiveAndCancelKeepEveryHandleToItsOwnOperation() {
        for round in 0..<50 {
            let slot = OperationRecordingSlot()
            let handles = (0..<32).map { _ in HandleSpy() }

            DispatchQueue.concurrentPerform(iterations: handles.count * 4) { index in
                let operation = UInt64(index / 4)
                switch index % 4 {
                case 0:
                    slot.replace(operation: operation, with: handles[Int(operation)])
                case 1, 2:
                    for _ in 0..<8 {
                        slot.receive(Self.event(operation), operation: operation)
                    }
                default:
                    slot.cancel(operation: operation &+ 1)
                }
            }

            var stillStored = 0
            for (operation, handle) in handles.enumerated() {
                XCTAssertTrue(
                    handle.received.allSatisfy { $0 == UInt64(operation) },
                    "round \(round): handle \(operation) received another operation's event"
                )
                XCTAssertLessThanOrEqual(handle.cancelCount, 1, "round \(round)")
                if slot.take(operation: UInt64(operation)) != nil {
                    stillStored += 1
                    XCTAssertEqual(handle.cancelCount, 0, "round \(round)")
                } else {
                    XCTAssertEqual(handle.cancelCount, 1, "round \(round)")
                }
            }
            XCTAssertLessThanOrEqual(stillStored, 1, "round \(round)")
        }
    }

    func testTheSlotIsNotLockedWhileAHandleReceives() {
        let slot = OperationRecordingSlot()
        let handle = HandleSpy()
        let receiveStarted = DispatchSemaphore(value: 0)
        let receiveMayReturn = DispatchSemaphore(value: 0)
        handle.onReceive = {
            receiveStarted.signal()
            receiveMayReturn.wait()
        }
        slot.replace(operation: 1, with: handle)

        let receiving = expectation(description: "receive returned")
        DispatchQueue.global().async {
            slot.receive(Self.event(1), operation: 1)
            receiving.fulfill()
        }
        XCTAssertEqual(receiveStarted.wait(timeout: .now() + 5), .success)

        // These return while the capture thread is still inside the handle.
        let others = expectation(description: "other calls returned")
        DispatchQueue.global().async {
            slot.receive(Self.event(2), operation: 9)
            slot.cancel(operation: 1)
            slot.replace(operation: 2, with: HandleSpy())
            others.fulfill()
        }
        wait(for: [others], timeout: 5)
        XCTAssertEqual(handle.cancelCount, 1)

        receiveMayReturn.signal()
        wait(for: [receiving], timeout: 5)
    }

    func testTheSlotIsNotLockedWhileAReplacedOrCancelledHandleIsCancelled() {
        let slot = OperationRecordingSlot()
        let first = HandleSpy()
        let second = HandleSpy()
        // A handle that calls back into the slot from cancel would deadlock
        // if the slot still held its lock.
        first.onCancel = { slot.receive(Self.event(1), operation: 2) }
        second.onCancel = { XCTAssertNil(slot.take(operation: 2)) }

        slot.replace(operation: 1, with: first)
        slot.replace(operation: 2, with: second)
        slot.cancel(operation: 2)

        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.cancelCount, 1)
        XCTAssertEqual(second.received, [1])
    }

    private static func event(_ number: UInt64) -> AudioCaptureEvent {
        .failure(.sharedBufferAllocationFailed(sequence: number))
    }
}

/// Records the number carried by each event it receives and how many times
/// it was cancelled.
private final class HandleSpy: RecordingSessionHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReceived: [UInt64] = []
    private var storedCancelCount = 0
    var onReceive: (() -> Void)?
    var onCancel: (() -> Void)?

    var received: [UInt64] { lock.withLock { storedReceived } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func receive(_ event: AudioCaptureEvent) {
        if case .failure(.sharedBufferAllocationFailed(let sequence)) = event {
            lock.withLock { storedReceived.append(sequence) }
        }
        onReceive?()
    }

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", engineName: "spy")
    }

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
        onCancel?()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}
