import AVFoundation
import Foundation

extension Notification.Name {
    /// Posted on the main actor with the URL of a newly finalized, playable recording.
    static let selfnoteRecordingSaved = Notification.Name("selfnote.recordingSaved")
}

enum CaptureFiles {
    static func directory() throws -> URL {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let recordings = support.appendingPathComponent("Recordings", isDirectory: true)
        try manager.createDirectory(at: recordings, withIntermediateDirectories: true)
        return recordings
    }

    static func partialURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString + ".partial.caf")
    }

    /// A finalized UUID.caf is visible to the notebook only after we have closed and checked it.
    static func finalize(_ partial: URL) throws -> URL {
        guard let id = partialID(for: partial) else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = partial.deletingLastPathComponent()
        do {
            try verifyAudio(at: partial)
        } catch CaptureError.noAudio {
            // Only an empty file has nothing to retain. Preserve all other bytes outside the retry queue.
            if try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0 {
                try FileManager.default.removeItem(at: partial)
            } else {
                let retained = directory.appendingPathComponent(id.uuidString + ".unrecovered.caf")
                try FileManager.default.moveItem(at: partial, to: retained)
            }
            throw CaptureError.noAudio
        }
        let destination = directory.appendingPathComponent(id.uuidString + ".caf")
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    static func recover(in directory: URL, excluding currentID: UUID?) throws -> (saved: [URL], unreadable: Int) {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        var saved: [URL] = []
        var unreadable = 0
        for item in items {
            guard let id = partialID(for: item), id != currentID else { continue }
            do {
                saved.append(try finalize(item))
            } catch {
                // Transient read or move errors leave the partial in place for the next unlock or launch.
                unreadable += 1
            }
        }
        return (saved, unreadable)
    }

    private static func partialID(for url: URL) -> UUID? {
        let suffix = ".partial.caf"
        let name = url.lastPathComponent
        guard name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropLast(suffix.count)))
    }

    private static func verifyAudio(at url: URL) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // A refused open can mean file protection. Check the CAF signature only if the bytes are readable.
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            // A CAF header alone cannot contain audio. Quarantine it rather than retrying forever.
            guard let header = try source.read(upToCount: 9), header.count == 9,
                  header.starts(with: Data("caff".utf8)) else { throw CaptureError.noAudio }
            throw error
        }
        guard file.length != 0 else { throw CaptureError.noAudio }
        guard file.length > 0, let sample = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: sample, frameCount: 1)
        guard sample.frameLength == 1 else { throw CocoaError(.fileReadCorruptFile) }
        if file.length > 1 {
            file.framePosition = file.length - 1
            try file.read(into: sample, frameCount: 1)
            guard sample.frameLength == 1 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}

enum CaptureError: LocalizedError {
    case busy, microphonePermission, liveActivityRequired, alreadyRecordingInApp, startFailed, noAudio, pendingSave

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Selfnote is changing recording state. Try again in a moment."
        case .microphonePermission:
            return "Allow Selfnote to use the microphone in Settings to start a voice note."
        case .liveActivityRequired:
            return "This recording shortcut needs Live Activities. Enable them for Selfnote in Settings or tap Record in the app."
        case .alreadyRecordingInApp:
            return "Selfnote is already recording. Open Selfnote to stop and save the current note."
        case .startFailed:
            return "The microphone could not start. Check the audio input and try again."
        case .noAudio:
            return "The recording has no readable audio."
        case .pendingSave:
            return "Recording stopped. Selfnote kept the unfinished file. Unlock and reopen the app to try saving it again."
        }
    }
}
