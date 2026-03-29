# TensorLabs Voice

Local-first dictation scaffold for macOS (Apple Silicon), designed for future iPhone portability.

## Current State
- Native macOS menu bar app (`SwiftUI` + `AppKit`) with enable/disable toggle
- Push-to-talk global hotkey wired to `Command + Shift + Space`
- Dual app modes:
  - `Dictation` inserts recognized text into the focused app
  - `Assistant` listens on the hotkey, replies locally, and speaks the answer back
- Live audio capture via `AVAudioEngine`
- Runtime-selected local ASR stack:
  - `fast` -> Parakeet TDT (CoreML)
  - `balanced` -> Qwen3-ASR 0.6B (MLX)
  - `accurateFast` -> Whisper distil-large-v3 (WhisperKit)
  - `accurate` -> Whisper large-v3 (WhisperKit)
- Automatic fallback runtime: `AppleSpeechEngine` (on-device only) if local model preparation fails
- Cross-app insertion with Accessibility-first strategy and paste fallback
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
3. In Dictation mode, grant Accessibility permissions in `System Settings -> Privacy & Security -> Accessibility` so text can be inserted into other apps.
4. Press and hold `Command + Shift + Space`, speak, then release.
5. In Dictation mode, the recognized text is inserted into the focused app.
6. In Assistant mode, the app replies locally and speaks the answer back.

## Notes
- WhisperKit may download the selected model on first run, then run locally on-device afterward.
- If WhisperKit cannot initialize, the app falls back to Apple on-device Speech so dictation still works.

## Compare Decode Speed
With diagnostics enabled, you can summarize local dictation timings from the metrics log:

```bash
swift scripts/summarize_dictation_metrics.swift
```

To limit the report to the latest sessions:

```bash
LIMIT=20 swift scripts/summarize_dictation_metrics.swift
```

## Xcode App Project
To run this as a normal macOS app (`.app`) without terminal, see:

- [Xcode migration guide](docs/xcode-app-migration.md)
