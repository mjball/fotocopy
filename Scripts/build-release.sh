#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Fotocopy"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
APP_ZIP="$PROJECT_DIR/$APP_NAME.app.zip"

if [ "$1" = "--release" ]; then
    if [ -z "$2" ]; then
        echo "Usage: ./build-release.sh --release <version>"
        echo "Example: ./build-release.sh --release v1.0"
        exit 1
    fi
    VERSION="$2"
    VERSION_NUMBER="${VERSION#v}"
fi

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
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || echo "Warning: No AppIcon.icns found, skipping icon"

if [ -n "$VERSION_NUMBER" ]; then
    echo "Stamping version $VERSION_NUMBER into app bundle..."
    BUNDLE_PLIST="$APP_BUNDLE/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION_NUMBER" "$BUNDLE_PLIST"
    plutil -replace CFBundleVersion -string "$VERSION_NUMBER" "$BUNDLE_PLIST"
fi

echo "Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Creating zip..."
rm -f "$APP_ZIP"
cd "$PROJECT_DIR"
zip -r "$APP_ZIP" "$APP_NAME.app"

echo ""
echo "Done! Created: $APP_BUNDLE"
echo "         Zip: $APP_ZIP"

if [ -n "$VERSION" ]; then
    echo ""
    echo "Creating GitHub release $VERSION..."
    gh release create "$VERSION" "$APP_ZIP" --title "$APP_NAME $VERSION" --notes "Release $VERSION"
    echo "Done! Release published at: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$VERSION"
else
    echo ""
    echo "To create a GitHub release, run:"
    echo "  ./Scripts/build-release.sh --release v1.0"
fi
