# Phoenix AI Android — v0.0.1

This is the first Android app foundation for Phoenix. It is separate from the existing Python CLI workflow and can be added to the existing `Phoenix-AI` repository without deleting `phoenix.py`, `templates.json`, `leads.json`, `history.json`, or the current workflow.

## Included in v0.0.1
- Flutter Android app with Phoenix launcher icon and dark/cyan/amber interface.
- Chat UI and Gemini REST chat connection.
- API key saved using Android secure storage on this device.
- Android speech recognition for short voice turns; recognized text is shown in the composer and sent when final.
- Text-to-speech for Phoenix replies, with voice mode and mute controls.
- GitHub Actions workflow to build a debug APK artifact.

## Not included yet
- Freelance workflow execution and template build engine.
- Video clip generation/editing pipeline and YouTube publishing.
- Background always-listening wake word.
- Autonomous client submission or automatic YouTube publishing.
These are later modules. This version does not pretend they are implemented.

## Build on GitHub (phone-friendly)
1. Upload/merge the contents of this folder into the root of your existing `Phoenix-AI` repository. Keep your existing Python files and JSON data.
2. Commit and push to `main`.
3. Open GitHub → Actions → **Phoenix Android v0.0.1 APK** → Run workflow.
4. When the run completes, open its Artifacts section and download `phoenix-v0.0.1-debug-apk`.
5. Extract the artifact ZIP and install `app-debug.apk` on your Android phone. Allow installation from that source when Android asks.

The workflow uses Flutter stable and builds a debug APK. It does not require your Gemini key in GitHub Secrets.

## Build locally
Install Flutter SDK and Android SDK, then:
```bash
flutter pub get
dart run flutter_launcher_icons
flutter build apk --debug
```
APK output:
`build/app/outputs/flutter-apk/app-debug.apk`

## Configure Gemini
Open Phoenix → settings icon → paste your Gemini API key → Save on phone.
The key is stored with `flutter_secure_storage` using Android encrypted preferences/Keystore-backed storage. It is not written into this repository or GitHub Actions. It is sent to Google's Gemini API over HTTPS for each chat request. Client-side keys are not fully extraction-proof; do not distribute an APK containing a personal key.

Model field defaults to `gemini-2.5-flash`. If that model is unavailable to your API key or account, change it in Settings to a model currently enabled for your Gemini API project.

## Voice behaviour / limitations
The `speech_to_text` plugin uses Android's speech recognition service. It is intended for short conversational turns, not always-on continuous listening. Device language availability and Google speech service availability can vary. The app shows the transcript before sending and retains text input as a fallback. Text-to-speech uses the device's installed TTS engine.

## Package choices
- Flutter/Dart for a native-feeling Android app UI and a single codebase.
- `speech_to_text` for Android speech recognition.
- `flutter_tts` for device text-to-speech.
- `flutter_secure_storage` for local credential storage.
- `http` for Gemini REST calls.

Version: **0.0.1+1**
