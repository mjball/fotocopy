#!/bin/bash
set -e

APP_NAME="Fotocopy"
REPO="mjball/fotocopy"
INSTALL_DIR="/Applications"

if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is required (brew install gh)"
    exit 1
fi

echo "Installing $APP_NAME..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading latest release..."
gh release download --repo "$REPO" --pattern "$APP_NAME.app.zip" --dir "$TMPDIR"

echo "Extracting..."
unzip -q "$TMPDIR/$APP_NAME.app.zip" -d "$TMPDIR"

echo "Clearing quarantine..."
xattr -cr "$TMPDIR/$APP_NAME.app"

if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "Removing existing $APP_NAME from $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

echo "Moving to $INSTALL_DIR..."
mv "$TMPDIR/$APP_NAME.app" "$INSTALL_DIR/"

echo ""
echo "Done! $APP_NAME is installed at $INSTALL_DIR/$APP_NAME.app"
open -a "$APP_NAME"
