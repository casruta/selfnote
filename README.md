# Selfnote

Record a thought, stop, and get an editable note on your iPhone. Selfnote saves the audio first, transcribes it on the phone, and keeps the original transcript next to your edits. Requires **iOS 26 or later**. The iPhone 13 Pro Max is a supported installation target. Available speech languages depend on the device. [iOS 26 compatibility](https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-26-iphe3fa5df43/26) · [Apple Speech](https://developer.apple.com/documentation/speech/speechtranscriber)

## Install from Windows

1. In GitHub, open a successful **iPhone build and tests** run for the branch you want to test. Download the **Selfnote-iPhone** artifact and extract **Selfnote.ipa** from the outer ZIP. The IPA already contains the device app and its recording widget. It needs signing for your iPhone. [Build runs](https://github.com/casruta/selfnote/actions/workflows/iphone.yml)
2. Install **Sideloadly** for Windows and the Apple components listed in its Windows setup instructions. Connect the unlocked iPhone by USB and tap **Trust** if prompted. [Sideloadly for Windows](https://sideloadly.io/)
3. In Sideloadly, select your iPhone, load **Selfnote.ipa**, and sign locally using your own Apple Account. Keep the embedded **SelfnoteWidgets** extension. Leave any option to remove app extensions disabled. Click **Start**. With a free account, refresh or re-sign the app every seven days using the same account and bundle identity to retain its data. [Sideloadly FAQ](https://sideloadly.io/faq)
4. Follow the phone’s trust prompt under **Settings → General → VPN & Device Management** if it appears. Turn on **Settings → Privacy & Security → Developer Mode** if requested, restart, and confirm on the phone. Open Selfnote and make your first recording before configuring a shortcut. [Apple’s Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## Record from the back of an iPhone 13 Pro Max

1. Tap **Record a note**, allow the microphone, and speak after the timer appears. Tap **Stop & Save**, open the note, and play the recording. Enable Live Activities for Selfnote in Settings for recording through Shortcuts.
2. In **Shortcuts**, tap **+**, add Selfnote’s **Start Recording** action, and name the shortcut **Record Selfnote**. Run it once with the phone unlocked.
3. Open **Settings → Accessibility → Touch → Back Tap → Triple Tap** and choose **Record Selfnote** under Shortcuts. Triple-tap the **back** of the phone. Speak after the ready cue. Stop in the app or from its recording Live Activity.

The right-side triple-click is Apple’s Accessibility Shortcut. On a genuinely locked phone, the Selfnote shortcut asks for authentication before it starts. Starting an existing recording action again keeps the current session. [Back Tap setup](https://support.apple.com/en-ca/guide/shortcuts/apd897693606/ios) · [Accessibility Shortcut](https://support.apple.com/en-au/guide/iphone/iph3e2e31a5/ios)

## Use an Action button or an on-screen control

On an iPhone with an Action button, choose **Settings → Action Button → Shortcut → Record Selfnote**. Press and hold the Action button to start the same action. You can also add Selfnote’s **Record Note** control to Control Center or a customizable Lock Screen. The in-app setup screen includes these steps. [Action button setup](https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios) · [System controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)

## Your notebook

- Stop closes the audio file. The notebook imports the finished recording under a stable ID and transcribes it when the app can run and read protected data. The first use of a speech language may download Apple’s model. For an offline test, finish one note in that language first.
- The inbox supports search. Open a note to edit, play the audio, check a task, share Markdown text, or delete the note and its recording. The original transcript remains available after editing.
- Short opening phrases can become titles. Ordinary speech stays as prose. In English, explicit cues such as “To do, buy two clay pots” and “Bullet, bring gloves” create checklist or list items when recognized with a cue delimiter. “I might plant mint” remains a thought.
- If transcription fails, the note retains its audio. Open it to retry, choose another supported language, or enter the text yourself. Notes and recordings use ordinary device backup settings.

## Verify on the phone

Try ten starts with your normal case and record which gestures the phone recognizes. Say a distinctive first and last word, then play the saved clip. Try another Start while recording, a phone call or headset disconnect, locking mid-recording, and starting from an awake but locked phone with Face ID covered. After a language download, try a recording in airplane mode. Each completed capture should yield one note and one playable recording. Hardware gesture recognition, haptic feel, and actual microphone input require a physical phone.

## Build and test

Open **Selfnote.xcodeproj** in Xcode with the iOS 26 SDK or newer and select the **Selfnote** scheme. For a local signed device build, choose a development team or create an ignored `Config/Signing.local.xcconfig` setting `DEVELOPMENT_TEAM` and a unique `SELFNOTE_BUNDLE_ID`. The app and widget derive their identifiers from that value.

GitHub Actions builds the Release device app on macOS, checks the embedded extension and App Intents metadata, packages the IPA, and runs unit and UI tests on an iPhone simulator. The suite covers recording-file recovery, notebook formatting and retry, and the recording entry screen. The implementation uses Apple frameworks with no external service accounts. The source is MIT-licensed. Instrument Sans is distributed under the SIL Open Font License included with the font. [Design plan](docs/iphone-app-plan.md)
