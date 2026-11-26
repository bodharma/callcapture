# Smart audio defaults

The first competitive upgrade makes starting a recording dependable: use the
Mac's current default output and microphone, while retaining explicit choices.

## Behaviour

- Output and microphone start on **System Default**, displaying the current
  device name. Microphone capture starts enabled; users can explicitly turn it off.
- Watch Core Audio device-list and default-input/default-output changes. Refresh
  both pickers while idle, and resolve devices again immediately before capture.
- Keep a connected manual override when system defaults change. If the selected
  device disappears, fall back to System Default for the next recording.
- Resolve input and output independently. If a required device is unavailable,
  show an actionable error before creating a session or starting capture.
- Keep an active recording on its existing devices. Seamless mid-recording
  handover needs separate capture/recovery work and belongs in the backlog.
  Warn that unplugging an active device may interrupt its audio.

## Implementation and boundaries

Extend the existing AudioDeviceEnumerator for default-device lookup and pure
selection resolution. AppModel owns Core Audio listener registration/removal,
available/default devices, microphone enablement, and final preflight selection.
ContentView keeps the two pickers and adds an explicit microphone toggle.
CaptureError distinguishes unavailable input from unavailable output.

Keep macOS 14.2 compatibility, existing dependencies, and the user's existing
AudioCaptureManager format correction unchanged. No recording is started for
verification without permission. Overrides are session preferences, as today;
persisted/per-app routing is future work.

The broader request is captured in docs/FEATURES.md as ranked, unimplemented
work, including the four correctness findings from the preceding audit.

## Verification

Test default changes, connected overrides, unplugged overrides, missing defaults,
and empty inventories with synthetic device lists. Build the app, run the new
Swift tests and the full suites, and report the known Keychain test dependency
separately if it blocks a full Swift run. Review the complete diff before handoff.
