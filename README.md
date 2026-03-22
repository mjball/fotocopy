# Fotocopy

A small macOS app for importing photos and videos from SD cards and external drives.

## Features

- Imports JPG, HEIC, RAW (CR2/CR3/NEF/ARW/DNG/RAF/ORF/RW2), and video (MOV/MP4/M4V)
- Organizes files into `YYYY/MM/DD/` folders by EXIF date
- Preview scan with interactive type, camera model, and date range filters
- Skips duplicates by filename + size matching
- Imports from Apple Photos libraries (recovers original camera filenames)
- Copy or move mode (move auto-disabled for Photos libraries)
- Auto-open when source/destination volumes mount
- Eject source/destination after import
- Check for updates from the menu bar (Cmd+U)

## Install

Requires [GitHub CLI](https://cli.github.com/) (`brew install gh`).

```
gh release download --repo mjball/fotocopy --pattern install.sh --dir /tmp && bash /tmp/install.sh && rm /tmp/install.sh
```

This downloads the latest release, clears macOS quarantine, and moves it to `/Applications`.

Alternatively, download `Fotocopy.app.zip` from [Releases](https://github.com/mjball/fotocopy/releases), unzip, move to `/Applications`, and run:

```
xattr -cr /Applications/Fotocopy.app
```

## Build from source

Requires macOS 14+ and Swift 5.9+.

```
swift build
```

To build a release `.app` bundle:

```
./Scripts/build-release.sh
```

## Releasing

Requires [GitHub CLI](https://cli.github.com/) authenticated with repo access.

```
./Scripts/build-release.sh --release v1.0
```

This builds the app, generates the icon from `Resources/AppIcon.png`, stamps the version into the bundle, code-signs, zips, and creates a GitHub release with the zip and install script attached.

## Running tests

```
swift test
```
