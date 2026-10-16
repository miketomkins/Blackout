#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p build
swiftc -swift-version 5 Sources/Core.swift Tests/TestMain.swift -o build/BlackoutTests
build/BlackoutTests
swiftc -swift-version 5 Sources/Core.swift Sources/DisplayBackend.swift Tests/BackendTests.swift -o build/BackendTests -framework AppKit -framework ApplicationServices -framework CoreGraphics
build/BackendTests
python3 -m unittest discover -s Tests -p '*Tests.py' -v
codesign --verify --deep --strict build/Blackout.app
