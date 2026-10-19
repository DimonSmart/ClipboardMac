#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
architectures=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then architectures=(--arch arm64 --arch x86_64); fi
swift build -c "$configuration" "${architectures[@]}"
bin_dir="$(swift build -c "$configuration" "${architectures[@]}" --show-bin-path)"
app_dir="$PWD/dist/ClipboardMac.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/ClipboardMac" "$app_dir/Contents/MacOS/ClipboardMac"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION:-1.0.0}" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$app_dir/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app_dir"
print -r -- "$app_dir"
