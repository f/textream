#!/bin/bash
set -euo pipefail

SCHEME="Textream"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
ARCHIVE_ARM="$BUILD_DIR/Textream-arm64.xcarchive"
ARCHIVE_X86="$BUILD_DIR/Textream-x86_64.xcarchive"
APP_NAME="Textream.app"
OUTPUT_DIR="$BUILD_DIR/universal"
OUTPUT_APP="$OUTPUT_DIR/$APP_NAME"
DMG_NAME="Textream.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DEVELOPER_ID_ENTITLEMENTS="$PROJECT_DIR/Textream/Textream-DeveloperID.entitlements"

echo "🧹 Cleaning previous build…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "🔨 Building for Apple Silicon (arm64)…"
xcodebuild archive \
  -project "$PROJECT_DIR/Textream.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_ARM" \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -quiet

echo "🔨 Building for Intel (x86_64)…"
xcodebuild archive \
  -project "$PROJECT_DIR/Textream.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_X86" \
  -destination "generic/platform=macOS" \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -quiet

ARM_APP="$ARCHIVE_ARM/Products/Applications/$APP_NAME"
X86_APP="$ARCHIVE_X86/Products/Applications/$APP_NAME"

echo "🧬 Creating universal binary…"
cp -R "$ARM_APP" "$OUTPUT_APP"

has_both_architectures() {
  local architectures
  architectures=" $(lipo -archs "$1") "
  [[ "$architectures" == *" arm64 "* && "$architectures" == *" x86_64 "* ]]
}

# Find all Mach-O binaries and lipo them together
find "$ARM_APP" -type f | while read -r arm_file; do
  rel="${arm_file#$ARM_APP}"
  x86_file="$X86_APP$rel"
  out_file="$OUTPUT_APP$rel"

  if [ -f "$x86_file" ] && file "$arm_file" | grep -q "Mach-O"; then
    # Swift packages can embed prebuilt frameworks that are already universal.
    if has_both_architectures "$arm_file"; then
      continue
    fi
    lipo -create "$arm_file" "$x86_file" -output "$out_file"
    has_both_architectures "$out_file"
  fi
done

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  echo "🖋️  Signing universal app with Developer ID…"
  # Sign embedded code first so the app seals its final signatures.
  if [ -d "$OUTPUT_APP/Contents/Frameworks" ]; then
    while IFS= read -r -d '' code; do
      codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$code"
    done < <(find "$OUTPUT_APP/Contents/Frameworks" -depth \
      \( -type d -name '*.framework' -o -type f -name '*.dylib' \) -print0)
  fi
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --entitlements "$DEVELOPER_ID_ENTITLEMENTS" \
    "$OUTPUT_APP"

  codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
else
  echo "⚠️  SIGNING_IDENTITY is not set; creating an ad-hoc signed local build."
  codesign --force --sign - "$OUTPUT_APP"
fi

echo "📦 Creating DMG…"
rm -f "$DMG_PATH"

# Create a temporary DMG folder with the app and an Applications symlink
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$OUTPUT_APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "Textream" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" \
  -quiet

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  echo "🖋️  Signing DMG with Developer ID…"
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    --identifier dev.fka.textream.dmg \
    "$DMG_PATH"

  codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

rm -rf "$DMG_STAGING"

echo ""
echo "✅ Done!"
echo "   App:  $OUTPUT_APP"
echo "   DMG:  $DMG_PATH"
echo ""
lipo -info "$OUTPUT_APP/Contents/MacOS/Textream"
