import AVFAudio
import Foundation
import Speech

enum LocalTranscriber {
    static let languageKey = "selfnote.speechLanguage"

    static func preferredLocale(_ identifier: String?) -> Locale {
        guard let identifier, !identifier.isEmpty else { return .current }
        return Locale(identifier: identifier)
    }

    enum Problem: LocalizedError {
        case unsupportedLanguage(String)
        case reservationsFull
        case download(String)
        case noWords

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let name):
                return "\(name) is unavailable for on-device transcription on this iPhone. Choose another language or edit the note yourself."
            case .reservationsFull:
                return "Your speech language slots are full. In Recording setup, use Release a language to free one, then retry."
            case .download(let detail):
                return "The speech language could not be installed. Check your connection and storage, then retry. \(detail)"
            case .noWords:
                return "The recording produced no recognized words. You can play it or write your own note."
            }
        }
    }

    static func availableLocales() async -> [Locale] {
        let preferred = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let dictation = await DictationTranscriber.supportedLocales
        let identifiers = Set((preferred + dictation).map(\.identifier))
        return identifiers.map { Locale(identifier: $0) }.sorted { name($0) < name($1) }
    }

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private enum Engine {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let module): return module
            case .dictation(let module): return module
            }
        }
    }

    private static func select(for locale: Locale) async throws -> (engine: Engine, status: AssetInventory.Status) {
        var candidates: [Engine] = []
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            candidates.append(.speech(SpeechTranscriber(locale: supported, preset: .transcription)))
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            candidates.append(.dictation(DictationTranscriber(locale: supported, preset: .longDictation)))
        }
        // Use an installed model for this locale before attempting a network download.
        var downloadable: (Engine, AssetInventory.Status)?
        for engine in candidates {
            let status = await AssetInventory.status(forModules: [engine.module])
            if status == .installed { return (engine, status) }
            if downloadable == nil && (status == .supported || status == .downloading) {
                downloadable = (engine, status)
            }
        }
        guard let downloadable else { throw Problem.unsupportedLanguage(name(locale)) }
        return downloadable
    }

    static func assetStatus(for locale: Locale) async -> AssetInventory.Status {
        guard let selected = try? await select(for: locale) else { return .unsupported }
        return selected.status
    }

    static func prepare(for locale: Locale) async throws {
        let selected = try await select(for: locale)
        try await installAssets(for: selected.engine.module) { _ in }
    }

    static func transcribe(
        file: URL,
        locale: Locale,
        onDownload: @escaping @Sendable (Bool) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        let selected = try await select(for: locale)
        try await installAssets(for: selected.engine.module, onDownload: onDownload)
        switch selected.engine {
        case .speech(let module):
            let text = module.results.filter { $0.isFinal }.map { String($0.text.characters) }
            return try await analyze(file, module: module, results: text)
        case .dictation(let module):
            let text = module.results.filter { $0.isFinal }.map { String($0.text.characters) }
            return try await analyze(file, module: module, results: text)
        }
    }

    private static func installAssets(
        for module: any SpeechModule,
        onDownload: @escaping @Sendable (Bool) async -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                await onDownload(true)
                try await installation.downloadAndInstall()
                await onDownload(false)
            }
        } catch {
            try Task.checkCancellation()
            let failure = error as NSError
            if failure.domain == SFSpeechError.errorDomain,
               failure.code == SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue {
                throw Problem.reservationsFull
            }
            throw Problem.download(error.localizedDescription)
        }
    }

    private static func analyze<Results: AsyncSequence>(
        _ file: URL, module: any SpeechModule, results: Results
    ) async throws -> String where Results.Element == String {
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
