# StickSpace

Sticky snippets for the macOS menu bar: keep texts, links, commands and secrets in small floating glass windows, copy them in one click, open links without leaving your app.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/stacks-dark.png">
    <img alt="StickSpace spaces: groups with entities, an entity being edited, a pinned space" src="docs/readme/stacks-light.png">
  </picture>
</p>

## What it is

- **Entity**: one piece of text. **Group**: a named list of entities. **Space**: groups in one window, with its own always-visible header.
- Lives only in the menu bar (no Dock icon). Local-only: no account, no server, no network.
- Liquid Glass on macOS 26, standard materials on macOS 14 and 15. Light, dark or system theme.

## Features

- **Copy** any entity with one click (exact text, nothing added).
- **Links**: an entity that is a full http(s) address gets an open button. Click opens the browser; **⌘-click opens it in the background** and keeps StickSpace active. The arrow in a group's title opens all its visible links at once, de-duplicated.
- **Mask**: hide secrets on screen with `••••••••`; reveal temporarily with the eye; copy works without revealing. Masking is visual only, nothing is encrypted.
- **Pin** a space (the pin is in its header) to lock its window in place (pinned windows cannot be dragged away).
- **Double-click** a group's title to expand or collapse; double-click the space header to fold all groups. **Drag** to reorder groups and entities. Double-click an entity to edit it inline (Auto / Text / Link / Code).
- **Titles and tags**: an entity can have a title shown instead of a long text or link, and tags such as `prod`, `stg`, `dev` shown as coloured chips.
- **Right-click** the space header, a group or an entity for everything else: rename, hide/show, add groups, zoom, import/export, delete (⌘Z undoes).
- **Zoom per space**: ⌘+ / ⌘− / ⌘0.
- **Import / Export** as versioned JSON (paste to import; masked entities are excluded from export unless you opt in).
- Menu bar: New Space, Import, show/hide each space, theme switch, Restart, Quit.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/windows-dark.png">
    <img alt="Export and import windows" src="docs/readme/windows-light.png">
  </picture>
</p>

## Install

```
brew install --cask caskbrew/tap/stickspace
```

Or download `StickSpace-<version>.zip` from [Releases](https://github.com/caskbrew/StickSpace/releases), unzip and move `StickSpace.app` to `/Applications`.

The app is ad-hoc signed and **not notarized**. The Homebrew cask clears the quarantine flag for you; with a manual download, right-click the app and choose Open the first time (or run `xattr -dr com.apple.quarantine /Applications/StickSpace.app`).

Requires macOS 14 or later (universal binary: Apple silicon and Intel).

## Your data

Everything is stored in `~/Library/Application Support/Stickspace/state.json` (plain JSON). Delete it to start fresh.

## Build from source

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
xcodegen generate
xcodebuild -project Stickspace.xcodeproj -scheme Stickspace -configuration Release -derivedDataPath build build
open build/Build/Products/Release/StickSpace.app
```

A Debug build is a separate app, **StickSpace Dev** (bundle id `com.sgoroshko.stickspace.dev`, data in `~/Library/Application Support/Stickspace Dev/`), so it can run next to the installed one without touching its data.

Tests: `xcodebuild -project Stickspace.xcodeproj -scheme Stickspace -destination 'platform=macOS' test -derivedDataPath build`

## License

Apache License 2.0, see [LICENSE](LICENSE).
