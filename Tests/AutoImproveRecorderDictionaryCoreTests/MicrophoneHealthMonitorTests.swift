import AVFoundation
import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class MicrophoneHealthMonitorTests: XCTestCase {
    func testExactSilentStartupEmitsAfterConfiguredDuration() {
        let monitor = MicrophoneHealthMonitor(
            configuration: MicrophoneHealthConfiguration(
                exactSilentFallbackDuration: 0.03,
                startupObservationDuration: 0.2,
                minimumSilentBuffers: 2
            )
        )
        let silentBuffer = makeBuffer(frameLength: 480, fill: 0)

        XCTAssertNil(monitor.observe(silentBuffer))
        XCTAssertNil(monitor.observe(silentBuffer))
        let event = monitor.observe(silentBuffer)

        XCTAssertEqual(event?.kind, .exactSilentStartup)
        XCTAssertEqual(event?.silentBufferCount, 3)
    }

    func testNonSilentAudioSuppressesExactSilentStartupEvent() {
        let monitor = MicrophoneHealthMonitor(
            configuration: MicrophoneHealthConfiguration(
                exactSilentFallbackDuration: 0.02,
                startupObservationDuration: 0.2,
                minimumSilentBuffers: 2
            )
        )

        XCTAssertNil(monitor.observe(makeBuffer(frameLength: 480, fill: 0)))
        XCTAssertNil(monitor.observe(makeBuffer(frameLength: 480, fill: 0.25)))
        XCTAssertNil(monitor.observe(makeBuffer(frameLength: 480, fill: 0)))
        XCTAssertNil(monitor.observe(makeBuffer(frameLength: 480, fill: 0)))
    }

    private func makeBuffer(frameLength: AVAudioFrameCount, fill value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
        buffer.frameLength = frameLength
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameLength) {
            samples[index] = value
        }
        return buffer
    }
}
