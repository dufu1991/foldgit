#!/bin/bash
set -euo pipefail

# Usage: package-macos.sh [--dmg-only] [output-directory] [extra xcodebuild arguments...]
# --dmg-only writes only FoldGit.app and the DMG (the release workflow signs and publishes the DMG itself).
foldgit_root="$(cd "$(dirname "$0")/.." && pwd)"
foldgit_dmg_only=false
if [ "${1:-}" = "--dmg-only" ]; then
  foldgit_dmg_only=true
  shift
fi
foldgit_output="${1:-$foldgit_root/dist/macos}"
if [ "$#" -gt 0 ]; then shift; fi
mkdir -p "$foldgit_output"
foldgit_output="$(cd "$foldgit_output" && pwd)"
foldgit_work="$(mktemp -d "${TMPDIR:-/tmp}/FoldGit-package.XXXXXX")"
trap 'rm -rf "$foldgit_work"' EXIT

printf 'Release build log: %s\n' "$foldgit_output/build.log"
if ! xcodebuild archive \
  -project "$foldgit_root/Platforms/macOS/FoldGit.xcodeproj" \
  -scheme FoldGit \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$foldgit_work/FoldGit.xcarchive" \
  -derivedDataPath "$foldgit_root/build/PackagingDerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=arm64 \
  "$@" \
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

# Trim the embedded frameworks before signing. The app is arm64 only (project.yml ARCHS).
foldgit_frameworks="$foldgit_app/Contents/Frameworks"
if [ -d "$foldgit_frameworks" ]; then
  while IFS= read -r -d '' foldgit_file; do
    foldgit_archs="$(lipo -archs "$foldgit_file" 2>/dev/null)" || continue
    if [ "$foldgit_archs" != arm64 ]; then
      case " $foldgit_archs " in
        *" arm64 "*)
          lipo "$foldgit_file" -thin arm64 -output "$foldgit_file.thin"
          # Rewrite in place so the original file mode is kept.
          cat "$foldgit_file.thin" > "$foldgit_file"
          rm "$foldgit_file.thin"
          ;;
        *) printf 'Embedded binary has no arm64 slice: %s (%s)\n' "$foldgit_file" "$foldgit_archs" >&2; exit 1 ;;
      esac
    fi
  done < <(find "$foldgit_frameworks" -type f -print0)
fi

foldgit_sparkle="$foldgit_frameworks/Sparkle.framework"
if [ -d "$foldgit_sparkle" ]; then
  # Sparkle only uses its XPC services in sandboxed apps or when Info.plist enables them.
  foldgit_entitlements="$foldgit_root/Platforms/macOS/Configuration/FoldGit.entitlements"
  if ! grep -q 'com.apple.security.app-sandbox' "$foldgit_entitlements" \
    && ! /usr/libexec/PlistBuddy -c 'Print :SUEnableDownloaderService' "$foldgit_plist" > /dev/null 2>&1 \
    && ! /usr/libexec/PlistBuddy -c 'Print :SUEnableInstallerLauncherService' "$foldgit_plist" > /dev/null 2>&1; then
    rm -rf "$foldgit_sparkle/Versions/B/XPCServices" "$foldgit_sparkle/XPCServices"
  else
    printf 'Keeping Sparkle XPC services: the app is sandboxed or enables them.\n'
  fi

  # Keep Sparkle localizations only for languages the app ships. Sparkle has no en.lproj; English is Base.lproj.
  foldgit_keep=" Base en English "
  for foldgit_language_file in "$foldgit_root"/Shared/Resources/Localization/*.json; do
    foldgit_language="$(basename "$foldgit_language_file" .json)"
    case "$foldgit_language" in
      zh-Hans) foldgit_keep+="zh-Hans zh_CN " ;;
      zh-Hant) foldgit_keep+="zh-Hant zh_TW zh_HK " ;;
      *) foldgit_keep+="$foldgit_language ${foldgit_language//-/_} " ;;
    esac
  done
  while IFS= read -r -d '' foldgit_lproj; do
    foldgit_language="$(basename "$foldgit_lproj" .lproj)"
    case "$foldgit_keep" in
      *" $foldgit_language "*) ;;
      *) rm -rf "$foldgit_lproj" ;;
    esac
  done < <(find "$foldgit_sparkle/Versions" -type d -name '*.lproj' -prune -print0)
fi

python3 "$foldgit_root/Scripts/sign-macos-adhoc.py" "$foldgit_app"
lipo "$foldgit_app/Contents/MacOS/FoldGit" -verify_arch arm64
test "$(lipo -archs "$foldgit_app/Contents/MacOS/FoldGit")" = arm64
test -s "$foldgit_app/Contents/Resources/Assets.car"
test -s "$foldgit_app/Contents/Resources/AppIcon.icns"

if [ -e "$foldgit_output/FoldGit.app" ]; then
  mv "$foldgit_output/FoldGit.app" "$foldgit_output/FoldGit.app.previous-$(date +%Y%m%d%H%M%S)"
fi
ditto "$foldgit_app" "$foldgit_output/FoldGit.app"
if [ "$foldgit_dmg_only" = false ]; then
  ditto -c -k --keepParent "$foldgit_app" "$foldgit_output/$foldgit_name.zip"
fi

foldgit_dmg_source="$foldgit_work/dmg"
mkdir -p "$foldgit_dmg_source"
ditto "$foldgit_app" "$foldgit_dmg_source/FoldGit.app"
ln -s /Applications "$foldgit_dmg_source/Applications"
hdiutil create -volname FoldGit -srcfolder "$foldgit_dmg_source" -fs HFS+ -format UDZO -ov "$foldgit_output/$foldgit_name.dmg"
hdiutil verify "$foldgit_output/$foldgit_name.dmg"

if [ "$foldgit_dmg_only" = true ]; then
  printf 'Created: %s\n' "$foldgit_output/$foldgit_name.dmg"
  exit 0
fi

(
  cd "$foldgit_output"
  shasum -a 256 "$foldgit_name.dmg" "$foldgit_name.zip" > SHA256SUMS.txt
)
cat > "$foldgit_output/BUILD-INFO.txt" <<EOF
FoldGit $foldgit_version ($foldgit_build)
Architectures: arm64
Minimum macOS: $foldgit_minimum
Signing: local ad hoc, including embedded updater tools
Apple notarization: not performed
Source icon: Shared/Resources/Branding/AppIcon.icon
Build log: build.log
EOF
printf 'Created: %s\n' "$foldgit_output/$foldgit_name.dmg" "$foldgit_output/$foldgit_name.zip"
