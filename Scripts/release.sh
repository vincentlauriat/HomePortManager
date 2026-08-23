#!/usr/bin/env bash
# Build a Release "HomePort Manager.app" (App/ xcodegen project), Developer ID sign
# with Hardened Runtime, notarize via Apple, staple, and package as release/*.dmg.
#
# Usage: ./Scripts/release.sh <version>          e.g. ./Scripts/release.sh 1.0.0
# Local dry run (no notarization): SKIP_NOTARIZE=1 ./Scripts/release.sh 1.0.0
#
# Uses the Mac-wide setup (see ~/DevApps/CLAUDE.md): Developer ID certificate
# "Vincent LAURIAT (KFLACS69T9)" and the shared notarytool keychain profile
# "AppliMacVincentGithub".

set -euo pipefail

VERSION="${1:?Usage: ./Scripts/release.sh <version>  (e.g. 1.0.0)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/App"
APP_NAME="HomePort Manager"
cd "$APP_DIR"

# 1. project.yml must carry the same MARKETING_VERSION.
if ! grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml; then
  echo "✗ MARKETING_VERSION in App/project.yml does not match $VERSION" >&2
  grep "MARKETING_VERSION" project.yml | sed 's/^/    /' >&2
  exit 1
fi

# 2. Regenerate the Xcode project.
command -v xcodegen >/dev/null || { echo "✗ brew install xcodegen" >&2; exit 1; }
echo "→ xcodegen generate"
xcodegen generate >/dev/null

# 3. Build Release, unsigned (manual signing next; avoids provenance-xattr failures).
echo "→ xcodebuild Release"
xcodebuild -project HomePortMenu.xcodeproj \
  -scheme HomePortMenu \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3

APP="$APP_DIR/build/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ Build did not produce $APP" >&2; exit 1; }

# The embedded dashboard (and the future API client) is dead without the AD-3 ATS
# exception: a project.yml that lost the key would still build green, so assert it here.
if [ "$(/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" \
    "$APP/Contents/Info.plist" 2>/dev/null)" != "true" ]; then
  echo "✗ Info.plist lacks NSAppTransportSecurity/NSAllowsArbitraryLoads (AD-3): the embedded dashboard cannot load HTTP — check App/project.yml" >&2
  exit 1
fi

# 4. Stage clean, sign with Hardened Runtime (timestamp server can be flaky → retries).
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"

STAGING_DIR="$(mktemp -d)"
STAGING="$STAGING_DIR/$APP_NAME.app"
echo "→ Staging to $STAGING_DIR"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

codesign_ts() {
  local target="$1" attempt
  for attempt in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target" 2>&1; then
      return 0
    fi
    [ "$attempt" -lt 5 ] && { echo "  ↻ codesign failed (attempt $attempt/5), retrying in 5s…"; sleep 5; }
  done
  echo "✗ codesign $target failed after 5 attempts" >&2
  return 1
}

echo "→ Codesigning the app with Developer ID + Hardened Runtime"
codesign_ts "$STAGING"
codesign --verify --strict --deep "$STAGING"

RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/HomePortManager-$VERSION.dmg"
rm -f "$DMG"

echo "→ Creating $DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGING_DIR"

# 5. Notarize + staple.
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠️  SKIP_NOTARIZE=1: DMG signé mais NON notarisé: $DMG"
  exit 0
fi

echo "→ Submitting to Apple notary service (2–5 min)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "→ Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✅ Built, signed, notarized and stapled: $DMG ($(ls -lh "$DMG" | awk '{print $5}'))"
