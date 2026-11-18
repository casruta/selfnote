import AVFoundation
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
