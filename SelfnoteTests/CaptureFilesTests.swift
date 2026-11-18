import AVFoundation
import SwiftData
import XCTest
@testable import Selfnote

final class CaptureFilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testFinalizePublishesTheOriginalFileUnderItsStableID() throws {
        let id = UUID()
        let partial = CaptureFiles.partialURL(for: id, in: directory)
        try writeAudio(at: partial)
        let original = try Data(contentsOf: partial)

        let saved = try CaptureFiles.finalize(partial)

        XCTAssertEqual(saved.lastPathComponent, id.uuidString + ".caf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: saved), original)
        XCTAssertEqual(try AVAudioFile(forReading: saved).length, 4)
    }

    func testRecoverySkipsTheLiveRecorderAndRetainsAnUnreadablePartial() throws {
        let activeID = UUID()
        let active = CaptureFiles.partialURL(for: activeID, in: directory)
        let interruptedID = UUID()
        let interrupted = CaptureFiles.partialURL(for: interruptedID, in: directory)
        let unreadableID = UUID()
        let unreadable = CaptureFiles.partialURL(for: unreadableID, in: directory)
        try writeAudio(at: active)
        try writeAudio(at: interrupted)
        try Data([1, 2, 3]).write(to: unreadable)

        let first = try CaptureFiles.recover(in: directory, excluding: activeID)
        let second = try CaptureFiles.recover(in: directory, excluding: activeID)

        XCTAssertEqual(first.saved.map(\.lastPathComponent), [interruptedID.uuidString + ".caf"])
        XCTAssertEqual(first.unreadable, 1)
        XCTAssertTrue(second.saved.isEmpty)
        XCTAssertEqual(second.unreadable, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(unreadableID.uuidString + ".unrecovered.caf")),
                       Data([1, 2, 3]))
    }

    func testHeaderOnlyInterruptedCAFIsRetainedWithoutRetryingOnEveryReopen() throws {
        let id = UUID()
        let partial = CaptureFiles.partialURL(for: id, in: directory)
        // Valid CAF file header, but no audio description or audio data chunks.
        let header = Data([0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0])
        try header.write(to: partial)

        let first = try CaptureFiles.recover(in: directory, excluding: nil)
        let reopened = try CaptureFiles.recover(in: directory, excluding: nil)

        XCTAssertTrue(first.saved.isEmpty)
        XCTAssertEqual(first.unreadable, 1)
        XCTAssertTrue(reopened.saved.isEmpty)
        XCTAssertEqual(reopened.unreadable, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".caf").path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".unrecovered.caf")), header)
    }

    func testRetryNeverReplacesARecordingAlreadyPublishedUnderTheSameID() throws {
        let id = UUID()
        let partial = CaptureFiles.partialURL(for: id, in: directory)
        try writeAudio(at: partial)
        let existing = try CaptureFiles.finalize(partial)
        let original = try Data(contentsOf: existing)
        try writeAudio(at: partial, sampleStep: 0.1)

        XCTAssertThrowsError(try CaptureFiles.finalize(partial))
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testEmptyRecordingNeverAppearsAsACompletedVoiceNote() throws {
        let id = UUID()
        let partial = CaptureFiles.partialURL(for: id, in: directory)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let empty = try AVAudioFile(forWriting: partial, settings: format.settings)
            XCTAssertEqual(empty.length, 0)
        }

        XCTAssertThrowsError(try CaptureFiles.finalize(partial))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try CaptureFiles.recover(in: directory, excluding: nil).unreadable, 0)
    }

    private func writeAudio(at url: URL, sampleStep: Float = 0.125) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4 { samples[index] = Float(index + 1) * sampleStep }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

final class CaptureRouteTests: XCTestCase {
    func testRemovingTheRecordingInputOrLosingTheRouteStopsCapture() {
        XCTAssertTrue(CaptureController.lostInput(reason: .oldDeviceUnavailable, previous: ["headset"], current: ["phone"]))
        XCTAssertTrue(CaptureController.lostInput(reason: .oldDeviceUnavailable, previous: ["headset"], current: []))
        XCTAssertTrue(CaptureController.lostInput(reason: .noSuitableRouteForCategory, previous: [], current: []))
    }

    func testOutputAndCategoryChangesLeaveAnActiveMicrophoneAlone() {
        XCTAssertFalse(CaptureController.lostInput(reason: .oldDeviceUnavailable, previous: ["phone"], current: ["phone"]))
        XCTAssertFalse(CaptureController.lostInput(reason: .categoryChange, previous: ["phone"], current: []))
        XCTAssertFalse(CaptureController.lostInput(reason: .newDeviceAvailable, previous: ["phone"], current: ["headset"]))
    }
}

final class RecordingLevelHistoryTests: XCTestCase {
    @MainActor
    func testIdleRecorderDoesNotExposeLevelsOrAcceptAnUnrelatedLease() {
        let recorder = CaptureController.shared
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(recorder.beginMetering(recordingID: UUID()))
        XCTAssertNil(recorder.inputLevel(lease: UUID()))
        recorder.endMetering(lease: UUID())
        XCTAssertEqual(recorder.phase, .idle)
    }

