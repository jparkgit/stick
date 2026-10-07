# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Stick is a native macOS sticky-notes app (SwiftUI + AppKit, no dependencies). It targets **macOS 26+ only** because it uses Liquid Glass (`.glassEffect`, `Glass`). Building requires macOS with Xcode Command Line Tools — it cannot be built or run on Linux. Project ethos (from README): native, minimal, local-first, lightweight.

## Commands

```bash
swift build                 # debug build
swift run StickyNotes       # run the bare executable (no .app bundle, no icon/Info.plist)
./scripts/build-app.sh      # release build → dist/Stick.app, dist/Stick.zip, dist/Stick.dmg
```

- There are no tests, linter, or formatter configured.
- `build-app.sh` writes `Info.plist` inline (bundle id `com.jvalaj.stick`, version, `LSUIElement`), ad-hoc codesigns, and builds a styled DMG via `hdiutil` + Finder AppleScript. Bump the version there (and in `packaging/homebrew/stick.rb`).
- The SwiftPM product/executable is `StickyNotes`; the script renames it to `Stick` inside the bundle.
- `dist/` is gitignored, but `dist/Stick.zip` and `dist/Stick.dmg` are force-tracked as download artifacts for the README. Rebuilding regenerates them; only commit them when intentionally publishing a new build.
- `install.sh` (the README's `curl | bash` installer) clones the repo, runs `build-app.sh`, and copies the app to `~/Applications`.

## Architecture

All app code lives in a single file, `Sources/StickyNotes/main.swift`, using top-level code (`NSApplication.shared` + `AppDelegate`, not `@main`/SwiftUI `App`). The UI is SwiftUI views hosted in hand-built `NSWindow` subclasses.

- **`StickerData` / `Store`** — notes persist as a JSON array at `~/Library/Application Support/StickyNotes/stickers.json`. `StickerData` has a custom `init(from:)` so new fields can be added with `decodeIfPresent` defaults without breaking existing files — follow that pattern for any new field.
- **`AppState`** (`ObservableObject`) — single source of truth shared by the dashboard and every sticker window. `upsert`/`remove` write to disk immediately. Appearance settings (glass variant, font size/color, background color/opacity) are `@Published` properties persisted to `UserDefaults` in `didSet`; colors are stored as sRGB `[Double]` arrays.
- **`AppDelegate`** — owns the `AppState`, the menu-bar status item, the dashboard, and `stickerWindows: [UUID: StickerWindow]`. It runs as an `.accessory` app (no Dock icon), so it installs its own main menu with an Edit menu — without it, Cmd-X/C/V/A don't reach `TextEditor`. Global `didMove`/`didResize` observers sync window frames back into `StickerData`. On app resign-active, unpinned stickers are sent behind other windows.
- **Close vs. delete** — the sticker's close button only orders the window out (the note stays in the store and reappears on next launch or when clicked in the dashboard); the dashboard's trash button deletes it.
- **`StickerWindow`** — a `.titled` + `.fullSizeContentView` window with hidden chrome, kept titled so system edge/corner resizing works. Dragging is done via `performDrag(with:)` from a SwiftUI `DragGesture` on the custom title bar. Pinning (`applyPinned`) toggles `.floating` level + `.canJoinAllSpaces`; the unpin path deliberately orders out and back to detach from fullscreen spaces. `isPinnedWindow` is derived from `level == .floating`.
- **`DashboardWindow`** — borderless, movable-by-background window listing notes plus the `SettingsPanel` (appearance) and the storage path (click reveals in Finder).
- **Liquid Glass workarounds** — both window classes override `isMainWindow` to `true`, and `FirstMouseHostingView` / `installActiveBlurFix` walk the view tree forcing `NSVisualEffectView.state = .active`, so glass doesn't render in its inactive/desaturated style when another app is focused. `FirstMouseHostingView.acceptsFirstMouse` lets a sticker be dragged on the first click without activating it first. Keep these in place when changing window code.

## Workflow preferences

- Never create a new git branch unless the user explicitly asks for one. Commit and push on the current branch.
