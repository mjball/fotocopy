# Fotocopy

A small macOS app for importing photos and videos from SD cards and external drives.

## Features

- Imports JPG, HEIC, RAW (CR2/CR3/NEF/ARW/DNG/RAF/ORF/RW2), and video (MOV/MP4/M4V)
- Organizes files into `YYYY/YYYY-MM-DD/` folders by EXIF date
- Preview scan shows new vs duplicate files before importing
- Skips duplicates by filename + size matching
- Copy or move mode
- Optional auto-open when a named volume mounts
- Eject source/destination on completion

## Install

```
curl -sL https://github.com/mjball/fotocopy/releases/latest/download/install.sh | bash
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
