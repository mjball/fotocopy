#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Fotocopy"

if [ "$1" = "--release" ]; then
    if [ -z "$2" ]; then
        echo "Usage: ./build-release.sh --release <version>"
        echo "Example: ./build-release.sh --release v1.0"
        exit 1
    fi
    VERSION="$2"
    VERSION_NUMBER="${VERSION#v}"
fi

# Build artifacts exist only long enough to be signed, packaged, and (for a
# release) uploaded. Keeping them out of the checkout makes /Applications the
# one installed-copy location and prevents large, stale bundles from lingering
# beside the source tree.
RELEASE_STAGING_DIR="$(mktemp -d -t fotocopy-release)"
trap 'rm -rf "$RELEASE_STAGING_DIR"' EXIT
APP_BUNDLE="$RELEASE_STAGING_DIR/$APP_NAME.app"
APP_ZIP="$RELEASE_STAGING_DIR/$APP_NAME.app.zip"

echo "Building $APP_NAME..."

cd "$PROJECT_DIR"
rm -rf .build
swift build -c release

echo "Creating app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

ICON_PNG="$PROJECT_DIR/Resources/AppIcon.png"
if [ -f "$ICON_PNG" ]; then
    echo "Generating app icon..."
    ICONSET="$RELEASE_STAGING_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for SIZE in 16 32 128 256 512; do
        sips -z $SIZE $SIZE "$ICON_PNG" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null 2>&1
        DOUBLE=$((SIZE * 2))
        sips -z $DOUBLE $DOUBLE "$ICON_PNG" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || echo "Warning: No icon found, skipping"
fi

if [ -n "$VERSION_NUMBER" ]; then
    echo "Stamping version $VERSION_NUMBER into app bundle..."
    BUNDLE_PLIST="$APP_BUNDLE/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION_NUMBER" "$BUNDLE_PLIST"
    plutil -replace CFBundleVersion -string "$VERSION_NUMBER" "$BUNDLE_PLIST"
fi

echo "Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Creating zip..."
cd "$RELEASE_STAGING_DIR"
zip -r "$APP_ZIP" "$APP_NAME.app"

echo ""
echo "Temporary release bundle and zip are ready for verification or publishing."

if [ -n "$VERSION" ]; then
    echo ""
    echo "Creating GitHub release $VERSION..."
    INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
    RELEASE_NOTES="$(cat <<NOTES
## Install

Requires [GitHub CLI](https://cli.github.com/) (\`brew install gh\`).

\`\`\`
gh release download --repo mjball/fotocopy --pattern install.sh --dir /tmp && bash /tmp/install.sh && rm /tmp/install.sh
\`\`\`

Or download \`$APP_NAME.app.zip\`, unzip, and run:
\`\`\`
xattr -cr /Applications/$APP_NAME.app
\`\`\`
NOTES
)"
    gh release create "$VERSION" "$APP_ZIP" "$INSTALL_SCRIPT" --title "$APP_NAME $VERSION" --notes "$RELEASE_NOTES"
    echo "Done! Release published at: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$VERSION"
else
    echo ""
    echo "Temporary artifacts will be removed when this script exits."
    echo "To create a GitHub release, run:"
    echo "  ./Scripts/build-release.sh --release v1.0"
fi
