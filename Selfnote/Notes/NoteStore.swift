import Darwin
import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
@Observable
final class NoteStore {
    typealias Transcribe = (
        URL, Locale, @escaping @Sendable (Bool) async -> Void
    ) async throws -> String

    let container: ModelContainer
    private let directory: () throws -> URL
    private let snapshotsDirectory: (() throws -> URL)?
    private let transcribe: Transcribe
    private var isForeground = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    private(set) var workingID: UUID?
    private(set) var downloadingID: UUID?
    var problem: String?

    private var context: ModelContext { container.mainContext }

    convenience init() throws {
        let configuration = ModelConfiguration(cloudKitDatabase: .none)
        let container = try ModelContainer(for: VoiceNote.self, configurations: configuration)
        self.init(container: container, directory: CaptureFiles.directory,
                  snapshotsDirectory: NoteFilesSnapshot.directory, transcribe: LocalTranscriber.transcribe)
    }

    init(container: ModelContainer, directory: @escaping () throws -> URL,
         snapshotsDirectory: (() throws -> URL)? = nil, transcribe: @escaping Transcribe) {
        self.container = container
        self.directory = directory
        self.snapshotsDirectory = snapshotsDirectory
        self.transcribe = transcribe
        container.mainContext.autosaveEnabled = false
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground { synchronize() }
    }

    func audioURL(for note: VoiceNote) throws -> URL {
        try directory().appendingPathComponent(note.audioFilename)
    }

