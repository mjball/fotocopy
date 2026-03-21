#!/bin/bash
set -e

APP_NAME="Fotocopy"
REPO="mjball/fotocopy"
INSTALL_DIR="/Applications"

echo "Installing $APP_NAME..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading latest release..."
curl -sL "https://github.com/$REPO/releases/latest/download/$APP_NAME.app.zip" -o "$TMPDIR/$APP_NAME.app.zip"

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
echo "You can open it from Spotlight or run: open -a $APP_NAME"
