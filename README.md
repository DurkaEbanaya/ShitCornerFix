# ShitCornerFix

**Square window corners + right-side traffic lights on macOS 26 Tahoe. No more rounded bullshit.**

Two dylibs, one TUI:

1. **CornerFix** (`libcornerfix.dylib`) — forces window corner radius to **0pt** (fully square)
2. **RightLights** (`librightlights.dylib`) — moves traffic light buttons to the **right** side of the window (Windows-style): `[zoom] [minimize] [close]`
3. **mactweaks** (TUI) — terminal control panel to toggle both features on/off, set radius, and manage per-app exclusions — all live, without restarting apps

macOS 26 (Tahoe) cranked window corner radius from 10pt (Sequoia) to 16pt. This project forces it back to **0pt** — fully square — across all applications, including Safari, Finder, Brave, and Qt apps. It also moves the traffic light buttons (close/minimize/zoom) from the left to the right side of the titlebar, like Windows.

## Features

### Corner Fix — square corners

`libcornerfix.dylib` is injected into every GUI application via `DYLD_INSERT_LIBRARIES`. At load time it swizzles private `NSWindow` / `NSThemeFrame` methods that control corner rendering:

| Method | Purpose |
|---|---|
| `_effectiveCornerRadius` | The actual radius the SkyLight compositor reads (macOS 15+). Forced to 0. |
| `_cornerRadius` / `_topCornerRadius` / `_bottomCornerRadius` | Legacy getters. Forced to 0. |
| `_setEffectiveCornerRadius:` / `_setCornerRadius:` | Setters intercepted, always 0. |
| `_cornerMask` | The `NSImage` mask the compositor uses for the window silhouette. Replaced with a square mask. |
| `_updateCornerMask` | Called first (updates layout/margins), then radius is overridden to 0. |

In **full mode** (default), it also walks the view/layer hierarchy (`CUIWindowFrameLayer`, `CABackdropLayer`, `CAPortalLayer`, `CAChameleonLayer`) setting `cornerRadius=0` on each.

In **lite mode** (Qt apps like AyuGram), it skips view-hierarchy walking (which crashes on non-standard window chrome) and instead swizzles corner methods on the **actual runtime subclass** of each window, plus applies private setters directly.

## Two Operating Modes

### Full Mode (default)

All native macOS apps: Finder, Safari, TextEdit, Terminal, Xcode, Incy, OpenCode, etc.

- Swizzles all corner methods on `[NSWindow class]`
- Walks view/layer hierarchy to set `cornerRadius=0` on every chrome layer
- Hooks `makeKeyAndOrderFront:`, `orderFront:`, `setFrame:display:`, `setStyleMask:` to re-apply on window events
- Overlay caps **disabled** by default (opt-in via `CFX_OVERLAY=1`)
- Shadow **kept enabled** at radius=0 (opt-out via `CFX_NO_SHADOW=1`)

### Lite Mode (Qt / non-standard window chrome)

Apps: AyuGram, other Qt-based apps.

Automatically activated based on bundle ID. Lite mode:
- Swizzles corner getters/setters on `[NSWindow class]`
- Detects the **actual runtime subclass** of each window and swizzles its overridden methods via `method_setImplementation`
- Applies private setters (`_setEffectiveCornerRadius:0`, KVC `cornerRadius=0`) directly on window instances
- **Does NOT** walk view/layer hierarchy (this is what crashed Qt apps)
- **Does NOT** install notification observers or overlay views

To add an app to lite mode, edit `CFXLiteModeBundleIDs()` in `src/sharpener/CornerFixSharpener.m`.

### Right Lights — traffic lights on the right

`librightlights.dylib` moves the close/minimize/zoom buttons from the left to the right side of the titlebar, Windows-style.

**Order (left to right in right group):** `[zoom] [minimize] [close]` — close at the top-right corner.

Swizzled methods:

