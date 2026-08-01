#!/bin/zsh
set -euo pipefail

# Build and run the checkout containing this script, regardless of the caller's
# current directory. Extra arguments are forwarded to Operator.
root_dir=$(cd "$(dirname "$0")/.." && pwd)

# Prefer the full Xcode toolchain when it is installed, while still allowing
# machines that only have Command Line Tools to build the Swift package.
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v swift >/dev/null 2>&1; then
  print -u2 "Swift is required. Install Xcode or the Xcode Command Line Tools."
  exit 1
fi

cd "$root_dir"
swift build -c release

executable="$root_dir/.build/release/Operator"
if [[ ! -x "$executable" ]]; then
  print -u2 "Build completed but Operator was not found at $executable"
  exit 1
fi

# A bare SwiftPM executable has no application bundle. That works for most
# AppKit APIs but UserNotifications requires NSBundle.main to be an .app.
# Build a throwaway, ad-hoc-signed bundle and run its executable in the
# foreground; closing Operator returns here and removes only this mktemp dir.
staging=$(mktemp -d "$root_dir/.build/operator-run.XXXXXX")
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Operator.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$executable" "$bundle/Contents/MacOS/Operator"
cp "$root_dir/Packaging/Info.plist" "$bundle/Contents/Info.plist"
cp "$root_dir/Packaging/Operator.icns" "$bundle/Contents/Resources/Operator.icns"
chmod 755 "$bundle/Contents/MacOS/Operator"
chmod 644 "$bundle/Contents/Info.plist" "$bundle/Contents/Resources/Operator.icns"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"

"$bundle/Contents/MacOS/Operator" "$@"
