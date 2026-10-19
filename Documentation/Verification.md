# Implementation and verification — 2026-10-19

## Implementation result

- **Mode:** satisfy-current-intent.
- **Specs used as intent:** IDD-0001 through IDD-0005; IDD-0006 used as the paste-prototype investigation sequence.
- **Engineering rules applied:** ENG-0001 and ENG-0002 (all Always rules, mechanically enumerated); ENG-0003 selected because this implementation creates persisted clipboard history.
- **Engineering structure:** README/INDEX and all three uniquely indexed canonical rule files inspected. Headings, required sections, Applicability and INDEX agree; no archive, lifecycle sections or fenced operational commands in rules; allocator ENG-0004 exceeds all current IDs. No guardrail edits.
- **Behavior changed:** created the native menu-bar application, capture/privacy controls, SQLite history, pins, retention, Unicode search, history panel, keyboard and contextual commands, settings, login-item integration, configurable shortcut, safe paste and Copy Only.
- **Behavior preserved / public contracts preserved:** there was no prior implementation. Existing Product Intent and Engineering documents remain unchanged.
- **Compatibility/data constraints:** macOS 26+, arm64 and x86_64; local private Application Support directory; exact UTF-8 content stored as BLOB; no ORM, external service, telemetry or Maccy dependency. Initial schema migration is version 1; unknown newer schemas produce an error instead of replacement.
- **Code areas changed:** Package.swift; Sources/HistoryCore, HistoryServices, HistoryInfrastructure, ClipboardMac and CSQLite; Resources/Info.plist; Scripts/build-app.sh.
- **Tests changed:** two new Swift Testing files covering nine meaningful scenarios.
- **Verification result:** platform fallback used because `.idd/verification.yaml` is absent. `swift test` passed nine Swift Testing tests (the preceding XCTest runner reports zero because this suite uses Swift Testing). Universal release build and bundle checks passed.
- **Engineering conformance:** no mismatch found in the scoped source/dependency review.
- **Intent-drift-audit result:** implemented scenarios match the inspected contracts; remaining evidence gaps below prevent claiming complete real-device acceptance.
- **Remaining risks:** broad target-app behavior and OS permission states still require manual validation; signed distribution and Intel hardware execution have not been validated.

## Automated evidence

| Check / command | Result |
| --- | --- |
| `swift test` | 9 tests passed, including exact UTF-8 variants, embedded NUL, Russian/English/accented search, SQLite restart, deduplication, pins, retention, delete and clear |
| Capture/privacy service tests | Passed: pause/resume baseline, no reads while permission is required, exclusions, protected/empty/oversized values, 1 MiB boundary, racing snapshots, self-writes and later external writes |
| Real NSPasteboard adapter test with a unique named board | Passed: exact Unicode text, source marker, concealed/transient/generated markers, own writes, file URLs and multi-item rejection. Does not change General pasteboard or its permissions |
| Paste service tests | Passed: one operation accepted at a time, original snapshot retained, failed target falls back, Copy Only sends no key, external clipboard changes during focus restoration send no paste |
| Keyboard-layout resolver | Passed: installed US, Russian and Dvorak tables resolve Command-V without switching the user's layout; Dvorak resolves a different physical key |
| Native hotkey registration | Passed: register, replace, unregister and re-register; Command-V and Command-Shift-V rejected |
| Storage load/maintenance | Passed: two fill/clear/reopen cycles at 2000 entries; retention reduction to 500; 100 Unicode searches under 2 seconds; compacted database below 100 KB after clearing |
| `UNIVERSAL=1 Scripts/build-app.sh` | Passed: release application bundle built and ad-hoc signed |
| `lipo -archs dist/ClipboardMac.app/Contents/MacOS/ClipboardMac` | arm64 and x86_64 |
| `xcrun vtool -show-build dist/ClipboardMac.app/Contents/MacOS/ClipboardMac` | minimum macOS 26.0 in both architectures |
| `codesign --verify --deep --strict dist/ClipboardMac.app` | Passed |
| `plutil -lint Resources/Info.plist` | Passed |

The toolchain emits a deprecation warning for x86_64 against its SDK. The produced Intel slice is present and its actual minimum system version is 26.0, confirmed from Mach-O load commands.

## Observed UI and prototype evidence

Host: macOS 26.7.1, Apple Silicon, Xcode 27.1. During the development launch the application reported Accessibility enabled and clipboard access Always Allow. These observations do not establish the behavior of a fresh Finder-launched installation.

A minimal native prototype was built and run before the full history panel. Automated interaction could inspect windows but did not reliably drive a physical global shortcut. The user then tested the prototype and explicitly confirmed that its test text was inserted after invoking the shortcut and the paste action. The requested test was in a blank TextEdit document; automated UI inspection did not independently establish the target used in that manual confirmation. This is evidence for basic real-device insertion, not completion of IDD-0006 across its full matrix.

UI automation subsequently verified:

