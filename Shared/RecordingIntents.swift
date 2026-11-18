import AppIntents
import Foundation

struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Record a voice note in Selfnote. An existing recording keeps running.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SELFNOTE_WIDGET
        try requireRecorderProcess()
        #else
        do {
            try await CaptureController.shared.start(requireLiveActivity: true)
        } catch {
            throw RecordingActionError(localizedStringResource: "\(error.localizedDescription)")
        }
        #endif
        return .result()
    }
}

struct StopRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop and Save Recording"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Recording")
    var recordingID: String

    init() {}

    init(noteID: UUID) {
        self.recordingID = noteID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SELFNOTE_WIDGET
        try requireRecorderProcess()
        #else
        guard let noteID = UUID(uuidString: recordingID) else {
            throw RecordingActionError(localizedStringResource: "Open Selfnote to stop the current recording.")
        }
        do {
            // A delayed action from an older Live Activity must only stop its own recording.
            try await CaptureController.shared.stop(expectedID: noteID)
        } catch {
            throw RecordingActionError(localizedStringResource: "\(error.localizedDescription)")
        }
        #endif
        return .result()
    }
}

private struct RecordingActionError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

#if SELFNOTE_WIDGET
// WidgetKit needs the intent types in the extension. LiveActivityIntent routes execution to the app.
private func requireRecorderProcess() throws {
    throw RecordingActionError(localizedStringResource: "Open Selfnote and use its recording controls.")
}
#else
struct SelfnoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Record a note in \(.applicationName)",
                "Start recording in \(.applicationName)"
            ],
            shortTitle: "Record Note",
            systemImageName: "mic.fill"
        )
    }
}
#endif
