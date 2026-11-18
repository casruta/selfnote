import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@main
struct SelfnoteWidgets: WidgetBundle {
    var body: some Widget {
        RecordNoteControl()
        RecordingLiveActivity()
    }
}

private struct RecordNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Selfnote.RecordNote") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record Note", systemImage: "mic.fill")
            }
        }
        .displayName("Record Note")
        .description("Start a voice note in Selfnote.")
    }
}

private struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selfnote is recording")
                        .font(.headline)
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                }
                Spacer(minLength: 0)
                StopRecordingButton(noteID: context.attributes.noteID)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "mic.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopRecordingButton(noteID: context.attributes.noteID)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording")
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .frame(width: 48)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording")
            }
        }
    }
}

private struct StopRecordingButton: View {
    let noteID: UUID

    var body: some View {
        Button(intent: StopRecordingIntent(noteID: noteID)) {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Stop and save recording")
    }
}
