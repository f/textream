import Foundation
import NaturalLanguage
import Observation
import Speech

nonisolated struct SpeechLanguageSuggestion: Equatable, Sendable {
    let detectedLanguageIdentifier: String
    let languageCode: String
    let localeIdentifier: String
    let confidence: Double

    var languageName: String {
        Locale.current.localizedString(forIdentifier: detectedLanguageIdentifier)
            ?? Locale.current.localizedString(forLanguageCode: languageCode)
            ?? detectedLanguageIdentifier
    }

    var localeName: String {
        Locale.current.localizedString(forIdentifier: localeIdentifier) ?? languageName
    }
}

nonisolated enum SpeechLocaleSupport {
    static func closestSupportedLocale(
        for language: Locale.Language,
        preferredRegion: Locale.Region? = Locale.current.region,
        supportedLocales: [Locale]
    ) -> Locale? {
        guard let languageCode = language.languageCode?.identifier else { return nil }
        let candidates = supportedLocales.filter {
            $0.language.languageCode?.identifier == languageCode
        }
        guard !candidates.isEmpty else { return nil }

        let target = Locale.Language(identifier: language.maximalIdentifier)
        return candidates.sorted { lhs, rhs in
            let lhsScore = score(lhs, target: target, preferredRegion: preferredRegion)
            let rhsScore = score(rhs, target: target, preferredRegion: preferredRegion)
            if lhsScore == rhsScore { return lhs.identifier < rhs.identifier }
            return lhsScore > rhsScore
        }.first
    }

    static func matches(language: Locale.Language, localeIdentifier: String) -> Bool {
        let selected = Locale.Language(identifier: localeIdentifier)
        guard language.languageCode?.identifier == selected.languageCode?.identifier else {
            return false
        }

        let detectedScript = Locale.Language(identifier: language.maximalIdentifier).script?.identifier
        let selectedScript = Locale.Language(identifier: selected.maximalIdentifier).script?.identifier
        return detectedScript == nil || selectedScript == nil || detectedScript == selectedScript
    }

    private static func score(
        _ locale: Locale,
        target: Locale.Language,
        preferredRegion: Locale.Region?
    ) -> Int {
        let candidate = Locale.Language(identifier: locale.language.maximalIdentifier)
        var result = 0
        if candidate.script?.identifier == target.script?.identifier { result += 200 }
        if let preferredRegion, locale.region?.identifier == preferredRegion.identifier { result += 100 }
        if candidate.region?.identifier == target.region?.identifier { result += 50 }
        return result
    }
}

nonisolated enum SpeechLanguageDetector {
    nonisolated struct Detection: Sendable {
        let identifier: String
        let language: Locale.Language
        let confidence: Double
    }

    static func detectedLanguage(in text: String) -> Detection? {
        let scrubbed = text.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: " ",
            options: .regularExpression
        )
        let sample = String(scrubbed.prefix(6_000))
        guard sample.lazy.filter(\.isLetter).prefix(20).count == 20 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominantLanguage = recognizer.dominantLanguage,
              dominantLanguage != .undetermined,
              let confidence = recognizer.languageHypotheses(withMaximum: 3)[dominantLanguage],
              confidence >= 0.75 else {
            return nil
        }
        let identifier = dominantLanguage.rawValue
        return Detection(
            identifier: identifier,
            language: Locale.Language(identifier: identifier),
            confidence: confidence
        )
    }

    static func suggestion(
        for text: String,
        currentLocaleIdentifier: String,
        supportedLocales: [Locale]
    ) -> SpeechLanguageSuggestion? {
        guard let detected = detectedLanguage(in: text) else { return nil }

        return suggestion(
            detectedLanguageIdentifier: detected.identifier,
            confidence: detected.confidence,
            currentLocaleIdentifier: currentLocaleIdentifier,
            supportedLocales: supportedLocales
        )
    }

    static func suggestion(
        detectedLanguageIdentifier: String,
        confidence: Double,
        currentLocaleIdentifier: String,
        supportedLocales: [Locale]
    ) -> SpeechLanguageSuggestion? {
        guard confidence >= 0.75,
              detectedLanguageIdentifier != NLLanguage.undetermined.rawValue else { return nil }
        let detectedLanguage = Locale.Language(identifier: detectedLanguageIdentifier)
        guard !SpeechLocaleSupport.matches(
            language: detectedLanguage,
            localeIdentifier: currentLocaleIdentifier
        ),
        let languageCode = detectedLanguage.languageCode?.identifier,
        let locale = SpeechLocaleSupport.closestSupportedLocale(
            for: detectedLanguage,
            supportedLocales: supportedLocales
        ) else {
            return nil
        }

        return SpeechLanguageSuggestion(
            detectedLanguageIdentifier: detectedLanguageIdentifier,
            languageCode: languageCode,
            localeIdentifier: locale.identifier,
            confidence: confidence
        )
    }
}

