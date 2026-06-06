import Foundation

enum DiagnosticSubsystem: String, Codable, Equatable {
    case microphone
    case accessibility
    case hotKey
    case openAIRealtime
    case transcription
    case improvement
    case localRuntime
    case archive
}

enum DiagnosticSeverity: String, Codable, Equatable {
    case info
    case warning
    case error
}

struct DiagnosticEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var subsystem: DiagnosticSubsystem
    var severity: DiagnosticSeverity
    var summary: String
    var details: String
    var relatedProvider: String?
}

protocol DiagnosticsStore: AnyObject {
    func record(_ event: DiagnosticEvent)
    func latestEvents(limit: Int) -> [DiagnosticEvent]
    func clear()
}

final class UserDefaultsDiagnosticsStore: DiagnosticsStore {
    private let defaults: UserDefaults
    private let key: String
    private let maxEvents: Int
    private let queue = DispatchQueue(label: "com.fieldtheory.air.diagnostics-store", qos: .utility)
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = "diagnosticEvents.v1",
        maxEvents: Int = 50
    ) {
        self.defaults = defaults
        self.key = key
        self.maxEvents = maxEvents
    }

    func record(_ event: DiagnosticEvent) {
        queue.async { [weak self] in
            self?.append(event)
        }
    }

    func latestEvents(limit: Int) -> [DiagnosticEvent] {
        Array(loadEvents().prefix(max(limit, 0)))
    }

    func clear() {
        lock.lock()
        defaults.removeObject(forKey: key)
        lock.unlock()
    }

    private func append(_ event: DiagnosticEvent) {
        lock.lock()
        var events = loadEventsLocked()
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        saveEventsLocked(events)
        lock.unlock()
    }

    private func loadEvents() -> [DiagnosticEvent] {
        lock.lock()
        let events = loadEventsLocked()
        lock.unlock()
        return events
    }

    private func loadEventsLocked() -> [DiagnosticEvent] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) else {
            return []
        }
        return events.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveEventsLocked(_ events: [DiagnosticEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: key)
    }
}
