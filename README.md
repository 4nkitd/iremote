# iRemote

A native macOS menu bar remote for Google TV and Android TV.

Requires macOS 15 or later and a TV running Android TV Remote Service on the same local network. Developer mode and ADB are not required. The downloadable alpha supports Apple Silicon Macs only.

## Install with Homebrew

```sh
brew install --cask 4nkitd/tap/iremote
```

Then launch **iRemote** from Applications. It lives in the menu bar, not the Dock.

To update:

```sh
brew update
brew upgrade --cask 4nkitd/tap/iremote
```

Alternatively, download `iRemote-0.1.2-macos-arm64.zip` from [Releases](https://github.com/4nkitd/iremote/releases), unzip it and move iRemote.app into Applications.

### Alpha signing warning

Version 0.1.2 is ad-hoc signed, **not Developer ID signed or notarised by Apple**. macOS may block the first launch. If you trust the download, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway**, when offered. See [Apple's guidance](https://support.apple.com/en-us/102445). If macOS does not offer approval, build from source instead.

The Homebrew cask does not remove quarantine attributes or bypass Gatekeeper. Installation alone does not grant permission to run the app.

## Build

Install Xcode with a Swift 6-capable toolchain, then:

```sh
git clone https://github.com/4nkitd/iremote.git
cd iremote
swift test
./build-app.sh
open dist/iRemote.app
```

The development build is ad-hoc signed, not notarised. No background helper or Python runtime is required.

## Pair

Open the remote icon in the menu bar. Choose your TV and enter the six hexadecimal characters shown on its screen. The app remembers the pairing and reconnects automatically.

If no TV appears, check that it is awake, that both devices share a network, and that macOS allows iRemote to access the local network. Guest networks can block device discovery.

## Features

- Local-network discovery and code pairing.
- Clickpad, Back, Home, Play/Pause, Mute and Power.
- Volume controls and status, when the TV reports them.
- Current-app status and a small set of app links.
- Keyboard navigation while the panel is focused.
- Mac keyboard typing into the focused TV text field, including Unicode, paste, backspace and Return.

Arrow keys navigate, Return selects, Escape goes back, Space plays or pauses, H opens Home, M toggles mute, and minus/plus adjust volume. Click outside to dismiss the panel.

On the Keyboard tab, open a search or text field on the TV and type normally on your Mac. Letters and spaces are text in this mode, not remote shortcuts.

The app chooses between two input paths:

- **Direct keyboard:** used when the TV does not expose its text field. Sends Android hardware-key events. Supports printable English letters, numbers and punctuation, up to 512 characters per paste, plus Backspace, cursor keys and Return. The Mac field previews keys sent, not the TV's contents. Clear and selection replacement are unavailable because the app cannot read the TV field. Unsupported pastes are rejected before any keys are sent.
- **Synced input:** used when the TV reports a focused field. Supports Unicode and pastes up to 4,096 UTF-16 units; Clear and replacement support fields up to 500 composed characters. The app waits for text/cursor acknowledgments before advancing. If an acknowledgment is missing, pending input stops instead of being retried or duplicated.

Direct keyboard input has been tested on a physical Google TV with YouTube search. Synced-input tests currently use a simulated TV; compatibility varies by TV app.

Configurable app tiles and a global keyboard shortcut are not implemented yet. App links depend on the installed app and its link handling.

## Privacy and pairing storage

This alpha stores its client identity in `~/Library/Application Support/iRemote/identity.p12`. It is restricted to the local user with file mode 0600 inside a 0700 directory and imported into process memory. It is **not stored in Keychain**. The PKCS#12 passphrase is a format requirement, not a security boundary. Other processes running as the same user can read this identity.

Paired TV addresses and certificate fingerprints are saved in the app's preferences. A changed TV certificate requires pairing again. The app does not log entered pairing codes or TV text.

Control traffic stays on your local network over TLS. There is no account, cloud backend or analytics. Device compatibility and credential storage will continue to improve before a stable release.

## Testing

`swift test` exercises malformed protobuf rejection, pairing-state validation, local TLS pairing, remote commands, app links, text input, serialized volume control, idle pings and certificate mismatch rejection. These tests use a simulated TV and do not establish compatibility with every physical TV.

The optional `FakeTV` executable advertises a simulated TV on the standard ports. Its name is deliberately distinct from a real device:

```sh
swift run FakeTV 'iRemote Test TV'
```

FakeTV prints its simulated pairing code to the terminal. It is a development tool, not part of the app bundle.

Temporary debugging uses `IREMOTE_INPUT_DIAGNOSTICS=1` for one launch. It logs fixed event names and numeric counters, not typed text or pairing codes. Normal launches leave it disabled.

## Design reference

The [design board](design/iremote-v4.png) documents the visual direction. It includes planned controls that are not all available in this alpha; the feature list above describes the current build.

## License and acknowledgments

[MIT](LICENSE). Protocol research and app-link attribution are documented in [THIRD_PARTY.md](THIRD_PARTY.md).
