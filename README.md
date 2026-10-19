# ClipboardMac

A native clipboard history utility for **macOS 26+**, built with Swift and AppKit. It runs in the menu bar without a persistent Dock icon. History stays on this Mac; the app sends no clipboard content or telemetry. Version checks and downloads of selected updates use public GitHub Releases.

## Getting started

The built app is located at `dist/ClipboardMac.app`. Open it in Finder. For regular use, you can move it to `/Applications`, then configure permissions and Launch at Login.

Settings opens on first launch:

1. In General, choose a global Open History shortcut. No shortcut is assigned by default. You can also open history from the menu bar.
2. In Privacy, request clipboard access, then choose **Always Allow** in System Settings. When access is set to Ask or Denied, the app does not read content automatically or prompt repeatedly.
3. Enable Accessibility for automatic paste. History, search, and Copy Only remain available without it.

The app does not require Input Monitoring, Screen Recording, or administrator privileges. Launch at Login is off by default; its toggle reflects the system's SMAppService state. For launch at login, use the app in a permanent location rather than the executable in `.build`.

## Usage

- Copy plain text. Capture checks for changes every 500 ms.
- Open history from the menu bar or with your chosen shortcut. Search receives focus, and the first entry is selected.
- Use the arrow keys to select an entry; Enter or a single click requests Paste. Command-Enter performs Copy Only.
- Command-P pins or unpins, Command-Backspace deletes, and Command-Y opens the full text in a read-only preview. These commands are also available in the context menu.
- Escape, pressing the Open History shortcut again, or switching the active window closes the panel without pasting.
- Clear Recent keeps pinned entries; Clear All requires confirmation.

Exact text, including Unicode, spaces, tabs, and line breaks, is preserved without normalization. Empty values, content larger than 1 MiB in UTF-8, files, non-text content, and values marked concealed/transient/generated are not saved. History retains up to 500 recent unique entries by default; the configurable range is 50–2000. Pinned entries do not count toward the limit.

Automatic paste checks the original app, window, and focused element. If the target is unavailable, focus has changed, or Accessibility is not enabled, no keystrokes are sent; Copy Only is available with the message “Copied. Press Cmd+V to paste”. Sending Command-V is not treated as confirmation that insertion actually occurred. A new external copy while restoring the target cancels the synthetic paste.

## Building and testing

Requires Xcode with the macOS 26 SDK or later and Swift 6.2+; no third-party packages are used.

```sh
swift test
Scripts/build-app.sh
```

A universal build for Apple Silicon and Intel:

```sh
UNIVERSAL=1 Scripts/build-app.sh
```

For a debug build: `CONFIGURATION=debug Scripts/build-app.sh`. To open Settings during development: `dist/ClipboardMac.app/Contents/MacOS/ClipboardMac --settings`.

The script creates an `.app` bundle and signs it ad hoc. Distribution beyond your own machine requires Developer ID, notarization, and a stable signing identity; you can pass `SIGN_IDENTITY` to the script. The minimum macOS version for both slices of the universal binary is 26.0.

## Publishing and updates

Publish from a clean working tree on the `main` branch. The script fetches the latest commits and tags, increments the patch version in the `vMAJOR.MINOR.PATCH` SemVer tag (the first version is `v1.0.0`), and pushes the branch together with the tag to `origin`:

```sh
./publish-next-version.sh
```

You can specify the remote, branch, initial version, and version increment type (`Patch`, `Minor`, or `Major`), for example: `./publish-next-version.sh origin main 1.0.0 Minor`. Pushing the tag triggers `.github/workflows/release.yml`: the workflow builds a universal `.app` and attaches `ClipboardMac-macos.zip` to the GitHub Release. Make sure your changes are committed before running the script.

In **About ClipboardMac**, the app checks the latest stable GitHub Release. If a new version is available, you can open its release page or install the archive and restart the app. Automatic installation requires write access to the app's parent directory; if the directory is protected, About explains why installation is unavailable. For distribution beyond your own machine, configure Developer ID and notarization.

## Architecture

- `HistoryCore`: models, text rules, sorting, Unicode search, and the storage contract; no AppKit or SQLite.
- `HistoryServices`: capture and paste orchestration through replaceable contracts.
- `HistoryInfrastructure`: system SQLite, NSPasteboard, Accessibility, Carbon hotkeys, preferences, and Command-V key resolution using the current keyboard layout.
- `ClipboardMac`: the AppKit panel, settings, and application composition.

The SQLite database is located at `~/Library/Application Support/ClipboardMac/history.sqlite`. The directory has `0700` permissions, and the main file has `0600` permissions; the directory protects access to sidecar files. The schema is versioned, changes are transactional, queries containing data are parameterized, and WAL, synchronous FULL, and secure_delete are enabled. Maintenance runs off the main thread after clearing history and at startup. The app does not claim to provide its own encryption or guarantee physical erasure of data from SSDs or backups.

## Verification status

Automated checks and remaining manual scenarios are documented in [Documentation/Verification.md](Documentation/Verification.md). Current product requirements and engineering rules are in `.idd/`.
