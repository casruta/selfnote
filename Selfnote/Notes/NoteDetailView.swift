import AVFAudio
import Combine
import SwiftUI

@MainActor
struct NoteDetailView: View {
    let note: VoiceNote
    let store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var capture = CaptureController.shared
    @StateObject private var playback = NotePlayback()
    @State private var isEditing = false
    @State private var confirmDelete = false
    @State private var selectLanguage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.createdAt.formatted(date: .long, time: .shortened))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isEditing {
                        TextField("Title", text: Binding(
                            get: { note.title }, set: { note.title = $0; note.editedTitle = true; store.saveEdits() }
                        ), axis: .vertical)
                        .font(.largeTitle.bold()).accessibilityLabel("Note title")
                    } else {
                        Text(note.displayTitle).font(.largeTitle.bold()).textSelection(.enabled)
                    }
                }
                Button {
                    do { try playback.toggle(file: store.audioURL(for: note)) }
                    catch { store.problem = "Couldn’t play the recording. \(error.localizedDescription)" }
                } label: {
                    Label(playback.isPlaying ? "Stop playback" : "Play recording",
                          systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(capture.activeID != nil || capture.isBusy)

                transcriptionStatus
                summarySection
                if isEditing {
                    TextEditor(text: Binding(get: { note.body }, set: updateBody))
                        .font(.body).frame(minHeight: 220)
                        .accessibilityLabel("Note body in Markdown")
                } else if !note.body.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        let lines = note.body.components(separatedBy: "\n")
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            formattedLine(line, index: index)
                        }
                    }
                }
                if !note.originalTranscript.isEmpty {
                    Divider()
                    DisclosureGroup("Original transcript") {
                        Text(note.originalTranscript).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8).textSelection(.enabled)
                    }
                    if note.filesSnapshotSaved == true {
                        Label("Saved a copy to Files", systemImage: "checkmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button(note.filesSnapshotSaved == nil ? "Save a copy to Files" : "Retry Files copy") {
                            store.retryFilesSnapshot(note)
                        }
                            .font(.footnote)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                Menu {
                    ShareLink(item: note.exportText, subject: Text(note.displayTitle)) {
                        Label("Share Markdown", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete note", systemImage: "trash")
                    }
                } label: {
                    Label("Note actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this note and its recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note and recording", role: .destructive) {
                playback.stop()
                do { try store.delete(note); dismiss() }
                catch { store.problem = "Couldn’t delete the note. \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $selectLanguage) {
            NoteLanguagePicker { locale in
                store.retry(note, locale: locale)
                selectLanguage = false
            }
        }
        .onChange(of: capture.isBusy) { _, busy in
            if busy { playback.stop() }
        }
        .onChange(of: capture.activeID) { _, id in
            if id != nil {
                playback.stop()
                selectLanguage = false
                confirmDelete = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in
            playback.stop()
        }
        .onDisappear { playback.stop() }
    }

    private var summarySection: some View {
        let summary = note.summary
        return VStack(alignment: .leading, spacing: 6) {
            Text("Summary").font(.headline).accessibilityAddTraits(.isHeader)
            if isEditing {
                TextField("Summary", text: Binding(
                    get: { note.summaryOverride ?? summary },
                    set: { note.summaryOverride = $0; store.saveEdits() }
                ), axis: .vertical)
                .accessibilityLabel("Note summary")
            } else {
                Text(summary.isEmpty ? "No summary yet" : summary)
                    .font(.body).foregroundStyle(summary.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var transcriptionStatus: some View {
        switch note.state {
        case .queued:
            Label("Waiting to transcribe", systemImage: "clock").foregroundStyle(.secondary)
        case .transcribing:
            HStack {
                ProgressView()
                Text(store.downloadingID == note.recordingID ? "Preparing speech language…" : "Transcribing on this iPhone…")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(note.failureMessage ?? "Transcription is unavailable. Your recording is saved.")
                    .font(.subheadline)
                ViewThatFits(in: .horizontal) {
                    HStack { retryButtons }
                    VStack(alignment: .leading) { retryButtons }
                }
            }
        case .ready, .deleting:
            EmptyView()
        }
    }

    @ViewBuilder private var retryButtons: some View {
        Button("Retry transcription") { store.retry(note) }.buttonStyle(.bordered)
        Button("Change language") { selectLanguage = true }.buttonStyle(.bordered)
    }

    @ViewBuilder private func formattedLine(_ line: String, index: Int) -> some View {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            let done = !line.hasPrefix("- [ ] ")
            let content = String(line.dropFirst(6))
            Button { updateBody(NoteFormatter.togglingTask(at: index, in: note.body)) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(.tint)
                    Text(content).strikethrough(done)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(content)
            .accessibilityValue(done ? "Checked" : "Unchecked")
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline) { Text("•"); Text(String(line.dropFirst(2))) }
                .textSelection(.enabled)
        } else if !line.isEmpty {
            Text(line).textSelection(.enabled)
        } else {
            Spacer().frame(height: 3)
        }
    }

    private func updateBody(_ text: String) {
        note.body = text
        note.editedBody = true
        store.saveEdits()
    }
}

private struct NoteLanguagePicker: View {
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

@MainActor
private final class NotePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(file: URL) throws {
        if player != nil { stop(); return }
        let audio = try AVAudioPlayer(contentsOf: file)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        audio.delegate = self
        player = audio
        guard audio.play() else {
            stop()
            throw CocoaError(.fileReadCorruptFile)
        }
        isPlaying = true
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        isPlaying = false
        let session = AVAudioSession.sharedInstance()
        if CaptureController.shared.activeID == nil && session.category == .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            if self?.player === player { self?.stop() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            if self?.player === player { self?.stop() }
        }
    }
}