private actor SpeechLanguageSuggestionService {
    static let shared = SpeechLanguageSuggestionService()

    func suggestion(for text: String, currentLocaleIdentifier: String) async -> SpeechLanguageSuggestion? {
        let detected = await Task.detached(priority: .utility) {
            SpeechLanguageDetector.detectedLanguage(in: text)
        }.value
        guard !Task.isCancelled,
              let detected,
              !SpeechLocaleSupport.matches(
                language: detected.language,
                localeIdentifier: currentLocaleIdentifier
              ) else { return nil }

        let requestedLocale = Locale(identifier: detected.identifier)
        guard !Task.isCancelled else { return nil }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale),
              let languageCode = detected.language.languageCode?.identifier else { return nil }

        return SpeechLanguageSuggestion(
            detectedLanguageIdentifier: detected.identifier,
            languageCode: languageCode,
            localeIdentifier: locale.identifier,
            confidence: detected.confidence
        )
    }
}

@Observable
@MainActor
final class SpeechLanguageSuggestionCoordinator {
    typealias Detector = @Sendable (String, String) async -> SpeechLanguageSuggestion?

    private(set) var suggestion: SpeechLanguageSuggestion?
    @ObservationIgnored private var ignoredLanguageIdentifier: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private let detector: Detector

    init(
        debounceDuration: Duration = .seconds(2.5),
        detector: @escaping Detector = { text, localeIdentifier in
            await SpeechLanguageSuggestionService.shared.suggestion(
                for: text,
                currentLocaleIdentifier: localeIdentifier
            )
        }
    ) {
        self.debounceDuration = debounceDuration
        self.detector = detector
    }

    func schedule(text: String, currentLocaleIdentifier: String) {
        task?.cancel()
        generation += 1
        let requestedGeneration = generation
        let debounceDuration = debounceDuration
        let detector = detector
        suggestion = nil

        task = Task { [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let detected = await detector(text, currentLocaleIdentifier)
            guard !Task.isCancelled,
                  let self,
                  self.generation == requestedGeneration,
                  detected?.detectedLanguageIdentifier != self.ignoredLanguageIdentifier else { return }
            self.suggestion = detected
        }
    }

    func dismiss(_ suggestion: SpeechLanguageSuggestion) {
        ignoredLanguageIdentifier = suggestion.detectedLanguageIdentifier
        self.suggestion = nil
    }

    func reset(text: String, currentLocaleIdentifier: String) {
        ignoredLanguageIdentifier = nil
        schedule(text: text, currentLocaleIdentifier: currentLocaleIdentifier)
    }

    func useSuggestedLocale() -> String? {
        guard let suggestion else { return nil }
        ignoredLanguageIdentifier = nil
        self.suggestion = nil
        return suggestion.localeIdentifier
    }

    func cancel() {
        task?.cancel()
        task = nil
        suggestion = nil
    }
}
