#!/bin/bash
set -euo pipefail

foldgit_root="$(cd "$(dirname "$0")/.." && pwd)"
foldgit_output="${1:-$foldgit_root/dist/macos}"
mkdir -p "$foldgit_output"
foldgit_output="$(cd "$foldgit_output" && pwd)"
foldgit_work="$(mktemp -d "${TMPDIR:-/tmp}/FoldGit-package.XXXXXX")"

printf 'Release build log: %s\n' "$foldgit_output/build.log"
if ! xcodebuild archive \
  -project "$foldgit_root/Platforms/macOS/FoldGit.xcodeproj" \
  -scheme FoldGit \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$foldgit_work/FoldGit.xcarchive" \
  -derivedDataPath "$foldgit_work/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=arm64 \
  > "$foldgit_output/build.log" 2>&1; then
  tail -n 100 "$foldgit_output/build.log"
  exit 1
fi

foldgit_app="$foldgit_work/FoldGit.xcarchive/Products/Applications/FoldGit.app"
foldgit_plist="$foldgit_app/Contents/Info.plist"
foldgit_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$foldgit_plist")"
foldgit_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$foldgit_plist")"
foldgit_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$foldgit_plist")"
foldgit_name="FoldGit-$foldgit_version-macOS-arm64"

codesign --force --sign - --options runtime --timestamp=none "$foldgit_app"
codesign --verify --deep --strict --verbose=2 "$foldgit_app"
lipo "$foldgit_app/Contents/MacOS/FoldGit" -verify_arch arm64
test "$(lipo -archs "$foldgit_app/Contents/MacOS/FoldGit")" = arm64
test -s "$foldgit_app/Contents/Resources/Assets.car"
test -s "$foldgit_app/Contents/Resources/AppIcon.icns"

if [ -e "$foldgit_output/FoldGit.app" ]; then
  mv "$foldgit_output/FoldGit.app" "$foldgit_output/FoldGit.app.previous-$(date +%Y%m%d%H%M%S)"
fi
ditto "$foldgit_app" "$foldgit_output/FoldGit.app"
ditto -c -k --keepParent "$foldgit_app" "$foldgit_output/$foldgit_name.zip"

foldgit_dmg_source="$foldgit_work/dmg"
mkdir -p "$foldgit_dmg_source"
ditto "$foldgit_app" "$foldgit_dmg_source/FoldGit.app"
ln -s /Applications "$foldgit_dmg_source/Applications"
hdiutil create -volname FoldGit -srcfolder "$foldgit_dmg_source" -fs HFS+ -format UDZO -ov "$foldgit_output/$foldgit_name.dmg"
hdiutil verify "$foldgit_output/$foldgit_name.dmg"

(
  cd "$foldgit_output"
  shasum -a 256 "$foldgit_name.dmg" "$foldgit_name.zip" > SHA256SUMS.txt
)
cat > "$foldgit_output/BUILD-INFO.txt" <<EOF
FoldGit $foldgit_version ($foldgit_build)
Architectures: arm64
Minimum macOS: $foldgit_minimum
Signing: local ad hoc, hardened runtime
Apple notarization: not performed
Source icon: Shared/Resources/Branding/AppIcon.icon
Build log: build.log
EOF
printf 'Created: %s\n' "$foldgit_output/$foldgit_name.dmg" "$foldgit_output/$foldgit_name.zip"
