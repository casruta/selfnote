import ActivityKit
import AVFoundation
import Combine
import UIKit

@MainActor
final class CaptureController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = CaptureController()

    enum Phase: String {
        case idle, preparing, recording, saving
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeID: UUID?
    @Published private(set) var startedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var lastStatus: String?

    private var meterLease: UUID?
    private var pendingStart: UUID?
    private var recorder: AVAudioRecorder?
    private var activity: Activity<RecordingAttributes>?
    private var activityObserver: Task<Void, Never>?
    private var sessionObservers: [NSObjectProtocol] = []

    private override init() { super.init() }

    func start(requireLiveActivity: Bool) async throws {
        if activeID != nil {
            if requireLiveActivity && activity?.activityState != .active && activity?.activityState != .stale {
                throw CaptureError.alreadyRecordingInApp
            }
            return
        }
        guard !isBusy else { throw CaptureError.busy }

        let id = UUID()
        pendingStart = id
        isBusy = true
        phase = .preparing
        lastStatus = nil
        defer {
            pendingStart = nil
            isBusy = false
            if activeID == nil { phase = .idle }
        }

        let session = AVAudioSession.sharedInstance()
        var activatedSession = false
        var newFile: URL?
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw CaptureError.microphonePermission }
            try Task.checkCancellation()
            guard pendingStart == id else { throw CancellationError() }
            if requireLiveActivity && !ActivityAuthorizationInfo().areActivitiesEnabled {
                throw CaptureError.liveActivityRequired
            }

            let url = CaptureFiles.partialURL(for: id, in: try CaptureFiles.directory())
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.prepare()
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            activatedSession = true

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            newFile = url
            let prepared = try AVAudioRecorder(url: url, settings: settings)
            recorder = prepared
            prepared.delegate = self
            guard prepared.prepareToRecord() else { throw CaptureError.startFailed }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                                  ofItemAtPath: url.path)

            let date = Date()
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                let attributes = RecordingAttributes(noteID: id, startedAt: date)
                activity = try? Activity.request(attributes: attributes, content: ActivityContent(
                    state: RecordingAttributes.ContentState(), staleDate: nil
                ))
            }
            if requireLiveActivity && activity == nil { throw CaptureError.liveActivityRequired }
            guard prepared.record() else { throw CaptureError.startFailed }

            activeID = id
            phase = .recording
            startedAt = date
            observeSession(id: id)
            feedback.impactOccurred()
        } catch {
            recorder?.delegate = nil
            recorder?.stop()
            recorder = nil
            if activatedSession { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            if let newFile { try? FileManager.default.removeItem(at: newFile) }
            let failedActivity = activity
            activity = nil
            lastStatus = error is CancellationError ? "Recording cancelled." : error.localizedDescription
            await failedActivity?.end(nil, dismissalPolicy: .immediate)
            throw error
        }
    }

    func stop(expectedID: UUID? = nil) async throws {
        guard let id = activeID else {
            if expectedID == nil || expectedID == pendingStart { pendingStart = nil }
            return
        }
        guard expectedID == nil || expectedID == id else { return }
        try await finish(id: id, savedMessage: "Recording saved.")
    }

    private func finish(id: UUID, savedMessage: String) async throws {
        guard activeID == id, let recorder else { return }
        isBusy = true
        phase = .saving
        defer { isBusy = false; phase = .idle }
        meterLease = nil
        recorder.isMeteringEnabled = false
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
        activityObserver?.cancel()
        activityObserver = nil

        let url = recorder.url
        recorder.delegate = nil
        recorder.stop() // Closes the file even when an interruption already stopped input.
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let finishedActivity = activity
        activity = nil
        activeID = nil
        startedAt = nil

        var saveError: Error?
        do {
            let saved = try CaptureFiles.finalize(url)
            lastStatus = savedMessage
            NotificationCenter.default.post(name: .selfnoteRecordingSaved, object: saved)
        } catch CaptureError.noAudio {
            lastStatus = CaptureError.noAudio.localizedDescription
            saveError = CaptureError.noAudio
        } catch {
            lastStatus = CaptureError.pendingSave.localizedDescription
            saveError = CaptureError.pendingSave
        }
        await finishedActivity?.end(nil, dismissalPolicy: .immediate)
        if let saveError { throw saveError }
    }

    /// The visible recorder owns this lease; an old view task cannot disable a newer session's meter.
    func beginMetering(recordingID: UUID) -> UUID? {
        guard activeID == recordingID, phase == .recording, let recorder else { return nil }
        let lease = UUID()
        meterLease = lease
        recorder.isMeteringEnabled = true
        return lease
    }

    func inputLevel(lease: UUID) -> Float? {
        guard meterLease == lease, phase == .recording, let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    func endMetering(lease: UUID) {
        guard meterLease == lease else { return }
        recorder?.isMeteringEnabled = false
        meterLease = nil
    }

    func recoverInterruptedRecordings() {
        // Live Activities can outlive a killed app process. Never close the current recorder's activity.
        for other in Activity<RecordingAttributes>.activities where other.id != activity?.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        do {
            let recovery = try CaptureFiles.recover(in: CaptureFiles.directory(), excluding: activeID ?? pendingStart)
            for url in recovery.saved {
                NotificationCenter.default.post(name: .selfnoteRecordingSaved, object: url)
            }
            guard activeID == nil && !isBusy else { return }
            if recovery.unreadable > 0 {
                lastStatus = "An interrupted recording couldn’t be saved."
            } else if !recovery.saved.isEmpty {
                lastStatus = "Recovered interrupted audio."
            }
        } catch {
            if activeID == nil { lastStatus = "Recordings couldn’t be opened. Unlock and reopen Selfnote." }
        }
    }

    private func observeSession(id: UUID) {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                  object: nil, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                try? await self?.finish(id: id, savedMessage: "Recording interrupted. Captured audio saved.")
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await self?.finish(id: id, savedMessage: "Audio input restarted. Captured audio saved.")
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                  object: nil, queue: .main) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let oldInputs = previous?.inputs.map(\.uid) ?? []
            let newInputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
            guard Self.lostInput(reason: reason, previous: oldInputs, current: newInputs) else { return }
            Task { @MainActor in
                try? await self?.finish(id: id, savedMessage: "Microphone disconnected. Captured audio saved.")
            }
        })
        if let activity {
            activityObserver = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    if state == .ended || state == .dismissed {
                        try? await self?.finish(id: id, savedMessage: "Recording activity ended. Captured audio saved.")
                        return
                    }
                }
            }
        }
    }

    nonisolated static func lostInput(reason: AVAudioSession.RouteChangeReason, previous: [String], current: [String]) -> Bool {
        if reason == .noSuitableRouteForCategory { return true }
        return reason == .oldDeviceUnavailable && previous.contains { !current.contains($0) }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        handleUnexpectedStop(at: recorder.url, message: flag ? "Recording saved." : "Recording interrupted. Captured audio saved.")
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        handleUnexpectedStop(at: recorder.url, message: "Audio input failed. Captured audio saved.")
    }

    private nonisolated func handleUnexpectedStop(at url: URL, message: String) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url, let id = self.activeID else { return }
            try? await self.finish(id: id, savedMessage: message)
        }
    }
}

/// A short history of actual input power, not generated waveform decoration.
struct RecordingLevelHistory {
    static let capacity = 32
    private(set) var values: [CGFloat] = []

    mutating func append(decibels: Float) {
        values.append(Self.normalized(decibels))
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    static func normalized(_ decibels: Float) -> CGFloat {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        // Square-root scaling makes quiet speech visible while retaining a genuine zero for silence.
        let amplitude = pow(10.0, Double(min(decibels, 0)) / 20)
        return CGFloat(sqrt(max(0, (amplitude - 0.001) / 0.999)))
    }
}
