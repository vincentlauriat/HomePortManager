#!/usr/bin/env bash
# Build a Release "HomePort Manager.app" (App/ xcodegen project), Developer ID sign
# with Hardened Runtime, notarize via Apple, staple, Sparkle-sign, and package as
# release/*.dmg + a refreshed appcast.xml.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ SPARKLE SIGNING KEY — DO NOT REGENERATE                                    │
# │                                                                            │
# │ Updates are EdDSA-signed with the private key in the login keychain under  │
# │ account "HomePortManager" (used by sign_update below). Its public half is  │
# │ embedded in the app as SUPublicEDKey in App/project.yml:                   │
# │     17/yjpR7NupWnjCBmxugO7mIJUHLh+wenoHv3naew94=                           │
# │                                                                            │
# │ NEVER run `generate_keys` again or import a new key into this account, and │
# │ NEVER change SUPublicEDKey. Doing so makes every already-installed app     │
# │ reject all future auto-updates. A backup of the private key lives at       │
# │ ~/Secrets/homeport-manager-sparkle-key-backup.txt (2026-08-28) — move it   │
# │ into a password manager and keep it, it is the only recovery path.        │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Usage: ./Scripts/release.sh <version>          e.g. ./Scripts/release.sh 1.1.0
# Local dry run (no notarization, no Sparkle signing, no appcast):
#   SKIP_NOTARIZE=1 ./Scripts/release.sh 1.1.0
#
# Uses the Mac-wide setup (see ~/DevApps/CLAUDE.md): Developer ID certificate
# "Vincent LAURIAT (KFLACS69T9)" and the shared notarytool keychain profile
# "AppliMacVincentGithub".
#
# Publish order matters: `gh release create` FIRST (so the appcast's enclosure
# URL resolves), THEN commit and push appcast.xml. Reversed, Sparkle clients
# that poll in between hit a 404.

set -euo pipefail

VERSION="${1:?Usage: ./Scripts/release.sh <version>  (e.g. 1.1.0)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/App"
APP_NAME="HomePort Manager"
cd "$APP_DIR"

# 1. project.yml must carry the same version in all four places it is spelled out.
# `MARKETING_VERSION` (build setting) and `CFBundleShortVersionString` (Info.plist
# property) both hold the human version — historically only the first was checked,
# which let the guard pass green while the shipped Info.plist still reported the
# old version. `CURRENT_PROJECT_VERSION` and `CFBundleVersion` (the Sparkle-facing
# build number, a plain integer string) must also agree with EACH OTHER: xcodegen
# does not expand `$(CURRENT_PROJECT_VERSION)` inside `info.properties`, so nothing
# else catches one being bumped without the other. Sparkle compares
# `CFBundleVersion` — never the marketing string — so a stale value here makes
# every future release silently invisible to already-installed clients.
if ! grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml; then
  echo "✗ MARKETING_VERSION in App/project.yml does not match $VERSION" >&2
  grep "MARKETING_VERSION" project.yml | sed 's/^/    /' >&2
  exit 1
fi
if ! grep -q "CFBundleShortVersionString: \"$VERSION\"" project.yml; then
  echo "✗ CFBundleShortVersionString in App/project.yml does not match $VERSION" >&2
  grep "CFBundleShortVersionString" project.yml | sed 's/^/    /' >&2
  exit 1
fi
CURRENT_PROJECT_VERSION=$(grep "CURRENT_PROJECT_VERSION:" project.yml | sed -E 's/.*"([^"]+)".*/\1/')
CFBUNDLE_VERSION=$(grep "CFBundleVersion:" project.yml | sed -E 's/.*"([^"]+)".*/\1/')
if [ "$CURRENT_PROJECT_VERSION" != "$CFBUNDLE_VERSION" ]; then
  echo "✗ CURRENT_PROJECT_VERSION ($CURRENT_PROJECT_VERSION) != CFBundleVersion ($CFBUNDLE_VERSION) in App/project.yml — Sparkle reads the latter; bump both together." >&2
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

# Same shape of failure as AD-3 above: a project.yml that lost SUPublicEDKey would still
# build green and ship an app that rejects every future auto-update at the first check.
SU_PUBLIC_ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ -z "$SU_PUBLIC_ED_KEY" ]; then
  echo "✗ Info.plist lacks SUPublicEDKey — check App/project.yml" >&2
  exit 1
fi
if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "✗ Sparkle.framework did not land in $APP/Contents/Frameworks — check the Sparkle package dependency in App/project.yml" >&2
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

echo "→ Codesigning Sparkle.framework nested binaries (deepest first)"
SPARKLE_FW="$STAGING/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/B"
codesign_ts "$SPARKLE_VER/Autoupdate"
codesign_ts "$SPARKLE_VER/XPCServices/Downloader.xpc"
codesign_ts "$SPARKLE_VER/XPCServices/Installer.xpc"
codesign_ts "$SPARKLE_VER/Updater.app"
codesign_ts "$SPARKLE_FW"

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

# 6. Sign the DMG with the Sparkle EdDSA key and refresh appcast.xml so the in-app
# updater can serve this version. See the header banner: never regenerate this key.
SPARKLE_VERSION="2.9.1"
SPARKLE_TOOLS="$ROOT/.sparkle-tools"
if [ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]; then
  echo "→ Fetching Sparkle $SPARKLE_VERSION tools (one-time setup)"
  mkdir -p "$SPARKLE_TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$SPARKLE_TOOLS"
fi

echo "→ Signing $DMG with the Sparkle EdDSA key"
SPARKLE_SIG_LINE=$("$SPARKLE_TOOLS/bin/sign_update" --account "HomePortManager" "$DMG")

echo "→ Writing $ROOT/appcast.xml (sparkle:version=$CFBUNDLE_VERSION, shortVersionString=$VERSION)"
PUB_DATE=$(date -R)
cat > "$ROOT/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>HomePort Manager</title>
    <link>https://raw.githubusercontent.com/vincentlauriat/HomePortManager/main/appcast.xml</link>
    <description>HomePort Manager release feed</description>
    <language>en</language>
    <item>
      <title>v$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$CFBUNDLE_VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/vincentlauriat/HomePortManager/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/vincentlauriat/HomePortManager/releases/download/v$VERSION/HomePortManager-$VERSION.dmg"
        type="application/octet-stream"
        $SPARKLE_SIG_LINE />
    </item>
  </channel>
</rss>
APPCAST

echo ""
echo "✅ Built, signed, notarized, stapled and Sparkle-signed: $DMG ($(ls -lh "$DMG" | awk '{print $5}'))"
echo "✅ appcast.xml written for v$VERSION"
echo ""
echo "Publish in this order (reversed, Sparkle clients hit a 404 on the enclosure URL):"
echo "  1. gh release create v$VERSION $DMG --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md"
echo "  2. git add appcast.xml && git commit -m 'docs: appcast for v$VERSION' && git push"