    func synchronize() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        do {
            let notes = try context.fetch(FetchDescriptor<VoiceNote>())
            let pendingSnapshots = notes.filter { $0.state == .ready && $0.filesSnapshotSaved == false }
            var known = Set(notes.map(\.recordingID))
            for note in notes {
                if note.state == .deleting {
                    do { try finishDeletion(note) }
                    catch { problem = "Couldn’t finish deleting the recording. \(error.localizedDescription)" }
                } else if note.state == .transcribing && workingID != note.recordingID {
                    // The previous process ended with an already-finalized recording.
                    note.state = .queued
                }
            }
            let files = try FileManager.default.contentsOfDirectory(
                at: directory(),
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension.lowercased() == "caf" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      known.insert(id).inserted else { continue }
                let values = try file.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                context.insert(VoiceNote(
                    recordingID: id, createdAt: values.creationDate ?? .now,
                    locale: .current, audioFilename: file.lastPathComponent
                ))
            }
            if context.hasChanges { try context.save() }
            for note in pendingSnapshots {
                try? saveFilesSnapshot(note)
            }
        } catch {
            problem = "Couldn’t load the recordings. \(error.localizedDescription)"
            return
        }
        startNext()
    }

    func saveEdits() {
        do { try context.save() }
        catch { problem = "Couldn’t save your changes. \(error.localizedDescription)" }
    }

    func retryFilesSnapshot(_ note: VoiceNote) {
        guard shouldSaveSnapshot(note) else { return }
        let previous = note.filesSnapshotSaved
        do {
            // The notebook remains authoritative even if writing the Files copy fails.
            note.filesSnapshotSaved = false
            do { try context.save() }
            catch {
                note.filesSnapshotSaved = previous
                throw error
            }
            try saveFilesSnapshot(note)
        } catch {
            problem = "Couldn’t save a copy to Files. Your note is still in Selfnote. \(error.localizedDescription)"
        }
    }

    private func shouldSaveSnapshot(_ note: VoiceNote) -> Bool {
        snapshotsDirectory != nil && note.state == .ready && !note.originalTranscript.isEmpty
            && note.filesSnapshotSaved != true
    }

    private func saveFilesSnapshot(_ note: VoiceNote) throws {
        guard shouldSaveSnapshot(note), let snapshotsDirectory else { return }
        let directory = try snapshotsDirectory()
        try NoteFilesSnapshot.write(note, to: directory)
        let previous = note.filesSnapshotSaved
        note.filesSnapshotSaved = true
        do { try context.save() }
        catch {
            note.filesSnapshotSaved = previous
            throw error
        }
    }

    func retry(_ note: VoiceNote, locale: Locale? = nil) {
        guard note.state == .failed else { return }
        let previousLocale = note.localeIdentifier
        let previousMessage = note.failureMessage
        if let locale { note.localeIdentifier = locale.identifier }
        note.failureMessage = nil
        note.state = .queued
        do {
            try context.save()
            startNext()
        } catch {
            note.localeIdentifier = previousLocale
            note.failureMessage = previousMessage
            note.state = .failed
            problem = "Couldn’t queue the recording. \(error.localizedDescription)"
        }
    }

    func delete(_ note: VoiceNote) throws {
        let previous = note.state
        note.state = .deleting
        do { try context.save() }
        catch {
            note.state = previous
            throw error
        }
        if workingID == note.recordingID {
            worker?.cancel()
            worker = nil
            workingID = nil
            downloadingID = nil
        }
        defer { startNext() }
        try finishDeletion(note)
    }

    private func finishDeletion(_ note: VoiceNote) throws {
        // Persisting .deleting first lets the next launch complete either half
        // of the file/database operation without importing the audio again.
        let url = try audioURL(for: note)
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        context.delete(note)
        try context.save()
    }

    private func startNext() {
        guard isForeground, worker == nil, UIApplication.shared.isProtectedDataAvailable else { return }
        let queued = NoteState.queued.rawValue
        var request = FetchDescriptor<VoiceNote>(
            predicate: #Predicate { $0.stateValue == queued },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        request.fetchLimit = 1
        do {
            guard let note = try context.fetch(request).first else { return }
            let url = try audioURL(for: note)
            note.state = .transcribing
            do { try context.save() }
            catch {
                note.state = .queued
                throw error
            }
            let id = note.recordingID
            let locale = Locale(identifier: note.localeIdentifier)
            workingID = id
            worker = Task {
                do {
                    let text = try await transcribe(url, locale) { [weak self] downloading in
                        await self?.markDownloading(id, downloading: downloading)
                    }
                    guard !Task.isCancelled, workingID == id else { return }
                    note.acceptTranscript(text)
                    if shouldSaveSnapshot(note) { note.filesSnapshotSaved = false }
                } catch {
                    guard !Task.isCancelled, workingID == id else { return }
                    if UIApplication.shared.isProtectedDataAvailable {
                        note.state = .failed
                        note.failureMessage = error.localizedDescription
                    } else {
                        note.state = .queued
                    }
                }
                workingID = nil
                downloadingID = nil
                worker = nil
                do {
                    try context.save()
                    try? saveFilesSnapshot(note)
                    startNext()
                }
                catch { problem = "Couldn’t save transcription progress. \(error.localizedDescription)" }
            }
        } catch {
            problem = "Couldn’t start transcription. \(error.localizedDescription)"
        }
    }

    private func markDownloading(_ id: UUID, downloading: Bool) {
        if workingID == id { downloadingID = downloading ? id : nil }
    }
}

@MainActor
enum NoteFilesSnapshot {
    static func directory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    static func url(for note: VoiceNote, in directory: URL) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let day = formatter.string(from: note.createdAt)
        return directory.appendingPathComponent("\(day)-\(note.recordingID.uuidString).md")
    }

    static func markdown(for note: VoiceNote) -> String {
        "# \(note.displayTitle)\n\n## Summary\n\n\(note.summary)\n\n## Notes\n\n\(note.body)\n\n## Original transcript\n\n\(note.originalTranscript)\n"
    }

    static func write(_ note: VoiceNote, to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: note, in: directory)
        let data = Data(markdown(for: note).utf8)
        let temporary = manager.temporaryDirectory.appendingPathComponent("selfnote-snapshot-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])

        // A same-volume hard link publishes finished bytes atomically and fails if the name is taken.
        // An identical file can be left by a crash between the write and the SwiftData save.
        let code = try temporary.withUnsafeFileSystemRepresentation { source in
            try destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { throw CocoaError(.fileWriteInvalidFileName) }
                return Darwin.link(source, target) == 0 ? 0 : errno
            }
        }
        if code == EEXIST, (try? Data(contentsOf: destination)) == data { return }
        if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }
}