| Method | Class | Purpose |
|---|---|---|
| `_updateButtonPositions` | NSThemeFrame | Main button layout — repositions after original |
| `layout` | NSThemeFrame | General layout — repositions after original |
| `_titlebarTitleRect` | NSThemeFrame | Window title — moved to left |
| `_minXTitlebarButtonsWidth` | NSThemeFrame | Left button zone → 0 |
| `_maxXTitlebarButtonsWidth` | NSThemeFrame | Right button zone → 69px |
| `leftButtonGroupFrameInTitlebarView` | NSThemeFrame | Hit-test/hover zone → right-aligned |
| `setFrameSize:` | NSTitlebarView | Repositions on resize |
| `layout` | NSTitlebarView | Repositions on titlebar layout |

Key design decisions:
- **Y preserved** — system computes Y differently for toolbar (y=33) vs non-toolbar (y=9) windows; only X is mirrored
- **Fullscreen-aware** — skips repositioning when window is fullscreen
- **Re-entrancy guard** — prevents layout loops from `setFrameOrigin:` triggering `layout`
- **Always-installed swizzles** — hooks check `RLShouldActivate()` on every call, enabling live toggle

### mactweaks — Terminal Control Panel

```
mactweaks
```

ncurses TUI for controlling both CornerFix and RightLights:

```
┌─ MacTweaks Control Panel ──────────────────────────┐
│                                                     │
│  Corner Fix                              [ON]       │
│    Radius                                0 pt       │
│    Excluded Apps                         (0)        │
│                                                     │
│  Right Lights                            [ON]       │
│    Excluded Apps                         (0)        │
│                                                     │
│  Quit                                               │
│                                                     │
│  ^/v Navigate  Space Toggle  Enter Edit  q Quit     │
└─────────────────────────────────────────────────────┘
```

| Key | Action |
|---|---|
| `↑/↓` or `j/k` | Navigate |
| `Space` | Toggle on/off |
| `Enter` | Edit (radius, open exclusions picker) |
| `Space` in picker | Add/remove app from exclusions |
| `PageUp/PageDown` | Scroll app list |
| `q` / `Esc` | Quit / back |

The exclusions picker shows all running GUI apps + installed apps from `/Applications` and `~/Applications` with checkboxes — no need to know bundle IDs.

### Sandbox-safe settings (notifyd)

Safari, TextEdit, Notes and other sandboxed apps cannot read files in `~/Library/Application Support/`. RightLights uses `notify_set_state` / `notify_get_state` (IPC via the notifyd daemon) to communicate settings to sandboxed apps. This works because notifyd is a system daemon that mediates communication — no file access needed.

**Encoding:**
- Global: `com.local.rightlights.global` — state 0=never set (default on), 1=enabled, 2=disabled
- Per-app: `com.local.rightlights.app.<bundleID>` — state 0=never set (default not excluded), 1=not excluded, 2=excluded
- Reload: `com.local.rightlights.reload` — posted after any change; all running apps re-read state and relayout

A plist file (`~/Library/Application Support/MacTweaks/rightlights.plist`) is also written for persistence across reboots. The TUI syncs plist → notifyd on startup.

## Requirements

| Requirement | Why | How to check |
|---|---|---|
| **macOS 26 Tahoe** | This targets Tahoe's 16pt radius and its private API layout | `sw_vers` → 26.x |
| **SIP disabled** (Filesystem Protections) | Needed to write to `/usr/local/lib` and for `DYLD_INSERT_LIBRARIES` to work on system apps | `csrutil status` |
| **Authenticated Root disabled** | Needed if you also want to modify system `.car` assets (optional, not required for dylib approach) | `csrutil authenticated-root` |
| **AMFI disabled** (`amfi_get_out_of_my_way=1`) | Needed for `DYLD_INSERT_LIBRARIES` to work on hardened-runtime / library-validation apps (Safari, Brave, Finder, Dock, etc.) | `nvram boot-args` |
| **Xcode Command Line Tools** | To compile the dylib | `clang --version` |

### Disabling AMFI (OpenCore)

Add `amfi_get_out_of_my_way=1` to `boot-args` in your OpenCore `config.plist`:

```
NVRAM → Add → 7C436110-AB2A-4BBB-A880-FE41995C9F82 → boot-args
```

Example:
```
-lilubetaall -amfipassbeta agdpmod=pikera ... amfi_get_out_of_my_way=1
```

