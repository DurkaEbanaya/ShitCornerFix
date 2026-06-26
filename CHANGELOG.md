# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] — 2026-06-27

### What's new

- **Fullscreen support** — buttons now appear on the right side in fullscreen mode:
  - Listens for `NSWindowDidEnterFullScreenNotification` / `NSWindowDidExitFullScreenNotification`
  - Cascading delayed reposition (0.3s, 0.7s, 1.5s, 3.0s) catches the titlebar view after the fullscreen transition animation settles
  - Works in both Win10 mode (WLButtons) and classic mode (repositioned original buttons)
  - No fullscreen skip anywhere — all 4 `NSWindowStyleMaskFullScreen` guards removed

### Fixed

- **Win10 buttons in fullscreen** — system un-hides original buttons on hover; we now re-hide them on every layout pass to prevent them appearing at the left position
- **Classic buttons in fullscreen** — original buttons repositioned to right when titlebar slides in on hover

### How it works

In macOS fullscreen, the titlebar is hidden by sliding the `_titlebarContainerView` up by 32px (y=-32), not by setting `hidden=YES`. The `NSTitlebarView` is still accessible with correct width (= screen width). When the user hovers at the top edge, the system slides the container back to y=0 and un-hides the buttons. Our swizzled layout methods catch this and reposition buttons to the right.

## [1.2.0] — 2026-06-27

### What's new

- **Win10-style buttons** — flat rectangular buttons with Windows 10 look:
  - Order: `[minimize] [maximize] [close]` (close at top-right, Windows-style)
  - Symbols: `—` (minimize), `□` (maximize), `✕` (close)
  - Hover: gray background for min/max, red `#E81123` + white symbol for close
  - Dark mode: white symbols on dark background
  - Pressed state with drag-outside cancellation
  - Size: 46×32px (titlebar height), no rounded corners
  - Toggle via `mactweaks` TUI or `notifyutil -s com.local.rightlights.win10 1`

- **Layout spacing fix (Bug 2)** — toolbar items, accessory views, and decorations no longer overlap buttons:
  - Swizzles `_toolbarLeadingSpace` → 0, `_toolbarTrailingSpace` → button group width
  - Swizzles `_minXTitlebarWidgetInset` → 0, `_maxXTitlebarWidgetInset` → button inset
  - Swizzles `_minXTitlebarDragWidth` → 0, `_maxXTitlebarDragWidth` → button group width
  - Swizzles `_minXTitlebarDecorationMinWidth` → 0, `_maxXTitlebarDecorationMinWidth` → button group width
  - Swizzles `_minXInsetForAccessoryViews` → 0
  - System now reserves space on the right for buttons, preventing overlaps in Safari, Finder, Calculator, Notes, Photos

- **Zoom/maximize button position fix (Bug 1)** — buttons now reach the right edge after zoom:
  - Uses `window.frame.size.width` as source of truth instead of stale `titlebarView.bounds.size.width`
  - Expands `titlebarView.bounds` if it lags behind window frame during resize
  - Cascading delayed reposition (50ms + 150ms) catches post-zoom layout passes
  - Removed re-entrancy guard that was blocking the final (correct) reposition call

### Fixed

- **OBS crash** — `com.obsproject.obs-studio` added to CornerFix lite-mode (Qt app, was crashing on view-hierarchy walking in full mode)

### Updated

- **mactweaks TUI** — Win10 Style toggle in Right Lights section
- **18 swizzles total** in RightLights (was 8 in v1.1)
- All swizzles always installed — live toggle without restart

### Tested on

- macOS 26.5.1 Tahoe, x86_64, OpenCore + Lilu 1.7.3
- Finder, Safari (sandboxed), Brave, AyuGram, Terminal, TextEdit, Notes, Calculator, OBS, OpenCode, Incy

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
