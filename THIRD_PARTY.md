# Third-party references

The app-link catalog in `Sources/RemoteCore/KnownApps.swift` adapts entries from [Couch](https://github.com/abiodunosagie/couch), `known_apps.json`. The text-input counter, UTF-16 cursor and echo-ordering behavior in `TVTextInput.swift` also follows Couch's `text_input.py`, reimplemented in Swift with bounded queues and stop-on-timeout behavior.

## Couch license

MIT License

Copyright (c) 2026 Abiodun Osagie

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Protocol research

The Swift implementation follows the Android TV Remote v2 wire format, using [androidtvremote2](https://github.com/tronikos/androidtvremote2) and its protocol definitions as interoperability references. That project is distributed under [Apache License 2.0](https://github.com/tronikos/androidtvremote2/blob/main/LICENSE). The Python library is not bundled or required at runtime.

App names and service trademarks belong to their respective owners. iRemote is not affiliated with Google, Apple, or Teenage Engineering.