- General and Privacy settings render within their window and expose named controls.
- Launch at Login initially displays off; no login registration was enabled during verification.
- History opens from the application menu with empty search and the first available entry selected.
- Unicode search accepts input and shows No matches for an absent query.
- A known multiline Unicode test copy appears in Recent with a concise preview.
- Entries remain after restarting the application.
- Command-P moves the selected entry to Pinned.
- Command-Y opens a read-only full-content sheet, including Unicode and trailing-space content.
- Preview rows use the available panel width; pin controls stay at the trailing edge.

No user's permission settings, login items, system appearance or keyboard layout were changed by these checks. Development test entries remain available in the local history.

## Manual checks still not verified

Use non-sensitive disposable text and documents. These are acceptance checks, not claims of existing test evidence.

1. On a fresh macOS 26 installation exercise Ask, Always Allow and Always Deny. Verify only an explicit user request prompts; polling under Ask/Deny does not. Check history and Copy Only remain usable.
2. Launch the packaged app from Finder. Check Accessibility disabled/enabled and the resulting Copy Only/automatic-paste paths without granting unrelated privileges.
3. Physically invoke the configurable shortcut in TextEdit/Notes, a browser form, VS Code and a terminal-like app. Exercise single click, Enter, repeated Enter and double click; verify at most one insertion. In a terminal use harmless text and no final newline.
4. Repeat insertion under Russian and Dvorak or another non-QWERTY layout. Automated layout-table resolution has passed; real insertion under these layouts has not been observed.
5. Change the target's field/window, terminate the target, activate a different app, or copy new text while the panel is open. Verify there is no synthetic paste into another field/app and Copy Only is reported.
6. Check protected fields and remote desktops: unsupported or unverifiable focus should fall back; event posting alone is never a success notification.
7. Check light/dark appearance, VoiceOver navigation, active-display placement, multiple monitors, Spaces and full-screen apps. Only the current display and appearance were visually inspected.
8. Move the bundle to a permanent location; enable/disable Launch at Login, check the system status including any required approval, restart the session, and verify settings/history/pins survive. Reopening the packaged app should not create a second monitor.
9. Run the Intel slice on a supported Intel Mac. Cross-building confirms compatibility at build time, not hardware execution.

IDD-0006 remains unresolved for its full matrix; no Product Intent or spike result was rewritten to imply completion.

# Intent Drift Audit

## Scope

Focused scope derived from this implementation: new Sources/* capture, storage, panel/commands, settings and paste behavior; the associated macOS 26 and local-data contracts in IDD-0001–0005; prototype evidence from IDD-0006; ENG-0001–0003. No intent or Engineering mutation is part of this audit.

## Relevant Current Intent

IDD-0001: native menu-bar lifecycle and local-only data. IDD-0002: eligible exact text, privacy and capture controls. IDD-0003: atomic persistence, exact recopy, pins, retention and Unicode search. IDD-0004: panel, keyboard commands, shortcut and settings. IDD-0005: original-target validation, one synthetic paste and Copy Only. IDD-0006: real-device validation.

## Relevant Engineering Guardrails

All Always rules ENG-0001/0002, plus ENG-0003 for persisted history. The same validated rule metadata and bodies used for implementation were used for this read-only comparison.

## Findings

### History, capture and command behavior

Classification: `matches-intent`. Scope: `current-requirement`.

Evidence: IDD-0001–0004 compared with domain/service policies, SQLite transactions and BLOB equality, AppKit controls, capture adapter and nine automated scenarios. UI evidence additionally covers search, keyboard pinning, full preview and restart history. No intended import/export, cloud, rich-format or global keyboard-monitoring features were added.

### Safe-paste behavior

Classification: `matches-intent`. Scope: `current-requirement`.

Evidence: IDD-0005 compared with pre-activation target snapshots, focused-element/window checks, serial selection acceptance, rechecking focus immediately before one Command-V down/up pair, layout-aware key resolution and fallback tests. No synthetic event is sent by Copy Only. No affirmative insertion-success notification exists. Manual prototype insertion was confirmed by the user.

### Remaining real-device acceptance matrix

Classification: `missing-verification`. Scope: `compatibility-boundary`.

Evidence: IDD-0001/0002/0004/0005/0006 require real permission, target-app, layout, accessibility, display and restart scenarios. Only the observations explicitly listed above exist; the nine remaining manual groups are not verified. Automated fake targets and layout tables do not substitute for those system behaviors.

Recommended next step: run the bounded manual checklist on the packaged application; record observations without clipboard content. Resolve IDD-0006 only after its targets and layouts have been exercised.

### Native, layered and system-SQLite constraints

Classification: `engineering-match`. Scope: `current-requirement`.

Evidence: ENG-0001–0003 compared with the SwiftPM target graph and source imports. Core and service decisions do not import AppKit or SQLite. Infrastructure owns native adapters and a serialized actor-backed system SQLite connection with versioning, prepared statements, WAL, bounded busy wait, transactions and maintenance. Both binary architectures target macOS 26.0. No third-party packages or Maccy source are present.

## Summary

Product Intent: inspected implementation matches the scoped contracts; full real-device acceptance remains unverified. No Product Intent was changed and no unowned durable feature was found. Engineering: no scoped mismatch found. Verification: automated and listed UI evidence passed; remaining manual evidence is explicitly distinguished above. Complete the manual matrix before claiming release acceptance.
