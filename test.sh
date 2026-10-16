#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# Always rebuild so the CLI tests below exercise the current sources, including on a fresh clone.
bash build.sh
swift run --quiet CoreChecks
swift run --quiet BackendChecks
python3 -m unittest discover -s Tests -p '*Tests.py' -v
codesign --verify --deep --strict build/Blackout.app
