import SwiftUI

struct RecordingBar: View {
    @ObservedObject private var recorder = CaptureController.shared
    @State private var errorMessage: String?

    var body: some View {
        let recording = recorder.activeID != nil

        VStack(alignment: .leading, spacing: 6) {
            if !recording, let status = recorder.lastStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
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
                HStack(spacing: 14) {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.18), in: Circle())
                        .accessibilityHidden(true)
                    Text(recording ? "Stop & Save" : "Record a note")
                        .font(.custom("InstrumentSans-Regular", size: 18, relativeTo: .headline).weight(.semibold))
                    Spacer(minLength: 6)
                    if recording, let start = recorder.startedAt {
                        Text(start, style: .timer)
                            .font(.callout.monospacedDigit())
                            .fixedSize()
                            .accessibilityHidden(true)
                    } else if recorder.isBusy {
                        ProgressView().tint(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(recording ? Color(red: 0.65, green: 0.16, blue: 0.21) : Color("RecordButton"),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isBusy)
            .accessibilityHint(recording ? "Finishes and saves this recording." : "Starts recording from the microphone.")
            .accessibilityIdentifier(recording ? "stopRecording" : "startRecording")
        }
        .frame(maxWidth: 630)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .alert("Recording needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
