import Foundation

/// Where one app's parakeet.cpp runtime is installed. Each app declares
/// `ParakeetRuntimeConfiguration.app` once, in a file only that app compiles.
struct ParakeetRuntimeConfiguration: Sendable {
    private let currentRoot: @Sendable () -> URL
    /// Shared by every copy of this configuration.
    private let keptRoot = KeptRoot()

    init(resolveRoot: @escaping @Sendable () -> URL) {
        currentRoot = resolveRoot
    }

    /// Returns the install root. It is called every time a path is built.
    /// Until `keepRoot` is called the root is resolved on every call, so a
    /// root that changes while the app runs is seen by later calls. After
    /// that, every call returns the kept root.
    func resolveRoot() -> URL {
        keptRoot.value ?? currentRoot()
    }

    /// Fixes the root for the rest of the process. The resident runtime calls
    /// this with the root its library loaded from, so the library, the
    /// models and the CLI all come from one root. Only the first call counts.
    func keepRoot(_ root: URL) {
        keptRoot.keep(root)
    }

    private final class KeptRoot: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?

        var value: URL? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func keep(_ root: URL) {
            lock.lock()
            defer { lock.unlock() }
            if stored == nil {
                stored = root
            }
        }
    }

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
