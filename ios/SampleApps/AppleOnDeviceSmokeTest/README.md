# Apple On-Device Smoke Test

This sample app is a minimal iOS SwiftUI harness for exercising IndeRun's Apple Foundation Models provider on a real supported device.

## Requirements

- Xcode 26.0 or newer with the iOS 26.0 SDK installed
- A physical iPhone or iPad that supports Apple Intelligence and Apple Foundation Models
- Apple Intelligence enabled on the device
- An OS/device/locale state where the system model is eligible and ready

## Project Layout

- `AppleOnDeviceSmokeTest.xcodeproj`: iOS app project
- `AppleOnDeviceSmokeTest/`: SwiftUI app sources

The app depends on the local Swift package at `ios/IndeRun` and imports:

- `IndeRunSwift`
- `IndeRunCore`
- `IndeRunContracts`
- `IndeRunAppleProviders`

## Manual Smoke Test

1. Open `AppleOnDeviceSmokeTest.xcodeproj` in Xcode.
2. Choose a real supported iOS 26.0+ device.
3. Configure a signing team for the app target if Xcode requests one.
4. Build and run the app.
5. Confirm the status area reports provider availability or unavailability.
6. Enter or keep the default prompt, then tap `Run on Device`.
7. Confirm one of these outcomes:
   - success: generated text appears in the output panel
   - normalized failure: the UI shows `IndeRunException.errorClass` and message

## Expected Failure Modes

- `CapabilityMismatch`: the system model is unavailable on the device, not enabled, or not ready
- `Internal`: an unexpected runtime/provider failure occurred

## Notes

- This app is intentionally a smoke-test harness, not a production sample.
- It does not call Apple Foundation Models directly from the UI layer; all execution goes through IndeRun's public Swift APIs.
