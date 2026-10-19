#!/bin/bash
# Builds, tests and packages a release into dist/: the ZIP, its .sha256 and its .sig (signed with the key in the
# login keychain). Publishes nothing; it prints the gh command to run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
bash test.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Blackout.app/Contents/Info.plist)"
TAG="v$VERSION"  # The app refuses an update whose bundle version isn't exactly its tag minus the "v".
ZIP="Blackout-$TAG-macOS-arm64.zip"
rm -rf dist && mkdir -p dist
# No resource forks or extended attributes: otherwise unzip extracts ._ files that break the code signature.
ditto -c -k --norsrc --noextattr --noacl --keepParent build/Blackout.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
swift run --quiet ReleaseTool sign "dist/$ZIP"
swift run --quiet ReleaseTool verify "dist/$ZIP"
cat <<EOF

Release files are in dist/. To publish (pre-releases count as updates):
  gh release create $TAG --target "$(git rev-parse HEAD)" --prerelease --title "Blackout $VERSION" \\
    --notes-file NOTES.md dist/$ZIP dist/$ZIP.sha256 dist/$ZIP.sig
EOF
