import Foundation

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard var rows = try JSONSerialization.jsonObject(with: input) as? [[String: Any]] else {
        throw NSError(domain: "PseudoRefNormalize", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input must be a JSON array."])
    }
    for index in rows.indices {
        guard let transcript = rows[index]["transcript"] as? String else {
            throw NSError(domain: "PseudoRefNormalize", code: 2, userInfo: [NSLocalizedDescriptionKey: "A row has no transcript."])
        }
        rows[index]["productNormalizedTranscript"] = TranscriptTextNormalizer.normalizeSpokenNumbers(in: transcript)
    }
    let output = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Pseudo-reference normalization failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
