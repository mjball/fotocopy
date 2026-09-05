# Fotocopy

Fotocopy is a file-first macOS app for importing, culling, and organizing photos on ordinary drives. It copies media directly into a simple date-based folder hierarchy, helps you review Canon CR3 bursts, and records your choices by moving files into normal `Keeps` and `Rejects` folders—not a proprietary photo library.

Your photos stay portable: browse them in Finder, edit them in the tools you already use, and move them without an export step. Fotocopy assists with fast review and safe file operations, but it never chooses what to keep or permanently deletes an image for you.

## Features

### Import into ordinary folders

- Imports JPG, HEIC, RAW (`CR2`/`CR3`/`NEF`/`ARW`/`DNG`/`RAF`/`ORF`/`RW2`), and video (`MOV`/`MP4`/`M4V`) from cards, external drives, and Apple Photos libraries.
- Organizes imports into `YYYY/MM/DD/` folders using the capture date, while retaining original camera filenames.
- Previews an import before copying, with file-type, camera-model, and date-range filters.
- Supports copy or move imports; move is deliberately unavailable for Apple Photos libraries.
- Uses a destination manifest to identify prior imports conservatively—even when cameras reuse filenames—and reconciles later Finder moves within a date folder.
- Can open and eject source or destination volumes as part of the import flow.

### Cull Canon CR3 bursts quickly

- Scans a chosen date folder and its `Keeps`/`Rejects` subfolders to rebuild conservative consecutive-capture bursts from the files on disk.
- Displays fast embedded JPEG previews, with full-resolution preview loading when you zoom; pinch, double-click, and pan directly in the main viewer. The Frames filmstrip and active detail-crop strip follow the selected frame during keyboard navigation.
- Offers Full, Compact, and Minimal review layouts, plus a filmstrip, per-frame Keep/Reject badges, and filesystem-derived burst status: no icon before a decision, an outlined green check after a keep or outlined red X after rejects only while review is in progress, then a filled green check when the finished burst has a keeper or a filled red X when every frame is rejected.
- Reads supported Canon AF metadata and can overlay the camera-recorded AF target or use it as the detail-comparison point. When a selected frame records an active target, Fotocopy automatically activates the matching crop comparison while preserving a manual point if you chose one.
- Provides keyboard-driven review: arrow keys navigate frames and bursts, keeping the selected burst visible in the sidebar; `⌘[`/`⌘]` move to the previous or next date folder with CR3s; `K`/`X` keep or reject the current frame; `⇧K` keeps the current frame and rejects the rest; `⇧X` rejects the burst. The same actions are available in the native **Cull** menu.
- Applies choices immediately by moving the CR3 and its paired XMP/ON1 sidecars into `Keeps` or `Rejects`. The latest move can be undone, and a later scan or relaunch restores the decision badges from the folder structure.

### Review and clean up a whole library

- The Organize task scans the configured import destination for `YYYY/MM/DD/Keeps` and `Rejects` folders—there is no separate catalog to maintain.
- Browse kept and rejected photos in a date-grouped thumbnail grid; filter by decision, date, or filename; reveal a photo in Finder or reopen its day in Cull.
- Recheck and move all rejected photo packages to Finder’s Trash in one confirmed action. Fotocopy never permanently deletes them; restore through Finder’s Trash if needed.

### Native macOS workflow

- Keeps files visible and usable in Finder and other photo software at every stage.
- Shows a quiet, live toolbar temperature readout for connected external SSDs, using macOS-provided SMART data without a password prompt.
- Includes a standard menu bar with discoverable commands and shortcuts, persistent cull preferences, and built-in update checks.

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

To verify a release build without retaining an extra `.app` bundle:

```
./Scripts/build-release.sh
```

The bundle and ZIP are staged only in a temporary directory and removed when
the script finishes. `/Applications/Fotocopy.app` is the authoritative local
installation; use the install instructions above after publishing a release.

## Releasing

Requires [GitHub CLI](https://cli.github.com/) authenticated with repo access.

```
./Scripts/build-release.sh --release v1.0
```

This builds the app, generates the icon from `Resources/AppIcon.png`, stages and signs the bundle, then uploads the ZIP and install script to GitHub. The temporary release artifacts are removed when the command finishes, leaving `/Applications/Fotocopy.app` as the only retained app bundle.

## Running tests

```
swift test
```
