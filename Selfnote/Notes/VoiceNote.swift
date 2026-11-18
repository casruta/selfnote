import Foundation
import SwiftData

enum NoteState: String {
    case queued, transcribing, ready, failed, deleting
}

@Model
final class VoiceNote {
    @Attribute(.unique) var recordingID: UUID
    var createdAt: Date
    var audioFilename: String
    var localeIdentifier: String
    var title = ""
    var body = ""
    var originalTranscript = ""
    var editedTitle = false
    var editedBody = false
    var stateValue: String
    var failureMessage: String?

    init(recordingID: UUID, createdAt: Date, locale: Locale, audioFilename: String? = nil) {
        self.recordingID = recordingID
        self.createdAt = createdAt
        self.audioFilename = audioFilename ?? recordingID.uuidString + ".caf"
        localeIdentifier = locale.identifier
        stateValue = NoteState.queued.rawValue
    }

    var state: NoteState {
        get { NoteState(rawValue: stateValue) ?? .failed }
        set { stateValue = newValue.rawValue }
    }

    var displayTitle: String { title.isEmpty ? "Voice note" : title }

    func acceptTranscript(_ text: String) {
        let draft = NoteFormatter.draft(
            from: text, locale: Locale(identifier: localeIdentifier), promoteHeading: !editedTitle
        )
        originalTranscript = text
        if !editedTitle { title = draft.title }
        if !editedBody { body = draft.body }
        failureMessage = nil
        state = .ready
    }

    var exportText: String { "# \(displayTitle)\n\n\(body)\n" }
}
