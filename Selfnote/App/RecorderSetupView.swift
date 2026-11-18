import SwiftUI

struct RecorderSetupView: View {
    var body: some View {
        List {
            Section("Try the recorder") {
                Text("Tap Record a note and allow microphone access. Start speaking when the recording timer appears. Tap Stop & Save to add the recording to your notes.")
            }
            Section("Make the recording shortcut") {
                Text("In Shortcuts, tap +, add Selfnote’s Start Recording action, and name the shortcut Record Selfnote. Run it once while your iPhone is unlocked.")
            }
            Section("Triple Back Tap") {
                Text("Open Settings → Accessibility → Touch → Back Tap → Triple Tap. Under Shortcuts, choose Record Selfnote. Tap the back of your iPhone three times to start.")
                    .accessibilityIdentifier("setupBackTap")
            }
            Section("Action button") {
                Text("On an iPhone with an Action button, open Settings → Action Button → Shortcut and choose Record Selfnote. Press and hold the button to start.")
                    .accessibilityIdentifier("setupActionButton")
            }
            Section("Control Center and Lock Screen") {
                Text("Add Selfnote’s Record Note control from the controls gallery. The recording Live Activity shows elapsed time and Stop. iPhone may ask you to unlock.")
            }
            SpeechSetupSection()
        }
        .navigationTitle("Recording setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}
