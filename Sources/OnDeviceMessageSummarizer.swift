import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum OnDeviceMessageSummarizer {
    static func source(title: String, body: String?) -> String {
        let parts = [title, body].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.joined(separator: "\n")
    }

    enum Failure: String, Error {
        case unsupportedDevice = "model_unsupported_device"
        case intelligenceDisabled = "model_intelligence_disabled"
        case modelNotReady = "model_not_ready"
        case modelUnavailable = "model_unavailable"
        case guardrail = "model_guardrail"
        case unsupportedLanguage = "model_unsupported_language"
        case contextTooLong = "model_context_too_long"
        case rateLimited = "model_rate_limited"
        case concurrentRequests = "model_concurrent_requests"
        case emptyOutput = "model_empty_output"
        case generationFailed = "model_generation_failed"

        var canSkipHighlight: Bool {
            self == .guardrail || self == .unsupportedLanguage || self == .contextTooLong
        }
    }

    // Reading this in a SwiftUI body tracks the observable system model.
    static var unavailability: Failure? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return .unsupportedDevice
            case .unavailable(.appleIntelligenceNotEnabled): return .intelligenceDisabled
            case .unavailable(.modelNotReady): return .modelNotReady
            @unknown default: return .modelUnavailable
            }
        }
        #endif
        return .unsupportedDevice
    }

    static func generate(_ text: String, instructions: String) async throws -> String {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyOutput }
        if let unavailability { throw unavailability }
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            do {
                let response = try await LanguageModelSession(instructions: instructions).respond(to: text)
                try Task.checkCancellation()
                let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else { throw Failure.emptyOutput }
                return result
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if let failure = error as? Failure { throw failure }
                switch error as? LanguageModelError {
                case .contextSizeExceeded: throw Failure.contextTooLong
                case .guardrailViolation, .refusal: throw Failure.guardrail
                case .unsupportedLanguageOrLocale: throw Failure.unsupportedLanguage
                case .rateLimited: throw Failure.rateLimited
                default: break
                }
                if case .concurrentRequests = error as? LanguageModelSession.Error {
                    throw Failure.concurrentRequests
                }
                if case .assetsUnavailable = error as? SystemLanguageModel.Error {
                    throw unavailability ?? Failure.modelUnavailable
                }
                throw Failure.generationFailed
            }
        }
        #endif
        throw Failure.unsupportedDevice
    }
}
