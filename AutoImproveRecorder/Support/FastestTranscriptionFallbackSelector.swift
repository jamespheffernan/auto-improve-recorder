import Foundation

enum FastestTranscriptionFallback: Equatable {
    case parakeetCppRecommended
}

enum FastestTranscriptionFallbackSelector {
    static func fallback(isParakeetCppRecommendedInstalled: Bool) -> FastestTranscriptionFallback {
        .parakeetCppRecommended
    }
}
