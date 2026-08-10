# App Privacy questionnaire draft

This is a working draft for the App Store Connect questionnaire, not a completed legal attestation. The account holder must compare every answer with the exact binary being submitted and personally confirm it in App Store Connect.

## Proposed top-level answers

- **Does this app collect data from this app?** No.
- **Is any data used to track users?** No.
- **Privacy Policy URL:** https://blog.fka.dev/textream/privacy.html

These proposed answers are based on the following build assumptions:

- the App Store build has no analytics, advertising, crash-reporting, attribution, or tracking SDK;
- the App Store build does not use the direct-download GitHub update checker;
- the developer does not operate an account, synchronization, speech, storage, or telemetry service for Textream;
- scripts, imported presentation notes, and preferences are processed locally unless the user explicitly enables a local-network feature;
- Remote Connection and Director Mode communicate directly with devices the user connects on the same local network; the developer does not receive that traffic;
- Apple’s Speech framework may process microphone audio on-device or through Apple, but Textream’s developer does not receive the audio or recognition result;
- no later code, embedded framework, or SDK changes the statements above.

## Why microphone and speech do not automatically mean “data collected”

App Store privacy answers describe data collected by the developer or third parties integrated into the app. Permission to use microphone audio is still privacy-sensitive and must be disclosed clearly, but Apple-framework processing that the developer cannot access is not represented here as developer collection. Re-check Apple’s current App Privacy guidance when submitting.

## Permissions and user-facing disclosures to verify

- Microphone purpose text explains that voice-guided modes need audio input.
- Speech Recognition purpose text explains that microphone audio may be sent to Apple for recognition.
- Local Network purpose text explains Remote Connection and Director Mode.
- The in-app About screen links to the published privacy policy.
- The public privacy policy matches the behavior of the uploaded build.

## Local-network privacy note

Remote Connection can expose script text and reading state to a connected device. Director Mode can also accept script edits and control commands. These features are user-enabled and local, but their HTTP and WebSocket traffic is not end-to-end encrypted. The public privacy policy tells users to use a trusted network and disable the features afterward.

## Re-check immediately before attesting

1. Inspect the archived app for embedded SDKs and frameworks.
2. Exercise every feature while monitoring outbound connections.
3. Confirm the App Store build has no direct-update request, donation flow, account flow, analytics, or developer backend.
4. Confirm the final privacy-policy page is publicly reachable without login.
5. Re-read Apple’s current definitions of “collect” and “tracking.”
6. Have the account holder submit the answers personally.
