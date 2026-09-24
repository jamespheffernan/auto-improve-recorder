import AppKit
import ApplicationServices
import Foundation
import os.log

private let performanceLog = OSLog(subsystem: "com.jamesheffernan.AutoSendRecorder.DeliveryFixture", category: .pointsOfInterest)

private enum Strategy: String, CaseIterable, Codable {
    case paste80ms
    case orderedPasteAndSend
    case verifiedPasteAndSend
    case qualifiedAXReplacement
}

private enum SendCommand: String, Codable {
    case none
    case enter
    case commandEnter

    var keyCode: CGKeyCode { 0x24 }
    var flags: CGEventFlags { self == .commandEnter ? .maskCommand : [] }
}

private enum Target: String, Codable {
    case textField
    case textView

    var identifier: String {
        switch self {
        case .textField: return "delivery.textField"
        case .textView: return "delivery.textView"
        }
    }
}

private struct Scenario: Codable {
    let id: String
    let target: Target
    let initial: String
    let selectionLocation: Int
    let selectionLength: Int
    let inserted: String
    let command: SendCommand

    var expected: String? {
        replacingUTF16Range(
            in: initial,
            location: selectionLocation,
            length: selectionLength,
            with: inserted
        )
    }
}

private let scenarios: [Scenario] = [
    Scenario(id: "empty-ascii", target: .textField, initial: "", selectionLocation: 0, selectionLength: 0, inserted: "Fast text", command: .none),
    Scenario(id: "end-emoji", target: .textField, initial: "Ship ", selectionLocation: 5, selectionLength: 0, inserted: "🚀", command: .none),
    Scenario(id: "middle-composed-accent", target: .textField, initial: "caf noir", selectionLocation: 3, selectionLength: 0, inserted: "e\u{301}", command: .none),
    Scenario(id: "replace-cjk", target: .textField, initial: "hello PLACE world", selectionLocation: 6, selectionLength: 5, inserted: "世界", command: .none),
    Scenario(id: "smart-punctuation", target: .textField, initial: "Quote: ", selectionLocation: 7, selectionLength: 0, inserted: "“fast”—isn’t fragile…", command: .enter),
    Scenario(id: "multiline-newlines", target: .textView, initial: "Header\nTail", selectionLocation: 7, selectionLength: 0, inserted: "line one\nline two\n", command: .none),
    Scenario(id: "command-enter", target: .textField, initial: "Send: ", selectionLocation: 6, selectionLength: 0, inserted: "now", command: .commandEnter),
    Scenario(id: "large-32kb", target: .textView, initial: "", selectionLocation: 0, selectionLength: 0, inserted: String(repeating: "0123456789abcdef", count: 2_048), command: .none),
]

private struct OperationRecord: Codable {
    let strategy: Strategy
    let scenario: String
    let iteration: Int
    let startedNanoseconds: UInt64
    let finishedNanoseconds: UInt64
    let latencyMilliseconds: Double
    let passed: Bool
    let expected: String
    let actual: String?
    let expectedSelectionLocation: Int
    let actualSelectionLocation: Int?
    let sendCommand: SendCommand
    let sendCountBefore: Int
    let sendCountAfter: Int
    let failure: String?
}

private struct Percentiles: Codable {
    let p50: Double
    let p95: Double
    let p99: Double
    let max: Double
}

private struct StrategySummary: Codable {
    let strategy: Strategy
    let operations: Int
    let failures: Int
    let latencyMilliseconds: Percentiles?
}

private struct RunSummary: Codable {
    let schemaVersion: Int
    let status: String
    let reason: String?
    let warmIterations: Int
    let fixturePID: Int32?
    let strategies: [StrategySummary]
    let invariantFailures: [String]
    let promotionGate: String
}

private final class LineWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(url: URL) throws {
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit { try? handle.close() }

    func append<T: Encodable>(_ value: T) throws {
        try handle.write(contentsOf: encoder.encode(value))
        try handle.write(contentsOf: Data([0x0A]))
    }
}

private struct AXTarget {
    let element: AXUIElement
    let pid: pid_t
    let identifier: String
}

private struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }

    func matches(_ pasteboard: NSPasteboard) -> Bool {
        let current = pasteboard.pasteboardItems ?? []
        guard current.count == items.count else { return false }
        return zip(items, current).allSatisfy { expected, actual in
            expected.values.allSatisfy { type, data in
                actual.data(forType: type) == data
            } && Set(expected.values.map(\.0)) == Set(actual.types)
        }
    }
}

private final class FixtureProcess {
    let process = Process()
    let readyURL: URL
    let logURL: URL
    private var fixturePID: pid_t?
    private(set) var targetPoints: [Target: CGPoint] = [:]

