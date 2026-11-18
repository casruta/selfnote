import SwiftData
import XCTest
@testable import Selfnote

@MainActor
final class NoteTests: XCTestCase {
    private let english = Locale(identifier: "en-US")

    func testFormatsExplicitCuesAndPreservesMeaning() {
        let input = "Balcony garden. The basil needs shade. To do, buy two clay pots. I might plant mint later."
        let draft = NoteFormatter.draft(from: input, locale: english)
        XCTAssertEqual(draft.title, "Balcony garden")
        XCTAssertEqual(draft.body, "The basil needs shade.\n\n- [ ] buy two clay pots.\n\nI might plant mint later.")

        let uncertain = "Project update. Don’t send Maya the $50.25 estimate. To do this properly, I might need another week."
        let faithful = NoteFormatter.draft(from: uncertain, locale: english)
        XCTAssertEqual(faithful.body, "Don’t send Maya the $50.25 estimate. To do this properly, I might need another week.")
    }

    func testCheckboxEditsOnlyTheChosenLineAndPreservesWhitespace() {
        let body = "- [ ] Same task\n\n- [ ] Same task\n"
        let checked = NoteFormatter.togglingTask(at: 2, in: body)
        XCTAssertEqual(checked, "- [ ] Same task\n\n- [x] Same task\n")
        XCTAssertEqual(NoteFormatter.togglingTask(at: 2, in: checked), body)
        XCTAssertEqual(NoteFormatter.togglingTask(at: 1, in: body), body)
    }

    func testTranscriptionKeepsUserEdits() {
        let note = VoiceNote(recordingID: UUID(), createdAt: .now, locale: english)
        note.title = "My heading"
        note.editedTitle = true
        note.acceptTranscript("Planning. Keep the original.")
        XCTAssertEqual(note.title, "My heading")
        XCTAssertEqual(note.body, "Keep the original.")
        note.body = "I changed my mind."
        note.editedBody = true
        note.acceptTranscript("Planning. A second result.")
        XCTAssertEqual(note.body, "I changed my mind.")
        XCTAssertEqual(note.originalTranscript, "Planning. A second result.")
        XCTAssertEqual(note.exportText, "# My heading\n\nI changed my mind.\n")
    }

    func testScansOnceAndRecoversPendingDeletion() throws {
        let (folder, container) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let audio = folder.appendingPathComponent(id.uuidString + ".caf")
        try Data([1]).write(to: audio)
        try Data([2]).write(to: folder.appendingPathComponent(UUID().uuidString + ".partial.caf"))
        let store = NoteStore(container: container, directory: { folder }) { _, _, _ in "Unused" }
        store.synchronize()
        store.synchronize()
        let notes = try container.mainContext.fetch(FetchDescriptor<VoiceNote>())
        XCTAssertEqual(notes.map(\.recordingID), [id])

        let note = try XCTUnwrap(notes.first)
        note.state = .deleting
        try container.mainContext.save()
        store.synchronize()
        store.synchronize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VoiceNote>()), 0)
    }

    func testInterruptedJobResumesAndFailedJobWaitsForExplicitRetry() async throws {
        let (folder, container) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let audio = folder.appendingPathComponent(id.uuidString + ".caf")
        try Data([1]).write(to: audio)
        let note = VoiceNote(recordingID: id, createdAt: .now, locale: english)
        note.state = .transcribing
        container.mainContext.insert(note)
        try container.mainContext.save()

        let counter = SpeechAttempt()
        let store = NoteStore(container: container, directory: { folder }) { _, _, _ in
            try await counter.run()
        }
        store.setForeground(true)
        try await waitUntil { note.state == .failed }
        store.synchronize()
        store.synchronize()
        XCTAssertEqual(note.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        store.retry(note)
        try await waitUntil { note.state == .ready }
        let count = await counter.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(note.originalTranscript, "A recovered thought.")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VoiceNote>()), 1)
    }

    func testDeletingDuringTranscriptionDiscardsLateResult() async throws {
        let (folder, container) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent(UUID().uuidString + ".caf")
        try Data([1]).write(to: audio)
        let gate = DeferredTranscript()
        let store = NoteStore(container: container, directory: { folder }) { _, _, _ in await gate.wait() }
        store.setForeground(true)
        try await waitUntil { gate.continuation != nil }
        let note = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<VoiceNote>()).first)
        try store.delete(note)
        gate.continuation?.resume(returning: "Late transcription.")
        gate.continuation = nil
        await Task.yield()
        store.synchronize()
        XCTAssertNil(store.workingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VoiceNote>()), 0)
    }

    private func makeStorage() throws -> (URL, ModelContainer) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return (folder, try ModelContainer(for: VoiceNote.self, configurations: configuration))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            guard clock.now < deadline else { throw WaitError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitError: Error { case timeout }
}

private actor SpeechAttempt {
    private(set) var count = 0
    func run() throws -> String {
        count += 1
        if count == 1 { throw CocoaError(.fileReadUnknown) }
        return "A recovered thought."
    }
}

@MainActor
private final class DeferredTranscript {
    var continuation: CheckedContinuation<String, Never>?
    func wait() async -> String {
        await withCheckedContinuation { continuation = $0 }
    }
}