Reboot for it to take effect.

> **Warning:** `amfi_get_out_of_my_way=1` fully disables Apple Mobile File Integrity. This reduces system security — any process can be injected into. On a hackintosh this is typically acceptable, but be aware of the trade-off.

### Disabling SIP (Recovery Mode)

```bash
# Boot into Recovery (Cmd+R on Intel)
csrutil disable
csrutil authenticated-root disable
# Reboot
```

## Installation

### 1. Build

```bash
git clone https://github.com/DurkaEbanaya/ShitCornerFix.git
cd ShitCornerFix
make all
```

Artifacts in `build/`:
- `libcornerfix.dylib` — square corners dylib
- `cornerfixctl` — CLI for live corner radius control
- `cornerfix-inject` — CLI for per-app injection
- `CornerFixTestApp.app` — test app
- `librightlights.dylib` — right-side traffic lights dylib
- `mactweaks` — terminal UI control panel

### 2. Sign and install

```bash
codesign -f -s - build/libcornerfix.dylib
codesign -f -s - build/librightlights.dylib
codesign -f -s - build/mactweaks
codesign -f -s - build/cornerfixctl
codesign -f -s - build/cornerfix-inject

cp build/libcornerfix.dylib /usr/local/lib/libcornerfix.dylib
cp build/librightlights.dylib /usr/local/lib/librightlights.dylib
cp build/cornerfixctl /usr/local/bin/cornerfixctl
cp build/cornerfix-inject /usr/local/bin/cornerfix-inject
cp build/mactweaks /usr/local/bin/mactweaks
```

### 3. Create LaunchAgent (auto-injection at login)

```bash
cat > ~/Library/LaunchAgents/com.local.shitcornerfix.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.shitcornerfix</string>
  <key>ProgramArguments</key>
  <array>
    <string>launchctl</string>
    <string>setenv</string>
    <string>DYLD_INSERT_LIBRARIES</string>
    <string>/usr/local/lib/libcornerfix.dylib:/usr/local/lib/librightlights.dylib</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.local.shitcornerfix.plist
```

### 4. Activate in current session

```bash
launchctl setenv DYLD_INSERT_LIBRARIES /usr/local/lib/libcornerfix.dylib:/usr/local/lib/librightlights.dylib
```

### 5. Restart running apps

```bash
killall Finder
killall Dock
```

New windows will have square corners and right-side traffic lights. Apps launched after this point will automatically get both dylibs.

## Live Control (cornerfixctl)

```bash
cornerfixctl                  # show current state
cornerfixctl --status         # same
cornerfixctl on               # enable globally
cornerfixctl off              # disable globally
cornerfixctl --radius 0       # square (default)
cornerfixctl --radius 10      # Sequoia-style
cornerfixctl --radius 16      # Tahoe default
cornerfixctl --app com.apple.Safari --radius 4   # per-app override
cornerfixctl --app com.apple.Safari off          # disable for one app
cornerfixctl debug-on         # enable debug logging (/tmp/CornerFix.debug.log)
cornerfixctl debug-off        # disable debug logging
cornerfixctl list             # show all settings + per-app overrides
cornerfixctl reset            # reset everything to defaults
cornerfixctl reload           # broadcast live reload (no restart needed)
```

## Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `CFX_OVERLAY` | `0` | Set to `1` to enable corner overlay caps (may cause gray strip artifacts on Tahoe) |
| `CFX_NO_SHADOW` | `0` | Set to `1` to disable window shadow at radius=0 |
| `CFX_HARD_EDGE_CAP` | `12` | Overlay cap size in points (only if `CFX_OVERLAY=1`) |
| `CFX_DEBUG` | `0` | Set to `1` to force-enable debug logging |
| `CFX_DEBUG_LOG_PATH` | `/tmp/CornerFix.debug.log` | Custom debug log path |
| `CFX_EXTERNAL_OVERLAY` | `0` | Set to `1` to draw external corner caps outside the window silhouette |
| `CFX_SETTINGS_PATH` | (auto) | Custom settings plist path (for sandboxed apps) |

## Limitations

