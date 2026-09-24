import AVFoundation
import CoreBluetooth
import Foundation

enum AutoSendWirelessBridgeError: LocalizedError {
    case deviceNotConnected
    case captureAlreadyActive
    case invalidAudioFormat
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "The wireless recorder is not connected."
        case .captureAlreadyActive:
            return "The wireless recorder is already active."
        case .invalidAudioFormat:
            return "The wireless recorder audio format is not available."
        case .archiveFailed(let message):
            return "The wireless recording could not be saved: \(message)"
        }
    }
}

final class AutoSendWirelessBridge: NSObject, @unchecked Sendable {
    static let shared = AutoSendWirelessBridge()

    private static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let controlUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let audioUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    fileprivate static let samplesPerPacket = 320

    private let queue = DispatchQueue(label: "com.turfterrace.autosendrecorder.wireless", qos: .userInteractive)
    private let lock = NSLock()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var buttonHandler: (@Sendable (Bool) -> Void)?
    private var buttonStateFilter = AutoSendWirelessButtonStateFilter()
    private var capture: WirelessCapture?
    private var pendingAudio: [Data] = []

    override private init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func start(buttonHandler: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        self.buttonHandler = buttonHandler
        lock.unlock()
        queue.async { [weak self] in
            self?.scanIfPossible()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            central.stopScan()
        }
    }

    func startCapture(
        at url: URL,
        streamHandler: @escaping AudioRecorder.AudioBufferHandler
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard peripheral?.state == .connected,
              controlCharacteristic?.isNotifying == true,
              audioCharacteristic?.isNotifying == true else {
            throw AutoSendWirelessBridgeError.deviceNotConnected
        }
        guard capture == nil else {
            throw AutoSendWirelessBridgeError.captureAlreadyActive
        }
        let newCapture = try WirelessCapture(url: url, streamHandler: streamHandler)
        capture = newCapture
        let queued = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)
        for packet in queued {
            newCapture.append(packet: packet)
        }
    }

    func stopCapture() throws -> URL {
        lock.lock()
        guard let active = capture else {
            lock.unlock()
            throw AutoSendRecordingError.noActiveRecording
        }
        capture = nil
        pendingAudio.removeAll(keepingCapacity: true)
        lock.unlock()
        return try active.finish()
    }

    func cancelCapture() {
        lock.lock()
        let active = capture
        capture = nil
        pendingAudio.removeAll(keepingCapacity: true)
        lock.unlock()
        active?.cancel()
    }

    private func scanIfPossible() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func receiveControl(_ data: Data) {
        guard let state = data.first, state == 0 || state == 1 else { return }
        lock.lock()
        let handler = buttonHandler
        let acceptedState = buttonStateFilter.consume(pressed: state == 1)
        if acceptedState == true {
            pendingAudio.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if let acceptedState {
            handler?(acceptedState)
        }
    }

    private func receiveAudio(_ data: Data) {
        lock.lock()
        if let capture {
            capture.append(packet: data)
        } else {
            pendingAudio.append(data)
            if pendingAudio.count > 12 {
                pendingAudio.removeFirst(pendingAudio.count - 12)
            }
        }
        lock.unlock()
    }
}

extension AutoSendWirelessBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scanIfPossible()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        clearConnectionAndScan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        lock.lock()
        let handler = buttonHandler
        lock.unlock()
        handler?(false)
        cancelCapture()
        clearConnectionAndScan()
    }

    private func clearConnectionAndScan() {
        lock.lock()
        buttonStateFilter.reset()
        lock.unlock()
        peripheral = nil
        controlCharacteristic = nil
        audioCharacteristic = nil
        scanIfPossible()
    }
}

extension AutoSendWirelessBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics(
                [Self.controlUUID, Self.audioUUID],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.controlUUID:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.audioUUID:
                audioCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == Self.controlUUID {
            receiveControl(data)
        } else if characteristic.uuid == Self.audioUUID {
            receiveAudio(data)
        }
    }
}

private final class WirelessCapture {
    private let url: URL
    private let writer: ArchiveAudioWriter
    private let streamHandler: AudioRecorder.AudioBufferHandler
    private var sequence: UInt64 = 0
    private var failedMessage: String?

    init(url: URL, streamHandler: @escaping AudioRecorder.AudioBufferHandler) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AutoSendWirelessBridgeError.invalidAudioFormat
        }
        self.url = url
        self.streamHandler = streamHandler
        writer = ArchiveAudioWriter(url: url, format: format)
        writer.open()
        if case .failed(let message) = writer.status {
            throw AutoSendWirelessBridgeError.archiveFailed(message)
        }
    }

    func append(packet: Data) {
        guard failedMessage == nil,
              let samples = IMAADPCM.decode(packet: packet),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.int16ChannelData?.pointee else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        let captured = CapturedAudioBuffer(sequence: sequence, buffer: buffer)
        sequence &+= 1
        writer.append(captured)
        if case .failed(let message) = writer.status {
            failedMessage = message
            return
        }
        streamHandler(.captured(captured))
    }

    func finish() throws -> URL {
        if let failedMessage {
            throw AutoSendWirelessBridgeError.archiveFailed(failedMessage)
        }
        switch writer.finish() {
        case .finished(_):
            return url
        case .failed(let message):
            throw AutoSendWirelessBridgeError.archiveFailed(message)
        case .unavailable, .writing:
            throw AutoSendWirelessBridgeError.archiveFailed("The audio file did not close correctly.")
        }
    }

    func cancel() {
        _ = writer.finish()
    }
}

private enum IMAADPCM {
    private static let indexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878,
        2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
        6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
        18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    static func decode(packet: Data) -> [Int16]? {
        guard packet.count >= 6 else { return nil }
        let bytes = [UInt8](packet)
        var predictor = Int(Int16(bitPattern: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)))
        var index = min(max(Int(bytes[4]), 0), stepTable.count - 1)
        var output = [Int16(predictor)]
        output.reserveCapacity(AutoSendWirelessBridge.samplesPerPacket)

        for byte in bytes.dropFirst(5) {
            for nibble in [Int(byte & 0x0f), Int(byte >> 4)] {
                guard output.count < AutoSendWirelessBridge.samplesPerPacket else { break }
                let step = stepTable[index]
                var difference = step >> 3
                if nibble & 1 != 0 { difference += step >> 2 }
                if nibble & 2 != 0 { difference += step >> 1 }
                if nibble & 4 != 0 { difference += step }
                predictor += nibble & 8 != 0 ? -difference : difference
                predictor = min(max(predictor, Int(Int16.min)), Int(Int16.max))
                index = min(max(index + indexTable[nibble], 0), stepTable.count - 1)
                output.append(Int16(predictor))
            }
        }
        return output.count == AutoSendWirelessBridge.samplesPerPacket ? output : nil
    }
}