    init(executable: URL, evidenceDirectory: URL) {
        readyURL = evidenceDirectory.appendingPathComponent("fixture-ready.json")
        logURL = evidenceDirectory.appendingPathComponent("fixture-events.ndjson")
        try? FileManager.default.removeItem(at: readyURL)
        try? FileManager.default.removeItem(at: logURL)
        if executable.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-W", executable.path, "--args", "--log", logURL.path, "--ready", readyURL.path]
        } else {
            process.executableURL = executable
            process.arguments = ["--log", logURL.path, "--ready", readyURL.path]
        }
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
    }

    func start() throws -> pid_t {
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: readyURL.path),
               let data = try? Data(contentsOf: readyURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = json["pid"] as? Int {
                if let fieldX = json["textFieldX"] as? Double, let fieldY = json["textFieldY"] as? Double {
                    targetPoints[.textField] = CGPoint(x: fieldX, y: fieldY)
                }
                if let viewX = json["textViewX"] as? Double, let viewY = json["textViewY"] as? Double {
                    targetPoints[.textView] = CGPoint(x: viewX, y: viewY)
                }
                fixturePID = pid_t(pid)
                return pid_t(pid)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw NSError(domain: "DeliveryFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture did not become ready."])
    }

    func stop() {
        if let fixturePID { kill(fixturePID, SIGTERM) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

private final class EventCounter {
    private let handle: FileHandle?
    private var pending = Data()
    private var total = 0
    private var commands: [String: Int] = [:]

    init(logURL: URL) {
        handle = try? FileHandle(forReadingFrom: logURL)
    }

    deinit {
        try? handle?.close()
    }

    func count(_ command: SendCommand? = nil) -> Int {
        readNewEvents()
        guard let command else { return total }
        return commands[command.rawValue, default: 0]
    }

    private func readNewEvents() {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        pending.append(data)

        while let newline = pending.firstRange(of: Data([0x0A])) {
            let line = pending[..<newline.lowerBound]
            pending.removeSubrange(...newline.lowerBound)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["kind"] as? String == "sendKey",
                  let command = object["command"] as? String else {
                continue
            }
            total += 1
            commands[command, default: 0] += 1
        }
    }
}

private func replacingUTF16Range(in original: String, location: Int, length: Int, with insertion: String) -> String? {
    let source = original as NSString
    guard location >= 0, length >= 0, location + length <= source.length else { return nil }
    return source.replacingCharacters(in: NSRange(location: location, length: length), with: insertion)
}

private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
    attribute(name, of: element) as? String
}

private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
    attribute(name, of: element) as? Bool
}

private func axAttributeError(_ name: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
}

private func axChildren(of element: AXUIElement) -> [AXUIElement] {
    guard let value = attribute(kAXChildrenAttribute, of: element) else { return [] }
    return value as? [AXUIElement] ?? []
}

private func describeAXTree(
    _ element: AXUIElement,
    depth: Int,
    maxDepth: Int,
    lines: inout [String],
    visited: inout Set<CFHashCode>
) {
    let hash = CFHash(element)
    guard visited.insert(hash).inserted else {
        lines.append("\(String(repeating: "  ", count: depth))<cycle hash=\(hash)>")
        return
    }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let role = stringAttribute(kAXRoleAttribute, of: element) ?? "<none>"
    let subrole = stringAttribute(kAXSubroleAttribute, of: element) ?? "<none>"
    let identifier = stringAttribute(kAXIdentifierAttribute, of: element) ?? "<none>"
    let title = stringAttribute(kAXTitleAttribute, of: element) ?? "<none>"
    let children = axChildren(of: element)
    let indentation = String(repeating: "  ", count: depth)
    lines.append("\(indentation)pid=\(pid) role=\(role) subrole=\(subrole) identifier=\(identifier) title=\(title) children=\(children.count)")
    guard depth < maxDepth else { return }
    for child in children.prefix(64) {
        describeAXTree(child, depth: depth + 1, maxDepth: maxDepth, lines: &lines, visited: &visited)
    }
}