1. **Sandboxed apps** (TextEdit, Notes, Mail) cannot read the settings plist due to sandbox restrictions. They still get square corners (defaults are `enabled=true, radius=0`), but per-app overrides and debug logging won't work without setting `CFX_SETTINGS_PATH` to a sandbox-accessible location.

2. **System updates** may update AppKit and change private method signatures. If corners stop being square after an update, rebuild from source — the swizzle code checks for method existence at runtime and skips missing methods gracefully.

3. **Full-mode view hierarchy walking** may crash apps with highly custom window chrome (Qt, some Electron apps). These should be added to `CFXLiteModeBundleIDs()` in the source.

4. **`amfi_get_out_of_my_way=1`** fully disables AMFI. There is no way to selectively allow `DYLD_INSERT_LIBRARIES` on hardened-runtime apps without it (a Lilu kext plugin could achieve this, but that's future work).

5. **APFS snapshots**: If you also modify system `.car` assets (Aqua.car / DarkAqua.car), every system update recreates the snapshot and reverts the changes. The dylib approach is not affected by this.

6. **Not tested on Apple Silicon**: The dylib is built for x86_64. For Apple Silicon, add `-arch arm64e` to the clang command in the Makefile. The swizzle code is arch-agnostic.

7. **Brave / Chromium**: Work in full mode with `amfi_get_out_of_my_way=1`. Without it, they crash with `SIGKILL (Code Signature Invalid)` at dyld load time — before our code even runs.

## How to Update the Dylib Safely

**Never** `rm` + `cp` over a loaded dylib. This causes every new process to crash with `Code Signature Invalid` because the file inode changes while the old dylib is still mapped in memory.

### Correct procedure:

```bash
# 1. Unload and unset
launchctl unload ~/Library/LaunchAgents/com.local.shitcornerfix.plist
launchctl unsetenv DYLD_INSERT_LIBRARIES

# 2. Restart UI apps (unloads old dylib from memory)
killall Finder Dock SystemUIServer

# 3. Install new dylib with fresh inode
codesign -f -s - build/libcornerfix.dylib
cp build/libcornerfix.dylib /usr/local/lib/libcornerfix.dylib.new
codesign -f -s - /usr/local/lib/libcornerfix.dylib.new
mv /usr/local/lib/libcornerfix.dylib.new /usr/local/lib/libcornerfix.dylib

# 4. Reload
launchctl load ~/Library/LaunchAgents/com.local.shitcornerfix.plist
launchctl setenv DYLD_INSERT_LIBRARIES /usr/local/lib/libcornerfix.dylib

# 5. Restart apps
killall Finder Dock
```

## Recovery / Uninstall

### Quick disable (no reboot)

```bash
launchctl unload ~/Library/LaunchAgents/com.local.shitcornerfix.plist
launchctl unsetenv DYLD_INSERT_LIBRARIES
killall Finder Dock
```

### Full uninstall

```bash
# 1. Remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.local.shitcornerfix.plist
rm ~/Library/LaunchAgents/com.local.shitcornerfix.plist

# 2. Remove env var
launchctl unsetenv DYLD_INSERT_LIBRARIES

# 3. Remove files
rm /usr/local/lib/libcornerfix.dylib
rm /usr/local/bin/cornerfixctl
rm /usr/local/bin/cornerfix-inject

# 4. Remove settings
rm -rf ~/Library/Application\ Support/CornerFix

# 5. Restart UI
killall Finder Dock

# 6. (Optional) Remove amfi_get_out_of_my_way=1 from boot-args
#    Edit your OpenCore config.plist and remove it from NVRAM → boot-args
#    Then reboot.
```

### Emergency recovery (if everything crashes)

If you accidentally delete the dylib while `DYLD_INSERT_LIBRARIES` is set, **every new process will crash**. Symptoms: Finder/Dock won't start, Terminal crashes, nothing works.

**Fix:**
1. Force reboot (hold power button)
2. Boot into Recovery Mode (Cmd+R on Intel)
3. Open Terminal
4. Run:
```bash
# Mount the data volume
mkdir -p /Volumes/Data
mount -t apfs /dev/disk3s1 /Volumes/Data  # adjust disk number

# Remove the LaunchAgent
rm /Volumes/Data/Users/<your-user>/Library/LaunchAgents/com.local.shitcornerfix.plist

# Or just restore the dylib
cp <backup>/libcornerfix.dylib /Volumes/Data/usr/local/lib/libcornerfix.dylib
```
5. Reboot normally

### If Finder/Dock won't start but Terminal works

```bash
launchctl unsetenv DYLD_INSERT_LIBRARIES
killall Finder Dock
```

## How It Works (Technical)

### The corner rendering pipeline in macOS 26

1. `NSWindow` stores `_effectiveCornerRadius` (CGFloat) — this is what the compositor reads
2. `_cornerMask` returns an `NSImage` used as the window silhouette mask
3. `_updateCornerMask` is called when the window is created/resized — it regenerates the mask
4. SkyLight's Metal shaders (`SkyLightShaders.air64.metallib`) take `_corner_radius` as a function constant and have specializations for `is_radius_eq_0` through `is_radius_eq_112`
5. The compositor clips window content to the corner mask shape

### What ShitCornerFix does

1. **Swizzles** `_effectiveCornerRadius` getter → always returns `0.0`
2. **Swizzles** `_cornerMask` getter → returns a square `NSImage` (solid black rectangle, no rounding)
3. **Swizzles** `_updateCornerMask` → calls original (updates layout) then forces radius=0
4. **Swizzles** all setter variants → always pass `0.0`
5. **Walks** the view/layer hierarchy in full mode → sets `cornerRadius=0` on `CUIWindowFrameLayer`, `CABackdropLayer`, `CAPortalLayer`, `CAChameleonLayer`
6. **Keeps** shadow enabled (disabling it caused blank strip artifacts when zooming)
7. **Disables** overlay caps by default (they caused gray strip artifacts on Tahoe where `_setEffectiveCornerRadius:0` works correctly)

### Lite mode subclass swizzling

Qt (AyuGram) and some Electron apps use custom `NSWindow` subclasses that override `_cornerMask` / `_effectiveCornerRadius`. Swizzling on `[NSWindow class]` doesn't affect these overrides. Lite mode:

1. Hooks `makeKeyAndOrderFront:` / `orderFront:` / `orderFrontRegardless:`
2. When a window appears, calls `CFXSwizzleCornerMethodsOnClass([window class])`
3. This checks if the subclass has its own IMP for each corner method (different from NSWindow's)
4. If yes, `method_setImplementation` replaces the subclass's IMP with ours
5. Also applies private setters directly on the window instance

This avoids the view-hierarchy walking that crashed Qt apps, while still overriding the compositor's corner radius source.

## Credits

- **makalin/CornerFix** — the original project this is forked from. The swizzle architecture, CLI, and injection model are all theirs.
- **m4rkw/macos-corner-fix** — the `NSThemeFrame` swizzle approach that inspired the simpler fallback dylib.
- **shiqimei** — the `Aqua.car` asset editing guide.
- **ZimengXiong** — the ThemeEngine/AssetCatalogTinkerer workflow.

ShitCornerFix adds: lite mode with subclass swizzling, overlay disable, `_updateCornerMask` fix, shadow retention, Chromium support, and the safe dylib update procedure.

## License

MIT. See [LICENSE](LICENSE).

## Tested On

| Component | Value |
|---|---|
| macOS | 26.5.1 Tahoe (25F80) |
| Architecture | x86_64 (Intel hackintosh, MacPro7,1) |
| Bootloader | OpenCore + Lilu 1.7.3 + WhateverGreen + AMFIPass |
| Finder | square corners + right buttons |
| Safari | square corners + right buttons (sandboxed, live toggle + exclusion verified) |
| Brave (Chromium) | square corners + right buttons (full mode, requires AMFI off) |
| AyuGram (Qt) | square corners (lite mode) + right buttons |
| Terminal | square corners + right buttons |
| TextEdit | square corners + right buttons (sandboxed) |
| OpenCode | square corners + right buttons |
| Incy | square corners + right buttons |