    func testSilenceAndInvalidReadingsNeverCreateFakeActivity() {
        for power in [Float(-160), -60, -.infinity, .infinity, .nan] {
            XCTAssertEqual(RecordingLevelHistory.normalized(power), 0)
        }
    }

    func testRealInputLevelsAreMonotonicAndClamped() {
        let quiet = RecordingLevelHistory.normalized(-40)
        let speech = RecordingLevelHistory.normalized(-20)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(speech, quiet)
        XCTAssertLessThan(speech, 1)
        XCTAssertEqual(RecordingLevelHistory.normalized(0), 1)
        XCTAssertEqual(RecordingLevelHistory.normalized(12), 1)
    }

    func testHistoryRetainsOnlyRecentSamplesAndNewSessionStartsEmpty() {
        var history = RecordingLevelHistory()
        history.append(decibels: 0)
        for _ in 0..<RecordingLevelHistory.capacity { history.append(decibels: -60) }
        XCTAssertEqual(history.values.count, RecordingLevelHistory.capacity)
        XCTAssertTrue(history.values.allSatisfy { $0 == 0 })
        history.append(decibels: -20)
        XCTAssertEqual(history.values.last, RecordingLevelHistory.normalized(-20))
        history = RecordingLevelHistory()
        XCTAssertTrue(history.values.isEmpty)
    }
}

@MainActor
final class NoteFilesSnapshotTests: XCTestCase {
    func testTranscriptionAutomaticallyPublishesOneSnapshot() async throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = temp.appendingPathComponent("Audio", isDirectory: true)
        let files = temp.appendingPathComponent("Notes", isDirectory: true)
        try manager.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temp) }
        let container = try ModelContainer(for: VoiceNote.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let note = VoiceNote(recordingID: UUID(), createdAt: .now, locale: Locale(identifier: "en-US"))
        try Data([1]).write(to: audio.appendingPathComponent(note.audioFilename))
        container.mainContext.insert(note)
        try container.mainContext.save()
        let store = NoteStore(container: container, directory: { audio }, snapshotsDirectory: { files }) {
            _, _, _ in "Shopping list. Pick up pears."
        }
        store.setForeground(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while note.filesSnapshotSaved != true && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(note.filesSnapshotSaved, true)
        XCTAssertEqual(note.state, .ready)
        let destination = NoteFilesSnapshot.url(for: note, in: files)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: files.path), [destination.lastPathComponent])
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8)
            .contains("## Original transcript\n\nShopping list. Pick up pears."))
    }

    func testSnapshotRetriesWithoutClobberingAndDoesNotRecreateAfterDeletion() throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = temp.appendingPathComponent("Audio", isDirectory: true)
        let files = temp.appendingPathComponent("Notes", isDirectory: true)
        try manager.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temp) }
        let container = try ModelContainer(for: VoiceNote.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = NoteStore(container: container, directory: { audio }, snapshotsDirectory: { files }) {
            _, _, _ in "Unused"
        }
        let note = VoiceNote(recordingID: UUID(), createdAt: .now, locale: Locale(identifier: "en-US"))
        note.acceptTranscript("Café plans. Bring a notebook.")
        note.body = "My edit."
        note.summaryOverride = "A short summary."
        container.mainContext.insert(note)
        try container.mainContext.save()
        try manager.createDirectory(at: files, withIntermediateDirectories: true)
        let destination = NoteFilesSnapshot.url(for: note, in: files)
        try Data("External edit".utf8).write(to: destination)
        store.retryFilesSnapshot(note)
        XCTAssertNotNil(store.problem)
        XCTAssertNotEqual(note.filesSnapshotSaved, true)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "External edit")
        XCTAssertEqual(note.originalTranscript, "Café plans. Bring a notebook.")

        try manager.removeItem(at: destination)
        // A successful file write followed by app termination can precede the completion marker.
        try NoteFilesSnapshot.write(note, to: files)
        store.synchronize()
        store.synchronize()
        XCTAssertEqual(note.filesSnapshotSaved, true)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: files.path), [destination.lastPathComponent])
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("## Summary\n\nA short summary."))
        XCTAssertTrue(text.contains("## Notes\n\nMy edit."))
        XCTAssertTrue(text.contains("## Original transcript\n\nCafé plans. Bring a notebook."))

        try manager.removeItem(at: destination)
        store.synchronize()
        XCTAssertFalse(manager.fileExists(atPath: destination.path))

        // Relaunch cleanup invalidates deleted SwiftData objects before snapshot retries.
        note.filesSnapshotSaved = false
        note.state = .deleting
        try container.mainContext.save()
        store.synchronize()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VoiceNote>()), 0)
        XCTAssertFalse(manager.fileExists(atPath: destination.path))
    }

    func testNotebookDatabaseAndAudioAreOutsideExposedDocuments() throws {
        let documents = try NoteFilesSnapshot.directory().deletingLastPathComponent().standardizedFileURL.path + "/"
        let store = ModelConfiguration(cloudKitDatabase: .none).url.standardizedFileURL.path
        let audio = try CaptureFiles.directory().standardizedFileURL.path
        XCTAssertFalse(store.hasPrefix(documents))
        XCTAssertFalse(audio.hasPrefix(documents))
    }
}
