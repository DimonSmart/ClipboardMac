![ClipboardMac — pinned prompts at your fingertips](assets/social-preview.jpg)

# ClipboardMac

**Stop typing the same prompt twice.**

That perfect Claude Code prompt? The Codex instructions you use every day? Don't bury them in a notes file.

ClipboardMac keeps your clipboard history and lets you **pin the text worth keeping**. Prompts, code snippets, terminal commands — ready to paste whenever you need them.

- **Pin your favorites.** They stay put, even when your recent clipboard history fills up.
- **Keep coding.** Open history with a shortcut, pick a snippet, press Enter to paste.
- **Keep it private.** Your clipboard history stays on your Mac. No account, no cloud uploads, no telemetry.

Native macOS menu bar app. **macOS 26 (Tahoe) or newer.**

## Install

**[Download the latest version](https://github.com/DimonSmart/ClipboardMac/releases/latest)**

Unzip `ClipboardMac-macos.zip`, move `ClipboardMac.app` to `/Applications`, and open it.

**Or just tell Claude Code, Codex, or your favorite coding agent:**

```text
Install ClipboardMac on my Mac from https://github.com/DimonSmart/ClipboardMac/releases/latest.
Download the latest ClipboardMac-macos.zip, extract ClipboardMac.app,
and move it to /Applications. Help me open it and set it up.
If macOS blocks the app, explain how I can approve it myself
without disabling macOS security protections.
```

The release is currently ad-hoc signed, not notarized. macOS may ask you to approve it in **System Settings → Privacy & Security** after your first attempt to open it.

## First launch

1. Choose a shortcut for **Open History** in Settings (none is assigned by default).
2. Allow clipboard access in **Settings → Privacy** and macOS System Settings.
3. Enable **Accessibility** if you want to paste directly into other apps. Without it, you can still browse, search, and copy snippets.

Inside clipboard history: **⌘P** to pin or unpin, **Enter** to paste, **⌘Enter** to copy without pasting, **⌘Y** to preview.

## Build from source

Requires Xcode with the macOS 26 SDK and Swift 6.2+.

```sh
swift test
Scripts/build-app.sh
```

See [verification notes](Documentation/Verification.md) for test coverage and manual checks.
