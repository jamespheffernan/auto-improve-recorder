import Foundation
import Darwin

protocol LocalRuntimeProbe: Sendable {
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func paths(matching pattern: String) -> [String]
    func ollamaModelTags(baseURL: URL) async throws -> [String]
    func operatingSystemVersion() -> OperatingSystemVersion
    func physicalMemoryBytes() -> UInt64
    func parakeetLiveRuntimeCapability(libraryPath: String) -> ParakeetLiveRuntimeCapability
}

struct DefaultLocalRuntimeProbe: LocalRuntimeProbe, @unchecked Sendable {
    private let fileManager: FileManager
    private let urlSession: URLSession

    init(fileManager: FileManager = .default, urlSession: URLSession = .shared) {
        self.fileManager = fileManager
        self.urlSession = urlSession
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: expandTilde(path))
    }

    func isExecutableFile(atPath path: String) -> Bool {
        fileManager.isExecutableFile(atPath: expandTilde(path))
    }

    func paths(matching pattern: String) -> [String] {
        let expandedPattern = expandTilde(pattern)
        let directory = (expandedPattern as NSString).deletingLastPathComponent
        let filePattern = (expandedPattern as NSString).lastPathComponent
        guard filePattern.contains("*"),
              let regex = try? NSRegularExpression(pattern: "^" + NSRegularExpression.escapedPattern(for: filePattern).replacingOccurrences(of: "\\*", with: ".*") + "$"),
              let contents = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return fileManager.fileExists(atPath: expandedPattern) ? [expandedPattern] : []
        }

        return contents
            .filter { name in
                let range = NSRange(location: 0, length: (name as NSString).length)
                return regex.firstMatch(in: name, range: range) != nil
            }
            .map { (directory as NSString).appendingPathComponent($0) }
            .sorted()
    }

    func ollamaModelTags(baseURL: URL) async throws -> [String] {
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 0.75

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LocalRuntimeProbeError.unhealthyOllama
        }

        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return tags.models.map(\.name)
    }

    func operatingSystemVersion() -> OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    func physicalMemoryBytes() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    func parakeetLiveRuntimeCapability(libraryPath: String) -> ParakeetLiveRuntimeCapability {
        let expandedPath = expandTilde(libraryPath)
        guard let handle = dlopen(expandedPath, RTLD_NOW | RTLD_LOCAL) else {
            return .loadFailed
        }
        defer { dlclose(handle) }
        let hasEverySymbol = ParakeetLiveSafetyPolicy.requiredRuntimeSymbols.allSatisfy {
            dlsym(handle, $0) != nil
        }
        return hasEverySymbol ? .ready : .missingSymbols
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum LocalRuntimeProbeError: Error, Equatable, Sendable {
    case unhealthyOllama
}

private struct OllamaTagsResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let name: String
    }

    let models: [Model]
}
