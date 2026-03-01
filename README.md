# TensorLabs Voice

Local-first dictation scaffold for macOS (Apple Silicon), designed for future iPhone portability.

## Current State
- Native macOS menu bar app (`SwiftUI` + `AppKit`) with enable/disable toggle
- Push-to-talk global hotkey wired to `Command + Shift + Space`
- Live audio capture via `AVAudioEngine`
- Primary ASR runtime: `WhisperKitEngine` (local model)
- Automatic fallback runtime: `AppleSpeechEngine` (on-device only) if WhisperKit init fails
- Cross-app insertion with Accessibility-first strategy and paste fallback
- Local model profiles:
  - `balanced` -> `small.en`
  - `fast` -> `base.en`
- Local diagnostics logger at `~/Library/Application Support/TensorLabsVoice/logs/metrics.jsonl`

## Prerequisites
- macOS 13+
- Apple Silicon recommended
- Xcode command line tools installed (`xcode-select --install`)

## Build
```bash
swift build
```

## Run
```bash
swift run TensorLabsVoice
```

After launch:
1. Click the menu bar item named `Voice` and select `Enable Dictation`.
2. Grant microphone and speech recognition permission prompts.
3. Grant Accessibility permissions in `System Settings -> Privacy & Security -> Accessibility` so text can be inserted into other apps.
4. Press and hold `Command + Shift + Space`, speak, then release to finalize and insert text into the focused app.

## Notes
- WhisperKit may download the selected model on first run, then run locally on-device afterward.
- If WhisperKit cannot initialize, the app falls back to Apple on-device Speech so dictation still works.

## Xcode App Project
To run this as a normal macOS app (`.app`) without terminal, see:

- [Xcode migration guide](docs/xcode-app-migration.md)
