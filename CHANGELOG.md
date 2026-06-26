# Changelog

All notable changes to this project will be documented in this file.

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