private func writeAXDiagnostics(pid: pid_t, to url: URL) {
    let app = AXUIElementCreateApplication(pid)
    var lines = ["AXIsProcessTrusted=\(AXIsProcessTrusted()) pid=\(pid)"]
    var names: CFArray?
    let namesError = AXUIElementCopyAttributeNames(app, &names)
    lines.append("applicationAttributeNamesError=\(namesError.rawValue) names=\((names as? [String] ?? []).sorted())")
    for name in [kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute] {
        let result = axAttributeError(name, of: app)
        let type = result.1.map { String(CFGetTypeID($0)) } ?? "nil"
        let description = result.1.map { String(describing: $0) } ?? "nil"
        lines.append("applicationAttribute name=\(name) error=\(result.0.rawValue) typeID=\(type) value=\(description)")
        if let value = result.1, CFGetTypeID(value) == AXUIElementGetTypeID() {
            var visited = Set<CFHashCode>()
            describeAXTree(value as! AXUIElement, depth: 1, maxDepth: 3, lines: &lines, visited: &visited)
        }
    }
    var visited = Set<CFHashCode>()
    describeAXTree(app, depth: 0, maxDepth: 8, lines: &lines, visited: &visited)
    try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func rangeAttribute(_ name: String, of element: AXUIElement) -> CFRange? {
    guard let value = attribute(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

private func rangeEquals(_ actual: CFRange?, location: Int, length: Int) -> Bool {
    guard let actual else { return false }
    return actual.location == location && actual.length == length
}

private func setRange(_ range: CFRange, on element: AXUIElement) -> Bool {
    var mutable = range
    guard let value = AXValueCreate(.cfRange, &mutable) else { return false }
    return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
}

private func findTarget(pid: pid_t, target: Target, point: CGPoint?) -> AXTarget? {
    let expectedRole = target == .textField ? (kAXTextFieldRole as String) : (kAXTextAreaRole as String)
    let focusSignal = target == .textField ? SIGUSR2 : SIGUSR1
    guard kill(pid, focusSignal) == 0 else { return nil }
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    var element: AXUIElement?
    var lastRole = "unavailable"
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if let focused = focusedTarget(pid: pid) {
            lastRole = stringAttribute(kAXRoleAttribute, of: focused) ?? "missing"
            if lastRole == expectedRole {
                element = focused
                break
            }
        }
        if let point {
            for root in [AXUIElementCreateSystemWide(), AXUIElementCreateApplication(pid)] {
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
                   let hit {
                    lastRole = stringAttribute(kAXRoleAttribute, of: hit) ?? "missing"
                    if lastRole == expectedRole {
                        element = hit
                        break
                    }
                }
            }
            if element != nil { break }
        }
        usleep(1_000)
    }
    guard let element else {
        FileHandle.standardError.write(Data("Could not focus \(target.rawValue); last AX role was \(lastRole).\n".utf8))
        return nil
    }
    var actualPID: pid_t = 0
    AXUIElementGetPid(element, &actualPID)
    let actualIdentifier = stringAttribute("AXIdentifier", of: element) ?? target.identifier
    return AXTarget(element: element, pid: actualPID, identifier: actualIdentifier)
}

private func setUp(_ scenario: Scenario, target: AXTarget) -> Bool {
    guard activateFixture(pid: target.pid),
          AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, scenario.initial as CFString) == .success,
          AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          setRange(CFRange(location: scenario.selectionLocation, length: scenario.selectionLength), on: target.element) else {
        return false
    }
    return stringAttribute(kAXValueAttribute, of: target.element) == scenario.initial &&
        rangeEquals(
            rangeAttribute(kAXSelectedTextRangeAttribute, of: target.element),
            location: scenario.selectionLocation,
            length: scenario.selectionLength
        )
}

private func activateFixture(pid: pid_t) -> Bool {
    guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
    _ = application.activate(options: [])
    let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return true
        }
        usleep(500)
    }
    return false
}

private func makeKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) -> CGEvent? {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
    event.flags = flags
    return event
}

private func postKey(pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
    guard let down = makeKeyEvent(keyCode: keyCode, flags: flags, down: true),
          let up = makeKeyEvent(keyCode: keyCode, flags: flags, down: false) else { return false }
    // Match the production delivery path. Targeted CGEvent posting delivers
    // Return to the fixture on current macOS builds, but it does not run the
    // responder-chain Paste command. The product posts keyboard events at the
    // HID tap after it has verified the frontmost process and focused target.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        return false
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
}

private func focusedTarget(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    guard let value = attribute(kAXFocusedUIElementAttribute, of: app), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

private func sameTarget(_ lhs: AXUIElement, _ rhs: AXTarget) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(lhs, &pid)
    guard pid == rhs.pid else { return false }
    if CFEqual(lhs, rhs.element) { return true }
    return stringAttribute("AXIdentifier", of: lhs) == rhs.identifier
}

private func canSend(expected: AXTarget, currentPID: pid_t) -> Bool {
    guard currentPID == expected.pid, let focused = focusedTarget(pid: currentPID) else { return false }
    let focusedIdentifier = stringAttribute("AXIdentifier", of: focused)
    return shouldSend(
        expectedPID: expected.pid,
        expectedIdentifier: expected.identifier,
        currentPID: currentPID,
        currentIdentifier: focusedIdentifier
    ) && sameTarget(focused, expected)
}

private func shouldSend(expectedPID: pid_t, expectedIdentifier: String, currentPID: pid_t, currentIdentifier: String?) -> Bool {
    currentPID == expectedPID && currentIdentifier == expectedIdentifier
}

private func waitForExpected(
    _ expected: String,
    selectionLocation: Int,
    target: AXTarget,
    timeoutMilliseconds: Double = 80
) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds * 1_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if stringAttribute(kAXValueAttribute, of: target.element) == expected,
           let range = rangeAttribute(kAXSelectedTextRangeAttribute, of: target.element),
           range.location == selectionLocation,
           range.length == 0 {
            return true
        }
        usleep(250)
    }
    return false
}

