# Xcode App Project Setup

This repo now includes an Xcode app project specification and app metadata files so you can run TensorLabs Voice as a normal `.app` (no terminal runtime required).

## Files Added
- `project.yml` (XcodeGen project spec)
- `XcodeSupport/Info.plist` (app bundle metadata + permission strings)
- `XcodeSupport/TensorLabsVoice.entitlements` (entitlements placeholder)
- `scripts/generate_xcodeproj.sh` (generates `TensorLabsVoice.xcodeproj`)

## Generate the Xcode Project
1. Install XcodeGen once:
```bash
brew install xcodegen
```
2. Generate the project:
```bash
./scripts/generate_xcodeproj.sh
```
3. Open in Xcode:
```bash
open TensorLabsVoice.xcodeproj
```

## Run as an App
1. In Xcode, select scheme `TensorLabsVoice`.
2. Run (`Cmd+R`).
3. The menu bar app launches without terminal.

## Build a Standalone App
1. Product -> Archive.
2. Distribute App -> Copy App.
3. Move the exported `.app` to `/Applications`.

## Notes
- Bundle ID defaults to `com.tensorlabs.voice` in `project.yml`.
- `LSUIElement` is set so the app behaves as a menu bar app.
- Mic/speech usage descriptions are set in `XcodeSupport/Info.plist`.
