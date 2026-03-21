# Fotocopy

A small macOS app for importing photos and videos from SD cards and external drives.

## Features

- Imports JPG, HEIC, RAW (CR2/CR3/NEF/ARW/DNG/RAF/ORF/RW2), and video (MOV/MP4/M4V)
- Organizes files into `YYYY/YYYY-MM-DD/` folders by EXIF date
- Skips duplicates using SHA-256 checksums
- Copy or move mode
- Optional auto-open when a named volume mounts
- Eject source/destination on completion

## Install

Download `Fotocopy.app.zip` from [Releases](https://github.com/mjball/fotocopy/releases), unzip, and move to `/Applications`.

Since the app isn't signed with an Apple Developer ID, macOS will block it on first launch. To fix this, run:

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
