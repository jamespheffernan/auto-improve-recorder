#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum HALInputCaptureError: LocalizedError {
    case unitUnavailable
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unitUnavailable:
            return "CoreAudio has no input unit."
        case .coreAudio(let operation, let status):
            return "CoreAudio could not \(operation) (error \(status))."
        }
    }
}

/// Records one CoreAudio input device through its own HAL unit. The unit is bound to the device
/// before it opens, so a recording never opens the system default input first. AVAudioEngine's
/// input node always opens the default first: an AirPods default then switches to call mode, and
/// the node keeps the AirPods format after it moves to the chosen device.
///
/// Buffers of at least `chunkFrames` frames reach `onBuffer` in order on a private serial queue,
/// never on the audio thread.
final class HALInputCapture {
    /// The largest number of frames one render may ask for.
    private static let maximumFramesPerRender: AVAudioFrameCount = 4096

    /// The device's own sample rate and channel count, as non-interleaved Float32.
    let format: AVAudioFormat

    private let unit: AudioUnit
    private let chunkFrames: AVAudioFrameCount
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let deliveryQueue = DispatchQueue(label: "recorder.audio.capture", qos: .userInitiated)
    /// Written on the audio thread only while the unit runs.
    private let renderBuffer: AVAudioPCMBuffer
    private let chunk: AVAudioPCMBuffer
    private var isRunning = false

    init(
        deviceID: AudioObjectID,
        chunkFrames: AVAudioFrameCount,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HALInputCaptureError.unitUnavailable
        }
        var newUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &newUnit), "open an input unit")
        guard let unit = newUnit else { throw HALInputCaptureError.unitUnavailable }

        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            var device = deviceID
            var maximumFrames = UInt32(Self.maximumFramesPerRender)
            let uint32Size = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, uint32Size),
                "enable input"
            )
            try Self.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, uint32Size),
                "disable output"
            )
            try Self.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, uint32Size),
                "select the microphone"
            )
            try Self.check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, uint32Size),
                "set the render size"
            )

            var hardware = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize),
                "read the microphone format"
            )
            guard hardware.mSampleRate > 0,
                  hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: hardware.mSampleRate,
                      channels: hardware.mChannelsPerFrame,
                      interleaved: false
                  ),
                  let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maximumFramesPerRender),
                  let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames + Self.maximumFramesPerRender) else {
                throw HALInputCaptureError.coreAudio("read the microphone format", kAudioUnitErr_FormatNotSupported)
            }
            try Self.check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription, formatSize),
                "set the recording format"
            )
            self.unit = unit
            self.format = format
            self.renderBuffer = renderBuffer
            self.chunk = chunk
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.chunkFrames = max(chunkFrames, 1)
        self.onBuffer = onBuffer

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frameCount, _ in
                Unmanaged<HALInputCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        // Every property is set, so a throw from here runs deinit, which disposes the unit.
        try Self.check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "set the input callback"
        )
        try Self.check(AudioUnitInitialize(unit), "prepare the microphone")
    }

    deinit {
        stop()
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func start() throws {
        guard !isRunning else { return }
        chunk.frameLength = 0
        try Self.check(AudioOutputUnitStart(unit), "start the microphone")
        isRunning = true
    }

    /// Stops the device. Returns after every buffer it captured has reached `onBuffer`.
    func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
        deliveryQueue.sync {}
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= renderBuffer.frameCapacity else {
            return kAudioUnitErr_TooManyFramesToProcess
        }
        // The buffer list's byte sizes follow frameLength, so set it before rendering into it.
        renderBuffer.frameLength = frameCount
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, renderBuffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        guard let source = renderBuffer.floatChannelData, let destination = chunk.floatChannelData else {
            return noErr
        }
        let offset = Int(chunk.frameLength)
        for channel in 0..<Int(format.channelCount) {
            (destination[channel] + offset).update(from: source[channel], count: Int(frameCount))
        }
        chunk.frameLength += frameCount
        guard chunk.frameLength >= chunkFrames,
              let delivered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameLength),
              let deliveredData = delivered.floatChannelData else {
            return noErr
        }
        for channel in 0..<Int(format.channelCount) {
            deliveredData[channel].update(from: destination[channel], count: Int(chunk.frameLength))
        }
        delivered.frameLength = chunk.frameLength
        chunk.frameLength = 0
        let onBuffer = onBuffer
        deliveryQueue.async { onBuffer(delivered) }
        return noErr
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw HALInputCaptureError.coreAudio(operation, status) }
    }
}
#endif
