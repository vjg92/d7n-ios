# d7n for iOS — on-device dictation keyboard (prototype)

A custom iPhone keyboard that records, transcribes and types text **inside the keyboard**, with no app switch and no network. Transcription uses Apple's on-device `SpeechTranscriber` (iOS 26). It is the iOS companion to [d7n for Mac](https://github.com/vjg92/d7n).

This is a working proof of concept, not a finished keyboard: it has a mic button and a globe key, but no letter keys.

## How it works

iOS does not let keyboard extensions record with `AVAudioEngine`; starting the engine fails with `AVAudioSession` error `'what'` (2003329396). This prototype records through a hidden `WKWebView` instead:

1. The keyboard holds an effectively invisible 2×2 web view that calls `getUserMedia`. WebKit captures audio under the **containing app's** microphone permission.
2. A `ScriptProcessor` sends Float32 PCM to Swift through a script message handler.
3. Swift converts the buffers and runs `SpeechAnalyzer` + `SpeechTranscriber` in the keyboard process.
4. The text is inserted with `textDocumentProxy.insertText`. No clipboard.

## Safeguards

- Audio is kept in memory only, never written to disk, and dropped after transcription.
- The mic turns off after 2 minutes, and when the keyboard is hidden, you switch apps, or you move to another text field. Anything recorded is then thrown away.
- Text is only typed into the field where dictation started. If you have moved elsewhere, it is discarded.
- The hidden web view loads only its built-in page. All network requests and navigations are blocked, and if the block can't be set up the recorder doesn't load.
- Only microphone requests from that page are approved; camera and other requests are refused. iOS still enforces the app's microphone permission.

## Caveats

- **This is a workaround.** Apple could block web-view audio capture in keyboards in a future iOS release, and App Review may reject it. It is fine for personal installs from Xcode.
- iOS shows its orange microphone indicator while recording.
- Verified on an iPhone 15 Pro running iOS 26.6.2.

## Requirements

- Xcode 26 or newer, iOS 26 SDK
- An iPhone that supports Apple Intelligence, running iOS 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you change `project.yml` (`brew install xcodegen`)
- An Apple ID for signing. With a free account, the app must be reinstalled every 7 days.

## Build and install

```sh
xcodegen generate
xcodebuild -project D7NKeyboardTest.xcodeproj -scheme D7NTest \
  -destination 'platform=iOS,id=<your-device-id>' \
  DEVELOPMENT_TEAM=<your-team-id> -allowProvisioningUpdates build
```

Or open `D7NKeyboardTest.xcodeproj` in Xcode, set your team on both targets, and run on your iPhone. Find your device id with `xcrun devicectl list devices`.

## Set up on the iPhone

1. Open **d7n test**, tap **Allow microphone**, then **Download model**.
2. Settings → General → Keyboard → Keyboards → Add New Keyboard → **d7n**, then tap d7n and turn on **Allow Full Access**.
3. In any app, switch to d7n with the globe key, tap the mic, speak, and tap again.

The keyboard reports what happened: `WORKS`, `BLOCKED`, silence, or a transcription error.

## Files

- `Keyboard/KeyboardViewController.swift`: keyboard UI and web-view recorder
- `Shared/Speech.swift`: audio buffer store, model download and transcription (used by both targets)
- `App/TestApp.swift`: setup app for the microphone permission and model download
- `project.yml`: XcodeGen project definition
