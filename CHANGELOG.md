# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] — 2026-06-26

### What's new

- **RightLights** — move traffic light buttons to the right side of the window (Windows-style)
  - Order: `[zoom] [minimize] [close]` (close at top-right, like Windows)
  - Swizzles `NSThemeFrame._updateButtonPositions`, `_closeButtonOrigin`, `_zoomButtonOrigin`, `_titlebarTitleRect`, `_minXTitlebarButtonsWidth`, `_maxXTitlebarButtonsWidth`, `leftButtonGroupFrameInTitlebarView`, `NSTitlebarView.setFrameSize:`, `NSTitlebarView.layout`
  - Preserves system Y position (9px for 32px titlebar, 33px for 66px titlebar+toolbar) — only mirrors X
  - Window title moves to the left
  - Fullscreen-aware (skips repositioning in fullscreen)
  - Re-entrancy guard prevents layout loops

- **`mactweaks` TUI** — terminal control panel (ncurses) for both CornerFix and RightLights
  - Toggle Corner Fix on/off (live, via Darwin notifications)
  - Set corner radius (0–24 pt)
  - Toggle Right Lights on/off (live)
  - Per-app exclusions with scrollable app picker — no need to know bundle IDs
  - Lists all running GUI apps + installed apps from `/Applications` and `~/Applications`
  - Checkbox UI: `[x]` excluded, `[ ]` not excluded
  - Shows excluded app names in main menu

- **Sandbox-safe settings via notifyd** — RightLights uses `notify_set_state` / `notify_get_state` (IPC via notifyd daemon) instead of plist files, so sandboxed apps (Safari, TextEdit, Notes) can read settings
  - Encoding: global state 0=never set (default on), 1=enabled, 2=disabled; per-app state 0=never set (default not excluded), 1=not excluded, 2=excluded
  - Plist file written for persistence across reboots; synced to notifyd on TUI startup

- **Live toggle without restart** — all swizzles always installed; hooks check `RLShouldActivate()` on every call; Darwin notification triggers relayout of all existing windows

### Updated

- **Makefile** — builds CornerFix dylib + CLI + inject + test app + RightLights dylib + mactweaks TUI
- **LaunchAgent** — injects both `libcornerfix.dylib` and `librightlights.dylib` via `DYLD_INSERT_LIBRARIES` (colon-separated)

### Tested on

- macOS 26.5.1 Tahoe, x86_64, OpenCore + Lilu 1.7.3
- Finder, Safari (sandboxed, live toggle + exclusion verified), Brave, AyuGram, Terminal, TextEdit, OpenCode, Incy

## [1.0.0] — 2026-06-26

### What's new

- **Square corners (0pt) on macOS 26 Tahoe** — forces `_effectiveCornerRadius=0` across all apps
- **Full mode** for native macOS apps — swizzles `NSWindow` corner methods + walks view/layer hierarchy
- **Lite mode** for Qt/non-standard window chrome (AyuGram) — subclass swizzling without view hierarchy walking
- **Chromium support** (Brave, Chrome, Edge) — full mode with `amfi_get_out_of_my_way=1`
- **`_updateCornerMask` fix** — calls original method first (updates layout/margins), then overrides radius. Fixes blank strip at top when zooming/resizing windows.
- **Overlay caps disabled by default** — the overlay caused gray strip artifacts on Tahoe where `_setEffectiveCornerRadius:0` works correctly. Opt-in via `CFX_OVERLAY=1`.
- **Shadow retained at radius=0** — disabling shadow caused visual window boundary loss. Opt-out via `CFX_NO_SHADOW=1`.
- **`cornerfixctl` CLI** — live control of radius (0–24), per-app overrides, debug logging, presets, reload
- **LaunchAgent** for automatic injection at login
- **Safe dylib update procedure** documented — prevents `Code Signature Invalid` crashes

### Based on

- makalin/CornerFix — swizzle architecture, CLI, injection model
- m4rkw/macos-corner-fix — `NSThemeFrame` approach inspiration

### Tested on

- macOS 26.5.1 Tahoe, x86_64, OpenCore + Lilu 1.7.3
- Finder, Safari, Brave, AyuGram, Terminal, OpenCode, Incy
