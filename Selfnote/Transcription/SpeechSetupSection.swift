import Speech
import SwiftUI

@MainActor
struct SpeechSetupSection: View {
    @AppStorage(LocalTranscriber.languageKey) private var languageID = ""
    @State private var choosingLanguage = false
    @State private var choosingRelease = false
    @State private var status: AssetInventory.Status?
    @State private var reservations: [Locale] = []
    @State private var operation: String?
    @State private var errorMessage: String?

    private var locale: Locale { LocalTranscriber.preferredLocale(languageID) }

    var body: some View {
        Section("Offline dictation") {
            Button { choosingLanguage = true } label: {
                LabeledContent("Default language", value: LocalTranscriber.name(locale))
            }
            .accessibilityIdentifier("speechLanguage")
            .disabled(operation != nil)
            if let operation {
                ProgressView(operation)
            } else if let status {
                switch status {
                case .installed:
                    Label("Ready to transcribe offline", systemImage: "checkmark.circle")
                case .supported:
                    Text("Download this language while connected to transcribe new recordings offline.")
                case .downloading:
                    Text("The language download is pending.")
                case .unsupported:
                    Text("Choose a supported language for this iPhone.")
                @unknown default:
                    Text("Check offline language availability.")
                }
            } else {
                ProgressView("Checking speech language")
            }
            if let errorMessage { Text(errorMessage) }
            Button("Prepare for offline use") { Task { await prepare() } }
                .disabled(operation != nil || status == nil || status == .installed || status == .unsupported)
                .accessibilityIdentifier("prepareSpeechLanguage")
            if !reservations.isEmpty {
                Button("Release a language") { choosingRelease = true }
                    .disabled(operation != nil)
            }
        }
        .sheet(isPresented: $choosingLanguage) {
            NoteLanguagePicker { selection in
                languageID = selection.identifier
                choosingLanguage = false
            }
        }
        .confirmationDialog("Release an offline language?", isPresented: $choosingRelease, titleVisibility: .visible) {
            ForEach(reservations, id: \.identifier) { item in
                Button(LocalTranscriber.name(item)) { Task { await release(item) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees a language slot. Future recordings in that language may need another download.")
        }
        .task(id: languageID) {
            errorMessage = nil
            status = nil
            await refresh()
        }
    }

    private func refresh() async {
        let selection = locale
        let currentStatus = await LocalTranscriber.assetStatus(for: selection)
        let languages = await AssetInventory.reservedLocales
        guard !Task.isCancelled, selection == locale else { return }
        status = currentStatus
        reservations = languages.sorted { LocalTranscriber.name($0) < LocalTranscriber.name($1) }
    }

    private func prepare() async {
        guard operation == nil else { return }
        operation = "Preparing offline language"
        errorMessage = nil
        defer { operation = nil }
        do { try await LocalTranscriber.prepare(for: locale) }
        catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    private func release(_ selection: Locale) async {
        guard operation == nil else { return }
        operation = "Releasing language"
        errorMessage = nil
        defer { operation = nil }
        if !(await AssetInventory.release(reservedLocale: selection)) {
            errorMessage = "The language reservation could not be released. Try again."
        }
        await refresh()
    }
}

struct NoteLanguagePicker: View {
    let choose: (Locale) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locales: [Locale] = []
    @State private var loading = true
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(locales.filter { search.isEmpty || LocalTranscriber.name($0).localizedStandardContains(search) },
                 id: \.identifier) { locale in
                Button(LocalTranscriber.name(locale)) { choose(locale) }
            }
            .overlay {
                if loading { ProgressView() }
                else if locales.isEmpty { ContentUnavailableView("No on-device languages available", systemImage: "waveform.slash") }
            }
            .navigationTitle("Speech language")
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                locales = await LocalTranscriber.availableLocales()
                loading = false
            }
        }
    }
}