private func waitForSendCount(
    _ expected: Int,
    counter: EventCounter,
    timeoutMilliseconds: Double = 250
) -> Int {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds * 1_000_000)
    var count = counter.count()
    while count < expected && DispatchTime.now().uptimeNanoseconds < deadline {
        usleep(250)
        count = counter.count()
    }
    return count
}

private func withTemporaryClipboardText<T>(_ text: String, operation: (_ injectedChangeCount: Int) throws -> T) rethrows -> (T, restored: Bool, contentRestored: Bool) {
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let injectedChangeCount = pasteboard.changeCount
    let result = try operation(injectedChangeCount)
    let canRestore = shouldRestoreClipboard(currentChangeCount: pasteboard.changeCount, injectedChangeCount: injectedChangeCount)
    if canRestore {
        snapshot.restore(pasteboard)
    }
    let contentRestored: Bool
    if snapshot.items.isEmpty {
        contentRestored = snapshot.matches(pasteboard)
    } else {
        contentRestored = canRestore && snapshot.matches(pasteboard)
    }
    return (result, canRestore, contentRestored)
}

private func shouldRestoreClipboard(currentChangeCount: Int, injectedChangeCount: Int) -> Bool {
    currentChangeCount == injectedChangeCount
}

private func directReplace(scenario: Scenario, target: AXTarget, expected: String) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(target.element, kAXValueAttribute as CFString, &settable) == .success,
          directReplacementIsQualified(
              target: scenario.target,
              role: stringAttribute(kAXRoleAttribute, of: target.element),
              isEditable: boolAttribute(kAXIsEditableAttribute, of: target.element),
              valueIsSettable: settable.boolValue,
              selectionMatches: rangeEquals(
                  rangeAttribute(kAXSelectedTextRangeAttribute, of: target.element),
                  location: scenario.selectionLocation,
                  length: scenario.selectionLength
              )
          ),
          AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, expected as CFString) == .success else {
        return false
    }
    let end = scenario.selectionLocation + (scenario.inserted as NSString).length
    return setRange(CFRange(location: end, length: 0), on: target.element)
}

private func directReplacementIsQualified(
    target: Target,
    role: String?,
    isEditable: Bool?,
    valueIsSettable: Bool,
    selectionMatches: Bool
) -> Bool {
    target == .textField &&
        role == (kAXTextFieldRole as String) &&
        isEditable == true &&
        valueIsSettable &&
        selectionMatches
}

private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let index = Int(ceil(Double(sorted.count) * fraction)) - 1
    return sorted[max(0, min(sorted.count - 1, index))]
}

private func summarize(_ strategy: Strategy, records: [OperationRecord]) -> StrategySummary {
    let own = records.filter { $0.strategy == strategy }
    let successful = own.filter(\.passed).map(\.latencyMilliseconds).sorted()
    let metrics = successful.isEmpty ? nil : Percentiles(
        p50: percentile(successful, 0.50),
        p95: percentile(successful, 0.95),
        p99: percentile(successful, 0.99),
        max: successful.last ?? .nan
    )
    return StrategySummary(strategy: strategy, operations: own.count, failures: own.filter { !$0.passed }.count, latencyMilliseconds: metrics)
}

