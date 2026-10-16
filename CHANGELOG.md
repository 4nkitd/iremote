# Changelog

## 0.2.0 alpha

- App discovery: the Apps tab can verify which catalog shortcuts launch on your TV. In the background iRemote presses Home, opens each shortcut, and confirms it from the TV's own app reports. Confirmed shortcuts are cached per TV, and unverified suggestions are labelled as such.
- The Apps tab offers to run the scan after pairing a new TV; you can run it again any time from **Discover**.
- Completed scans replace the saved list for that TV, including an empty result. Cancelled scans, a powered-off TV, lost feedback and disconnects leave saved results untouched.
- Discovery never removes a shortcut because of a normal launch timeout, and it does not reopen the previous app when the scan ends.
- 59 automated tests, including a scan state machine with synthetic TV reports and end-to-end TLS discovery against the simulated TV.

## 0.1.2 alpha

First public release. macOS 15+, Apple Silicon.

- Native menu bar panel with directional navigation and media controls.
- Local discovery, six-character pairing, TLS certificate pinning and reconnection.
- App launcher with a fixed set of known links.
- Mac keyboard input through synchronized IME when available, with direct Android keyboard fallback otherwise.
- Validation of pairing messages, protobuf lengths and reported volume values.
- Sequential volume changes and bounded text input queues.
- 36 automated tests, plus a native AppKit input probe.

The alpha is ad-hoc signed and not notarised. Global shortcuts, launch at login, app tile customization and a stable signed release are not included.
