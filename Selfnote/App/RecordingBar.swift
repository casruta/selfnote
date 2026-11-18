import SwiftUI
import UIKit

struct RecordingBar: View {
    @ObservedObject private var recorder = CaptureController.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var errorMessage: String?
    @State private var levels = RecordingLevelHistory()

    private var meterSession: UUID? {
        scenePhase == .active && recorder.phase == .recording ? recorder.activeID : nil
    }

    private var actionTitle: String {
        switch recorder.phase {
        case .idle: "Record a note"
        case .preparing: "Preparing microphone…"
        case .recording: "Stop & Save"
        case .saving: "Saving recording…"
        }
    }

    var body: some View {
        let recording = recorder.phase == .recording
        VStack(alignment: .leading, spacing: 10) {
            if recording {
                HStack {
                    Label("Recording", systemImage: "record.circle")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let start = recorder.startedAt {
                        Text(start, style: .timer)
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .accessibilityIdentifier("recordingStatus")
                levelDisplay
                    .accessibilityHidden(true)
            } else if recorder.phase == .idle, let status = recorder.lastStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                let activeID = recorder.activeID
                Task {
                    do {
                        if let activeID {
                            try await recorder.stop(expectedID: activeID)
                        } else {
                            try await recorder.start(requireLiveActivity: false)
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    if recorder.isBusy {
                        ProgressView().tint(.white)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: recording ? "stop.fill" : "mic.fill")
                            .accessibilityHidden(true)
                    }
                    Text(actionTitle)
                        .font(.custom("InstrumentSans-Regular", size: 18, relativeTo: .headline).weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(recording ? Color(red: 0.65, green: 0.16, blue: 0.21) : Color("RecordButton"),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isBusy)
            .accessibilityHint(recording ? "Finishes and saves this recording." : "Starts recording from the microphone.")
            .accessibilityIdentifier(recording ? "stopRecording" : "startRecording")
        }
        .padding(14)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 24).fill(Color(uiColor: .secondarySystemBackground))
            } else {
                RoundedRectangle(cornerRadius: 24).fill(.regularMaterial)
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .frame(maxWidth: 630)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .task(id: meterSession) {
            levels = RecordingLevelHistory()
            guard !Task.isCancelled, let id = meterSession, let lease = recorder.beginMetering(recordingID: id) else { return }
            defer { recorder.endMetering(lease: lease) }
            while !Task.isCancelled {
                guard let power = recorder.inputLevel(lease: lease) else { return }
                levels.append(decibels: power)
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 50)) }
                catch { return }
            }
        }
        .alert("Recording needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var levelDisplay: some View {
        GeometryReader { geometry in
            if reduceMotion {
                // No scrolling or interpolation: a single current-level indicator.
                Capsule().fill(.tint)
                    .frame(width: max(2, geometry.size.width * (levels.values.last ?? 0)), height: 4)
                    .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 3) {
                    let padding = max(0, RecordingLevelHistory.capacity - levels.values.count)
                    let samples = Array(repeating: CGFloat.zero, count: padding) + levels.values
                    ForEach(samples.indices, id: \.self) { index in
                        Capsule().fill(.tint)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, samples[index] * geometry.size.height))
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 28)
    }
}
