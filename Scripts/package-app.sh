#!/bin/zsh
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
bundle="${1:-$root_dir/dist/Operator.app}"
version_config="$root_dir/Config/Version.xcconfig"

if [[ ! -r "$version_config" ]]; then
  print -u2 "Missing version configuration at $version_config"
  exit 1
fi

marketing_version=$(sed -n 's/^MARKETING_VERSION = //p' "$version_config" | tr -d '[:space:]')
build_number=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$version_config" | tr -d '[:space:]')

if [[ ! "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  print -u2 "Config/Version.xcconfig must define a semantic MARKETING_VERSION and positive CURRENT_PROJECT_VERSION"
  exit 1
fi

if [[ -e "$bundle" ]]; then
  print -u2 "Refusing to overwrite $bundle"
  exit 1
fi

cd "$root_dir"
swift build -c release
build_products=$(swift build -c release --show-bin-path)
resource_bundle="$build_products/Operator_Operator.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  print -u2 "Missing SwiftPM resource bundle at $resource_bundle"
  exit 1
fi
mkdir -p "$root_dir/dist"
staging=$(mktemp -d "$root_dir/dist/operator-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
staged_bundle="$staging/Operator.app"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
cp "$build_products/Operator" "$staged_bundle/Contents/MacOS/Operator"
cp Packaging/Info.plist "$staged_bundle/Contents/Info.plist"
cp Packaging/Operator.icns "$staged_bundle/Contents/Resources/Operator.icns"
cp -R "$resource_bundle" "$staged_bundle/Contents/Resources/Operator_Operator.bundle"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$staged_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$staged_bundle/Contents/Info.plist"
chmod 755 "$staged_bundle/Contents/MacOS/Operator"
chmod 644 "$staged_bundle/Contents/Info.plist" "$staged_bundle/Contents/Resources/Operator.icns"
/usr/bin/plutil -lint "$staged_bundle/Contents/Info.plist" >/dev/null
cmp -s "$build_products/Operator" "$staged_bundle/Contents/MacOS/Operator"
for asset in claude-code.svg codex.svg; do
  if [[ ! -r "$staged_bundle/Contents/Resources/Operator_Operator.bundle/$asset" ]]; then
    print -u2 "Packaged app is missing required resource: $asset"
    exit 1
  fi
done
/usr/bin/codesign \
  --force \
  --sign - \
  --options runtime \
  --timestamp=none \
  "$staged_bundle"
/usr/bin/codesign --verify --deep --strict "$staged_bundle"
mv "$staged_bundle" "$bundle"
print "Created hardened $bundle (version $marketing_version, build $build_number)"
