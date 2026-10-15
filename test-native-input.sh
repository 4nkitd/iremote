#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
swift build --product iRemote
BIN="$(swift build --show-bin-path)"
swiftc -I "$BIN" Sources/iRemote/TVTypingView.swift Tests/NativeInputProbe.swift \
    "$BIN/RemoteCore.o" -o .build/NativeInputProbe
.build/NativeInputProbe
