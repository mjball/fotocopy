# Fotocopy architecture

Fotocopy is deliberately file-first. It has no managed photo catalog: a
destination's `YYYY/MM/DD` folders, `Keeps`/`Rejects` subfolders, and optional
destination manifest are the product's durable state. SwiftUI state is always
reconstructable from those folders after a rescan or relaunch.

## Feature map

| Area | Location | Responsibility |
| --- | --- | --- |
| Import | `Sources/Fotocopy/ContentView.swift`, `ImportViewModel.swift`, `ImportEngine.swift` | Source scan, preview, filtering, transfer, and duplicate detection. |
| Cull domain | `Sources/Fotocopy/Cull/Domain/` | Value types, burst grouping, navigation, and filesystem-derived decisions. |
| Cull application | `Sources/Fotocopy/Cull/Application/` plus `Cull/Presentation/CullWorkspaceView.swift` | Main-actor state coordination. The extracted library workflow and export-selection policy live in `Application`; the active review controller remains with its primary view until its tightly coupled review/inspection state can be split without risk. |
| Cull infrastructure | `Sources/Fotocopy/Cull/Infrastructure/` | ImageIO preview cache, Canon metadata reader, safe cull moves, and native JPEG conversion. |
| Cull presentation | `Sources/Fotocopy/Cull/Presentation/` | SwiftUI review, inspector, sidebar, and Organize views. No view may move, trash, or convert files directly. |
| Organize data | `Sources/Fotocopy/Cull/Organize/` | Library-wide decision/statistics scan and Trash plans. |
| Import manifest | `Sources/Fotocopy/DestinationManifest.swift` | SQLite-backed import identity/history. Treat it as data-integrity code. |

## Rules that protect user photos

1. **The filesystem is authoritative.** Never persist a second catalog of
   culling choices. Rebuild UI state from a scan when in doubt.
2. **Plan before mutation.** File-changing features create and validate a
   typed plan before applying it. A plan must reject collisions and paths
   outside the active date folder or configured library.
3. **Never overwrite or permanently delete a photo.** Cull moves are
   reversible; library cleanup uses Finder's Trash; export refuses an existing
   destination.
4. **Move photo packages together.** The companion-file definition lives in
   `CullApplyEngine.companionURLs`; reuse it for every Keep, Reject, undo, and
   Trash operation.
5. **Keep the manifest in sync with file moves.** A successful Cull move that
   is under a manifest root must record its relocation. Do not simplify this
   into a rescan-only approach: duplicate history intentionally survives later
   Finder deletion.
6. **Keep blocking disk and ImageIO work off the main actor.** Observable
   controllers own presentation state; engines do disk work in detached tasks
   and return typed results.
7. **UI supplies UI semantics.** Dialogs, keyboard/modifier interpretation,
   and Finder presentation live at the UI edge. Application policy receives
   explicit choices, so it can be tested without synthesizing AppKit events.

## How to make a change

- Add a new rule about photos, bursts, plans, navigation, or selection to
  `Cull/Domain` and test it directly.
- Add disk, metadata, image conversion, or cache behavior to
  `Cull/Infrastructure`; return data rather than mutating views.
- Add asynchronous workflow state to the relevant observable controller in
  `Cull/Application` (or the existing active-review controller), not to a
  SwiftUI view.
- Add controls and layout in `Cull/Presentation`; invoke application methods
  rather than reaching into `FileManager`, `Process`, or the manifest.
- Preserve the existing `plan`/`apply` test style for any operation that can
  alter user files. Add a regression test before changing a safety condition.

## Deliberate non-goals

The project remains one SwiftPM executable target for now. The directory and
controller boundaries make ownership explicit without turning an ongoing UI
refactor into a high-risk package-target migration. Split a new core target
only when a feature needs to be reused outside the macOS app.
