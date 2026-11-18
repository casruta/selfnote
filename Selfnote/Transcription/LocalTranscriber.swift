import AVFAudio
import Foundation
import Speech

enum LocalTranscriber {
    enum Problem: LocalizedError {
        case unsupportedLanguage(String)
        case download(String)
        case noWords

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let name):
                return "\(name) is unavailable for on-device transcription on this iPhone. Choose another language or edit the note yourself."
            case .download(let detail):
                return "The speech language could not be installed. Check your connection and storage, then retry. \(detail)"
            case .noWords:
                return "The recording produced no recognized words. You can play it or write your own note."
            }
        }
    }

    static func availableLocales() async -> [Locale] {
        let preferred = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        let identifiers = Set((preferred + dictation).map(\.identifier))
        return identifiers.map { Locale(identifier: $0) }.sorted { name($0) < name($1) }
    }

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func transcribe(
        file: URL,
        locale: Locale,
        onDownload: @escaping @Sendable (Bool) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            let text = module.results.filter { $0.isFinal }.map { String($0.text.characters) }
            return try await analyze(file, module: module, results: text, onDownload: onDownload)
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, preset: .longDictation)
            let text = module.results.filter { $0.isFinal }.map { String($0.text.characters) }
            return try await analyze(file, module: module, results: text, onDownload: onDownload)
        }
        throw Problem.unsupportedLanguage(name(locale))
    }

    private static func analyze<Results: AsyncSequence>(
        _ file: URL,
        module: any SpeechModule,
        results: Results,
        onDownload: @escaping @Sendable (Bool) async -> Void
    ) async throws -> String where Results.Element == String {
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                await onDownload(true)
                try await installation.downloadAndInstall()
                await onDownload(false)
            }
        } catch {
            try Task.checkCancellation()
            throw Problem.download(error.localizedDescription)
        }

        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let audio = try AVAudioFile(forReading: file)
            try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
            var transcript = ""
            for try await segment in results {
                try Task.checkCancellation()
                transcript += segment
            }
            try Task.checkCancellation()
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Problem.noWords }
            return text
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
