#!/bin/bash
# cornerfix-inject.sh — set DYLD_INSERT_LIBRARIES in launchd, then restart
# GUI processes so they inherit the environment variable.
# Also applies system-wide animation defaults (NoAnims).
#
# IMPORTANT: When updating dylibs, use `install` (not `cp`) to create a new
# inode. cp overwrites in-place and corrupts memory-mapped pages in running
# processes → AMFI kills them with "Invalid Page" / Code Signature Invalid.

DYLDS="/usr/local/lib/libcornerfix.dylib:/usr/local/lib/librightlights.dylib:/usr/local/lib/libnoanims.dylib"

launchctl setenv DYLD_INSERT_LIBRARIES "$DYLDS"

# Apply NoAnims defaults (system-wide animation settings)
NA_PLIST="$HOME/Library/Application Support/MacTweaks/noanims.plist"
NA_ENABLED=1
if [ -f "$NA_PLIST" ]; then
    NA_ENABLED=$(/usr/bin/defaults read "$NA_PLIST" enabled 2>/dev/null || echo 1)
fi

if [ "$NA_ENABLED" = "1" ]; then
    # ── Global window animations ──
    defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
    defaults write NSGlobalDomain NSWindowResizeTime -float 0.0001

    # ── Dock ──
    defaults write com.apple.dock autohide-time-modifier -float 0
    defaults write com.apple.dock autohide-delay -float 0
    defaults write com.apple.dock launchanim -bool false
    defaults write com.apple.dock mineffect -string "scale"

    # ── Finder ──
    defaults write com.apple.Finder DisableAllAnimations -bool true

    # ── Accessibility ──
    defaults write com.apple.universalaccess reduceMotion -bool true
    # NOTE: reduceTransparency NOT set — breaks System Settings UI in Tahoe

    # ── Spring loading ──
    defaults write NSGlobalDomain "com.apple.springing.enabled" -bool false
    defaults write NSGlobalDomain "com.apple.springing.duration" -float 0
fi

# Give launchd a moment to register the env
sleep 1

# Restart GUI processes that need our hooks.
killall Finder 2>/dev/null
killall Dock 2>/dev/null
killall SystemUIServer 2>/dev/null
killall NotificationCenter 2>/dev/null
killall ControlCenter 2>/dev/null

exit 0
