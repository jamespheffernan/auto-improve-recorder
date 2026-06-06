import Foundation

enum RealtimeDiagnosticsRedactor {
    static func redactedJSON(_ json: [String: Any], fallback: String) -> String {
        let redacted = redactingPromptFields(in: json)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(
                  withJSONObject: redacted,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return fallback
        }
        return String(data: data, encoding: .utf8) ?? fallback
    }

    static func sanitizedProviderErrorMessage(_ message: String, dictionarySnapshot: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Realtime API error." }
        guard !dictionarySnapshot.isEmpty else { return trimmed }
        return "Realtime API error. Dictionary prompt was active; provider message redacted."
    }

    private static func redactingPromptFields(in value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key.caseInsensitiveCompare("prompt") == .orderedSame {
                    dictionary[key] = "<redacted>"
                } else {
                    dictionary[key] = redactingPromptFields(in: child)
                }
            }
            return dictionary
        }

        if let array = value as? [Any] {
            return array.map { redactingPromptFields(in: $0) }
        }

        return value
    }
}
