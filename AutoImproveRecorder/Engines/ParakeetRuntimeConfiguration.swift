import Foundation

/// Where one app's parakeet.cpp runtime is installed. Each app declares
/// `ParakeetRuntimeConfiguration.app` once, in a file only that app compiles.
struct ParakeetRuntimeConfiguration: Sendable {
    /// Returns the install root. It is called every time a path is built, so
    /// a root that changes while the app runs is seen by later calls.
    let resolveRoot: @Sendable () -> URL

    /// A configuration that resolves to `preferredRoot()` while
    /// `preferredRootIsReady()` is true and to `fallbackRoot()` otherwise.
    /// Readiness is checked on every resolution.
    static func preferring(
        _ preferredRoot: @escaping @Sendable () -> URL,
        whenReady preferredRootIsReady: @escaping @Sendable () -> Bool,
        otherwise fallbackRoot: @escaping @Sendable () -> URL
    ) -> ParakeetRuntimeConfiguration {
        ParakeetRuntimeConfiguration {
            if preferredRootIsReady() { return preferredRoot() }
            return fallbackRoot()
        }
    }
}

/// Model filenames under `<root>/models` that both apps load in-process.
enum ParakeetModelFilename {
    static let liveRecommended = "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
}