private func runOperation(
    strategy: Strategy,
    scenario: Scenario,
    iteration: Int,
    target: AXTarget,
    counter: EventCounter
) -> OperationRecord {
    let expected = scenario.expected ?? "<invalid fixture range>"
    let expectedSelectionLocation = scenario.selectionLocation + (scenario.inserted as NSString).length
    let sendBefore = counter.count()
    var failure: String?
    var clipboardRestored = true
    let signpostID = OSSignpostID(log: performanceLog)
    let started = DispatchTime.now().uptimeNanoseconds
    os_signpost(.begin, log: performanceLog, name: "DeliveryOperation", signpostID: signpostID, "%{public}s", strategy.rawValue)

    if !setUp(scenario, target: target) {
        failure = "Could not configure the target through Accessibility."
    } else if strategy == .qualifiedAXReplacement {
        if !directReplace(scenario: scenario, target: target, expected: expected) {
            failure = scenario.target == .textField ? "Qualified AXValue replacement failed." : "Not a qualified native plain field."
        } else if scenario.command != .none && canSend(expected: target, currentPID: target.pid) &&
                    !postKey(pid: target.pid, keyCode: scenario.command.keyCode, flags: scenario.command.flags) {
            failure = "Could not post the send key."
        }
    } else {
        let clipboardResult = withTemporaryClipboardText(scenario.inserted) { _ in
            guard postKey(pid: target.pid, keyCode: 0x09, flags: .maskCommand) else { return false }
            switch strategy {
            case .paste80ms:
                usleep(80_000)
                if scenario.command != .none {
                    guard waitForExpected(
                        expected,
                        selectionLocation: expectedSelectionLocation,
                        target: target,
                        timeoutMilliseconds: 1
                    ) else { return false }
                    guard canSend(expected: target, currentPID: target.pid) else { return false }
                    return postKey(pid: target.pid, keyCode: scenario.command.keyCode, flags: scenario.command.flags)
                }
                return true
            case .orderedPasteAndSend:
                if scenario.command != .none {
                    return postKey(pid: target.pid, keyCode: scenario.command.keyCode, flags: scenario.command.flags)
                }
                return true
            case .verifiedPasteAndSend:
                guard waitForExpected(expected, selectionLocation: expectedSelectionLocation, target: target) else { return false }
                if scenario.command != .none {
                    guard canSend(expected: target, currentPID: target.pid) else { return false }
                    return postKey(pid: target.pid, keyCode: scenario.command.keyCode, flags: scenario.command.flags)
                }
                return true
            case .qualifiedAXReplacement:
                return false
            }
        }
        clipboardRestored = clipboardResult.contentRestored
        if !clipboardResult.0 {
            failure = "Paste or send operation failed."
        } else if !clipboardResult.restored || !clipboardResult.contentRestored {
            failure = "Guarded clipboard restoration failed."
        }
    }

    usleep(2_000)
    let actual = stringAttribute(kAXValueAttribute, of: target.element)
    let actualSelection = rangeAttribute(kAXSelectedTextRangeAttribute, of: target.element)
    let finished = DispatchTime.now().uptimeNanoseconds
    os_signpost(.end, log: performanceLog, name: "DeliveryOperation", signpostID: signpostID, "%{public}s", failure == nil ? "pass" : "fail")
    let expectedSends = scenario.command == .none ? 0 : 1
    let sendAfter = expectedSends == 0
        ? counter.count()
        : waitForSendCount(sendBefore + expectedSends, counter: counter)
    if failure == nil && actual != expected { failure = "Value mismatch." }
    // Return can commit an NSTextField and remove its editor. For send cases,
    // each guarded strategy proves the value and caret before it posts Return.
    if failure == nil && scenario.command == .none &&
        !rangeEquals(actualSelection, location: expectedSelectionLocation, length: 0) {
        failure = "Selection mismatch."
    }
    if failure == nil && sendAfter - sendBefore != expectedSends { failure = "Send count mismatch." }
    if failure == nil && !clipboardRestored { failure = "Clipboard content was not restored." }

    return OperationRecord(
        strategy: strategy,
        scenario: scenario.id,
        iteration: iteration,
        startedNanoseconds: started,
        finishedNanoseconds: finished,
        latencyMilliseconds: Double(finished - started) / 1_000_000,
        passed: failure == nil,
        expected: expected,
        actual: actual,
        expectedSelectionLocation: expectedSelectionLocation,
        actualSelectionLocation: actualSelection?.location,
        sendCommand: scenario.command,
        sendCountBefore: sendBefore,
        sendCountAfter: sendAfter,
        failure: failure
    )
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func writeVerdict(_ summary: RunSummary, to directory: URL) throws {
    let metrics = summary.strategies.map { strategy -> String in
        guard let latency = strategy.latencyMilliseconds else {
            return "| \(strategy.strategy.rawValue) | \(strategy.operations) | \(strategy.failures) | unavailable | unavailable | unavailable | unavailable |"
        }
        return String(
            format: "| %@ | %d | %d | %.3f ms | %.3f ms | %.3f ms | %.3f ms |",
            strategy.strategy.rawValue,
            strategy.operations,
            strategy.failures,
            latency.p50,
            latency.p95,
            latency.p99,
            latency.max
        )
    }.joined(separator: "\n")
    let failures = summary.invariantFailures.isEmpty
        ? "None in the checks that ran."
        : summary.invariantFailures.map { "- \($0)" }.joined(separator: "\n")
    let text = """
    # Auto Send delivery fixture verdict

    Status: **\(summary.status.uppercased())**

    \(summary.promotionGate)

    Reason: \(summary.reason ?? "The live run completed.")

    ## Live measurements

    | Strategy | Operations | Failures | p50 | p95 | p99 | max |
    |---|---:|---:|---:|---:|---:|---:|
    \(metrics.isEmpty ? "| No live measurements | 0 | 0 | unavailable | unavailable | unavailable | unavailable |" : metrics)

    ## Invariant failures

    \(failures)

    ## Decision

    Keep the fixture. Do not promote any product delivery path until this exact live two-process gate passes:

    ```bash
    DELIVERY_FIXTURE_ITERATIONS=40 Bench/DeliveryFixture/run_delivery_fixture.sh
    ```
    """
    try text.write(to: directory.appendingPathComponent("verdict.md"), atomically: true, encoding: .utf8)
}

private func runUnitGoldens(evidenceDirectory: URL) throws -> [String] {
    let cases: [(String, Int, Int, String, String)] = [
        ("", 0, 0, "hello", "hello"),
        ("ab", 2, 0, "🚀", "ab🚀"),
        ("caf noir", 3, 0, "e\u{301}", "cafe\u{301} noir"),
        ("hello PLACE world", 6, 5, "世界", "hello 世界 world"),
        ("A\nB", 2, 0, "one\ntwo\n", "A\none\ntwo\nB"),
        ("Quote: ", 7, 0, "“fast”—isn’t fragile…", "Quote: “fast”—isn’t fragile…"),
        ("", 0, 0, String(repeating: "0123456789abcdef", count: 2_048), String(repeating: "0123456789abcdef", count: 2_048)),
    ]
    var failures: [String] = []
    var outputs: [[String: Any]] = []
    for (index, item) in cases.enumerated() {
        let actual = replacingUTF16Range(in: item.0, location: item.1, length: item.2, with: item.3)
        let passed = actual == item.4
        if !passed { failures.append("UTF-16 golden \(index) failed.") }
        outputs.append(["id": index, "passed": passed, "expected": item.4, "actual": actual as Any])
    }
    let validGuard = shouldRestoreClipboard(currentChangeCount: 21, injectedChangeCount: 21)
    let changedGuard = shouldRestoreClipboard(currentChangeCount: 22, injectedChangeCount: 21)
    outputs.append(["id": "clipboard-unchanged-count-restores", "passed": validGuard])
    outputs.append(["id": "clipboard-changed-count-suppresses-restore", "passed": !changedGuard])
    if !validGuard || changedGuard { failures.append("Clipboard change-count guard failed.") }
    let expectedPID: pid_t = 800
    let sameDestination = shouldSend(expectedPID: expectedPID, expectedIdentifier: "field", currentPID: expectedPID, currentIdentifier: "field")
    let focusChanged = shouldSend(expectedPID: expectedPID, expectedIdentifier: "field", currentPID: expectedPID, currentIdentifier: "view")
    let pidChanged = shouldSend(expectedPID: expectedPID, expectedIdentifier: "field", currentPID: 801, currentIdentifier: "field")
    outputs.append(["id": "same-destination-allows-send", "passed": sameDestination])
    outputs.append(["id": "focus-change-suppresses-send", "passed": !focusChanged])
    outputs.append(["id": "pid-change-suppresses-send", "passed": !pidChanged])
    let enterDescriptorPasses = SendCommand.enter.keyCode == 0x24 && SendCommand.enter.flags.isEmpty
    let commandEnterDescriptorPasses = SendCommand.commandEnter.keyCode == 0x24 && SendCommand.commandEnter.flags == .maskCommand
    outputs.append(["id": "enter-descriptor", "passed": enterDescriptorPasses])
    outputs.append(["id": "command-enter-descriptor", "passed": commandEnterDescriptorPasses])
    if !sameDestination || focusChanged || pidChanged { failures.append("Destination guard golden failed.") }
    if !enterDescriptorPasses || !commandEnterDescriptorPasses { failures.append("Send command descriptor golden failed.") }
    let directQualified = directReplacementIsQualified(
        target: .textField,
        role: kAXTextFieldRole as String,
        isEditable: true,
        valueIsSettable: true,
        selectionMatches: true
    )
    let directAmbiguous = directReplacementIsQualified(
        target: .textField,
        role: kAXTextFieldRole as String,
        isEditable: nil,
        valueIsSettable: true,
        selectionMatches: true
    )
    let directWrongRole = directReplacementIsQualified(
        target: .textView,
        role: kAXTextAreaRole as String,
        isEditable: true,
        valueIsSettable: true,
        selectionMatches: true
    )
    outputs.append(["id": "qualified-direct-write", "passed": directQualified])
    outputs.append(["id": "ambiguous-direct-write-has-no-fallback", "passed": !directAmbiguous])
    outputs.append(["id": "wrong-role-direct-write-has-no-fallback", "passed": !directWrongRole])
    if !directQualified || directAmbiguous || directWrongRole {
        failures.append("Direct-write qualification golden failed.")
    }
    let data = try JSONSerialization.data(withJSONObject: outputs, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: evidenceDirectory.appendingPathComponent("unit-goldens.json"), options: .atomic)
    return failures
}

private func runSuppressionChecks(pid: pid_t, field: AXTarget, textView: AXTarget, counter: EventCounter) -> [String] {
    var failures: [String] = []
    let before = counter.count()
    _ = AXUIElementSetAttributeValue(field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(textView.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if canSend(expected: field, currentPID: pid) { failures.append("Focus-change send was not suppressed.") }
    if canSend(expected: field, currentPID: pid + 100_000) { failures.append("PID-change send was not suppressed.") }
    usleep(5_000)
    if counter.count() != before { failures.append("Suppression check emitted a send event.") }
    return failures
}

private func runClipboardExternalChangeCheck() -> [String] {
    let pasteboard = NSPasteboard.general
    let original = PasteboardSnapshot.capture(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("fixture-injected", forType: .string)
    let injectedCount = pasteboard.changeCount
    pasteboard.clearContents()
    pasteboard.setString("simulated-external-change", forType: .string)
    let shouldRestore = shouldRestoreClipboard(currentChangeCount: pasteboard.changeCount, injectedChangeCount: injectedCount)
    if shouldRestore { original.restore(pasteboard) }
    let preserved = pasteboard.string(forType: .string) == "simulated-external-change"
    original.restore(pasteboard)
    return (!shouldRestore && preserved) ? [] : ["Clipboard external-change guard failed."]
}

private struct Options {
    var fixtureExecutable: URL?
    var evidenceDirectory: URL
    var warmIterations = 20
    var textEditProbe = false

    init(arguments: [String]) {
        var evidence = URL(fileURLWithPath: ".autoresearch/auto-send-delivery-fixture", isDirectory: true)
        var fixture: URL?
        var iterations = 20
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--fixture" where index + 1 < arguments.count:
                fixture = URL(fileURLWithPath: arguments[index + 1]); index += 2
            case "--evidence" where index + 1 < arguments.count:
                evidence = URL(fileURLWithPath: arguments[index + 1], isDirectory: true); index += 2
            case "--iterations" where index + 1 < arguments.count:
                iterations = Int(arguments[index + 1]) ?? 20; index += 2
            case "--textedit-probe":
                textEditProbe = true; index += 1
            default:
                index += 1
            }
        }
        fixtureExecutable = fixture
        evidenceDirectory = evidence
        warmIterations = max(1, iterations)
    }
}

private struct TextEditProbeSummary: Codable {
    let status: String
    let pid: pid_t?
    let focusedRole: String?
    let focusedIdentifier: String?
    let reason: String
}

private func runTextEditProbe(evidenceDirectory: URL) throws -> Int32 {
    let bundleIdentifier = "com.apple.TextEdit"
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
        let summary = TextEditProbeSummary(
            status: "blocked",
            pid: nil,
            focusedRole: nil,
            focusedIdentifier: nil,
            reason: "TextEdit was already running. The fixture did not touch it."
        )
        try writeJSON(summary, to: evidenceDirectory.appendingPathComponent("textedit-probe.json"))
        return 77
    }

    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-na", "TextEdit"]
    try launcher.run()
    launcher.waitUntilExit()
    guard launcher.terminationStatus == 0 else {
        let summary = TextEditProbeSummary(
            status: "blocked",
            pid: nil,
            focusedRole: nil,
            focusedIdentifier: nil,
            reason: "The open command could not launch TextEdit."
        )
        try writeJSON(summary, to: evidenceDirectory.appendingPathComponent("textedit-probe.json"))
        return 77
    }

    let launchDeadline = Date().addingTimeInterval(5)
    var running: NSRunningApplication?
    while Date() < launchDeadline {
        running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        if running != nil { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard let running else {
        let summary = TextEditProbeSummary(
            status: "blocked",
            pid: nil,
            focusedRole: nil,
            focusedIdentifier: nil,
            reason: "TextEdit launched, but its process could not be resolved."
        )
        try writeJSON(summary, to: evidenceDirectory.appendingPathComponent("textedit-probe.json"))
        return 77
    }

    let pid = running.processIdentifier
    defer {
        _ = postKey(pid: pid, keyCode: 0x0D, flags: .maskCommand)
        usleep(100_000)
        _ = running.terminate()
    }
    _ = running.activate(options: [])
    usleep(300_000)
    _ = postKey(pid: pid, keyCode: 0x2D, flags: .maskCommand)

    let focusDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    var focused: AXUIElement?
    var focusedRole: String?
    while DispatchTime.now().uptimeNanoseconds < focusDeadline {
        if let candidate = focusedTarget(pid: pid) {
            let role = stringAttribute(kAXRoleAttribute, of: candidate)
            focusedRole = role
            if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
                focused = candidate
                break
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    writeAXDiagnostics(pid: pid, to: evidenceDirectory.appendingPathComponent("textedit-ax-diagnostics.txt"))

    let identifier = focused.flatMap { stringAttribute(kAXIdentifierAttribute, of: $0) }
    let found = focused != nil
    let summary = TextEditProbeSummary(
        status: found ? "complete" : "blocked",
        pid: pid,
        focusedRole: focusedRole,
        focusedIdentifier: identifier,
        reason: found
            ? "TextEdit exposed a focused editable text element."
            : "TextEdit did not expose a focused AXTextArea or AXTextField."
    )
    try writeJSON(summary, to: evidenceDirectory.appendingPathComponent("textedit-probe.json"))
    return found ? 0 : 77
}

private func main() throws -> Int32 {
    let options = Options(arguments: CommandLine.arguments)
    try FileManager.default.createDirectory(at: options.evidenceDirectory, withIntermediateDirectories: true)
    var invariantFailures = try runUnitGoldens(evidenceDirectory: options.evidenceDirectory)

    guard AXIsProcessTrusted() else {
        let summary = RunSummary(
            schemaVersion: 1,
            status: "blocked",
            reason: "Accessibility permission is not enabled for DeliveryController.",
            warmIterations: options.warmIterations,
            fixturePID: nil,
            strategies: [],
            invariantFailures: invariantFailures,
            promotionGate: "BLOCKED: no live two-process evidence; do not promote a direct-insertion path."
        )
        try writeJSON(summary, to: options.evidenceDirectory.appendingPathComponent("summary.json"))
        try writeVerdict(summary, to: options.evidenceDirectory)
        print("BLOCKED: Enable Accessibility for DeliveryController, then rerun the exact command in README.md.")
        return 77
    }

    if options.textEditProbe {
        return try runTextEditProbe(evidenceDirectory: options.evidenceDirectory)
    }

    guard let executable = options.fixtureExecutable else {
        FileHandle.standardError.write(Data("--fixture PATH is required for a live run.\n".utf8))
        return 64
    }
    let fixture = FixtureProcess(executable: executable, evidenceDirectory: options.evidenceDirectory)
    let pid = try fixture.start()
    defer { fixture.stop() }
    let counter = EventCounter(logURL: fixture.logURL)
    writeAXDiagnostics(pid: pid, to: options.evidenceDirectory.appendingPathComponent("ax-diagnostics.txt"))

    guard let field = findTarget(pid: pid, target: .textField, point: fixture.targetPoints[.textField]),
          let textView = findTarget(pid: pid, target: .textView, point: fixture.targetPoints[.textView]) else {
        let summary = RunSummary(
            schemaVersion: 1,
            status: "blocked",
            reason: "The controller is trusted, but macOS did not expose both fixture text targets through Accessibility.",
            warmIterations: options.warmIterations,
            fixturePID: pid,
            strategies: [],
            invariantFailures: invariantFailures,
            promotionGate: "BLOCKED: no live two-process evidence; do not promote a direct-insertion path."
        )
        try writeJSON(summary, to: options.evidenceDirectory.appendingPathComponent("summary.json"))
        try writeVerdict(summary, to: options.evidenceDirectory)
        print(summary.promotionGate)
        return 77
    }

    invariantFailures += runSuppressionChecks(pid: pid, field: field, textView: textView, counter: counter)
    invariantFailures += runClipboardExternalChangeCheck()

    let operationWriter = try LineWriter(url: options.evidenceDirectory.appendingPathComponent("operations.ndjson"))
    var records: [OperationRecord] = []
    for strategy in Strategy.allCases {
        for iteration in -3..<options.warmIterations {
            for scenario in scenarios {
                if strategy == .qualifiedAXReplacement && scenario.target != .textField { continue }
                let target = scenario.target == .textField ? field : textView
                let record = runOperation(strategy: strategy, scenario: scenario, iteration: iteration, target: target, counter: counter)
                if iteration >= 0 {
                    records.append(record)
                    try operationWriter.append(record)
                }
            }
        }
    }

    let summaries = Strategy.allCases.map { summarize($0, records: records) }
    let baselineFailures = records.filter { $0.strategy == .paste80ms && !$0.passed }
    invariantFailures += baselineFailures.map { "\($0.strategy.rawValue)/\($0.scenario): \($0.failure ?? "unknown")" }
    let baseline = summaries.first { $0.strategy == .paste80ms }?.latencyMilliseconds?.p50 ?? .infinity
    let candidate = summaries
        .filter {
            ($0.strategy == .verifiedPasteAndSend || $0.strategy == .qualifiedAXReplacement) &&
                $0.failures == 0
        }
        .compactMap { $0.latencyMilliseconds?.p50 }
        .min() ?? .infinity
    let materialReduction = candidate <= baseline * 0.75
    let gatePassed = invariantFailures.isEmpty && materialReduction
    let summary = RunSummary(
        schemaVersion: 1,
        status: "complete",
        reason: nil,
        warmIterations: options.warmIterations,
        fixturePID: pid,
        strategies: summaries,
        invariantFailures: invariantFailures,
        promotionGate: gatePassed
            ? "PASS: zero observed loss, duplication, cross-target delivery, and double-send; best candidate materially reduced the 80 ms baseline."
            : "REJECT: one or more correctness invariants failed, or no candidate reduced median latency by at least 25%."
    )
    try writeJSON(summary, to: options.evidenceDirectory.appendingPathComponent("summary.json"))
    try writeVerdict(summary, to: options.evidenceDirectory)
    print(summary.promotionGate)
    return gatePassed ? 0 : 1
}

do {
    exit(try main())
} catch {
    FileHandle.standardError.write(Data("delivery fixture failed: \(error)\n".utf8))
    exit(1)
}
