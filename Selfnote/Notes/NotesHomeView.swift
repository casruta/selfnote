import Combine
import SwiftData
import SwiftUI
import UIKit

@MainActor
struct NotesHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var capture = CaptureController.shared
    @State private var store: NoteStore?
    @State private var startupError: String?
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    NotesInbox(store: store)
                        .modelContainer(store.container)
                } else if let startupError {
                    ContentUnavailableView {
                        Label("Notebook unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(startupError)
                    } actions: {
                        Button("Try again", action: openNotebook)
                    }
                } else {
                    ProgressView("Opening notebook")
                }
            }
            .navigationTitle("Notebook")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSetup = true } label: {
                        Label("Recording setup", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("recordingSetup")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { RecordingBar() }
        .onChange(of: capture.activeID) { _, id in
            if id != nil { showingSetup = false }
        }
        .task { if store == nil { openNotebook() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if store == nil {
                    openNotebook()
                } else {
                    CaptureController.shared.recoverInterruptedRecordings()
                    store?.setForeground(true)
                }
            } else {
                store?.setForeground(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selfnoteRecordingSaved).receive(on: RunLoop.main)) { _ in
            store?.synchronize()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification).receive(on: RunLoop.main)) { _ in
            if store == nil {
                openNotebook()
            } else {
                CaptureController.shared.recoverInterruptedRecordings()
                store?.synchronize()
            }
        }
        .sheet(isPresented: $showingSetup) {
            NavigationStack {
                RecorderSetupView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSetup = false }
                        }
                    }
            }
        }
        .alert("Notebook needs attention", isPresented: Binding(
            get: { store?.problem != nil },
            set: { if !$0 { store?.problem = nil } }
        )) {
            Button("OK") { store?.problem = nil }
        } message: {
            Text(store?.problem ?? "")
        }
    }

    private func openNotebook() {
        CaptureController.shared.recoverInterruptedRecordings()
        do {
            let opened = try NoteStore()
            store = opened
            startupError = nil
            opened.setForeground(scenePhase == .active)
        } catch {
            startupError = "Your audio files are stored separately from the notebook. \(error.localizedDescription)"
        }
    }
}

private struct NotesInbox: View {
    let store: NoteStore
    @Query(sort: \VoiceNote.createdAt, order: .reverse) private var notes: [VoiceNote]
    @State private var search = ""

    private var matchingNotes: [VoiceNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter {
            $0.state != .deleting && (query.isEmpty || $0.displayTitle.localizedStandardContains(query)
                || $0.body.localizedStandardContains(query))
        }
    }

    var body: some View {
        List(matchingNotes, id: \.recordingID) { note in
            NavigationLink {
                NoteDetailView(note: note, store: store)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(note.displayTitle).font(.headline).lineLimit(2)
                    Text(note.body.isEmpty ? summary(for: note) : note.body)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.vertical, 5)
            }
        }
        .listStyle(.plain)
        .overlay {
            if matchingNotes.isEmpty {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No notes yet", systemImage: "waveform",
                                           description: Text("Record a thought to add it to your notebook."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .searchable(text: $search, prompt: "Search notes")
    }

    private func summary(for note: VoiceNote) -> String {
        switch note.state {
        case .queued: "Waiting to transcribe"
        case .transcribing: store.downloadingID == note.recordingID ? "Preparing speech language" : "Transcribing"
        case .failed: "Recording saved · Transcription needs attention"
        case .ready: "Recording saved"
        case .deleting: ""
        }
    }
}
