# Smart Audio Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Default both capture sources to the current system devices and publish a ranked competitive feature backlog.

**Architecture:** Extend existing Core Audio enumeration and AppModel. Resolve device choices immediately before capture; listeners refresh picker names and inventories. Keep the capture engine and existing user changes intact.

**Tech Stack:** Swift, SwiftUI, Core Audio, Swift Testing; no new dependency.

**Spec:** ../specs/2026-11-26-smart-audio-defaults-design.md

## Global Constraints

- Keep macOS 14.2 compatibility, existing dependencies, and the user's existing AudioCaptureManager format correction unchanged.
- Microphone capture defaults on; turning it off remains an explicit user choice.
- Preserve connected manual choices and resolve input/output independently.
- Do not restart or replace an active recording on a route-change event.
- Keep the broader feature backlog explicitly unimplemented.

## Review Focus

- Headphones become the default while the menu stays open: the label and next recording must use the new output.
- A connected manual override survives a system-default change.
- An unplugged override falls back to the current default before capture.
- A missing required input/output creates no recording session.
- Listener callbacks must release AppModel and be removed on teardown.

## Task 1: Implement and verify automatic selection

**Files:** AudioDevices.swift, CallCaptureApp.swift, ContentView.swift, CaptureError.swift under macos-app/Sources; new Tests/CallCaptureTests/AudioDeviceSelectionTests.swift.

**Interfaces:** Add `AudioDeviceEnumerator.defaultInputDevice()` and `defaultOutputDevice()` returning `AudioDeviceInfo?`; add `resolveDevice(preferredUID: String?, devices: [AudioDeviceInfo], defaultDevice: AudioDeviceInfo?) -> AudioDeviceInfo?`.

- [x] Write selection tests for changed defaults, valid/missing overrides, a stale default and no devices.
- [x] Run `swift test --filter AudioDeviceSelectionTests`; confirm the missing implementation fails.
- [x] Add lookup/resolution, AppModel listeners and preflight, default labels and the explicit microphone toggle.
- [x] Run the focused tests and `swift build`; confirm successful completion.

## Task 2: Document the next upgrades and review the whole change

**Files:** docs/FEATURES.md, docs/PENDING.md, README.md, this plan.

- [x] Publish five ranked feature groups with outcomes and acceptance criteria; link the backlog from README/PENDING.
- [x] Run full Python and Swift suites; distinguish an environment block from a failing assertion.
- [x] Request a fresh whole-change review and address material findings.
- [x] Verify the original capture patch is unchanged and record results here.

## Execution notes

Ruling: implement the concrete device-default request in this pass and capture the
larger competitive upgrade in a ranked backlog, matching the user's request for a
feature list. No extra approval gate is introduced for this authorized change.

Ruling: use a task branch in the existing workspace so the user's in-progress
capture-format fix remains present and unchanged. No commit, push, or release is
needed to make this local change reviewable.

Review finding: the nonisolated async recording start could refresh device state
concurrently with the main-queue HAL listener. The complete refresh-and-resolve
operation now uses one MainActor.run snapshot before session creation.

## Verification receipts

- RED: six new selection tests failed to compile because resolveDevice did not
  exist. GREEN: all six passed after implementation.
- Final Swift regression run after the review fix:
  `swift test --skip 'JobRequestEngineTests|PricingSettingsTests'` passed 60 Swift
  Testing cases plus 2 XCTest cases. Build succeeded. Existing linker warnings
  reference missing cached ModuleCache files; they did not prevent linking.
- Full `swift test --skip-build` was attempted with a 25-second bound. It did not
  complete; the six tests in the two skipped suites instantiate SettingsManager
  and depend on live Keychain access, the same block identified in the audit.
  This is not a full-suite pass. The task-owned test process group was stopped.
- Python: `.venv/bin/python -m pytest -q --no-cov -p no:cacheprovider` passed all
  190 tests.
- `git diff --check` passed; final review approved the corrected main-thread
  snapshot. No material review findings remain.
- The pre-existing capture-format diff remains unchanged: SHA-256
  e245b9ec6fd5e396cea3febad4d8798649573941972fcee0d0a25eb5bed336e2.
- No app was launched, no real microphone/audio was recorded, and no route was
  changed for testing. Wired/Bluetooth capture, visual layout and seamless
  mid-recording handover remain unverified. No release was published.
