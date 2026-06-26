// RightLights.m
// Move traffic light buttons to the right side of the window (Windows-style)
// Injected via DYLD_INSERT_LIBRARIES
//
// Order from left to right in the right group: [zoom] [minimize] [close]
// Close at the top-right corner, just like Windows.
//
// Settings: ~/Library/Application Support/MacTweaks/rightlights.plist
// Notification: com.local.rightlights.reload

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/log.h>
#import <notify.h>

#pragma mark - Constants

static const CGFloat kButtonSize    = 14.0;
static const CGFloat kButtonSpacing = 23.0;
static const CGFloat kRightInset    = 9.0;
// kButtonY is now read from each button's existing frame — no hardcode

static CGFloat RLRightGroupWidth(void) {
    return kRightInset + kButtonSize + 2 * kButtonSpacing;  // 69
}

#pragma mark - Settings

// Settings communication: uses notifyd state (IPC, works in sandbox).
// notify_set_state / notify_get_state store a uint64 per notification name.
//
// Protocol:
//   com.local.rightlights.global  — state: 0=disabled, 1=enabled (default: 1)
//   com.local.rightlights.app.<bundleID> — state: 0=excluded, 1=not-excluded
//
// The TUI sets state via notify_set_state, then posts com.local.rightlights.reload.
// The dylib reads state via notify_get_state on init and on reload notification.
//
// The plist file is still written for persistence across reboots
// (non-sandboxed apps read it at startup before notifyd is consulted).

static NSString *const kRLSettingsPath     = @"~/Library/Application Support/MacTweaks/rightlights.plist";
static NSString *const kRLReloadNotifName = @"com.local.rightlights.reload";
static NSString *const kRLGlobalStateName = @"com.local.rightlights.global";
static NSString *const kRLAppStatePrefix  = @"com.local.rightlights.app.";

static volatile BOOL rlEnabled = YES;
static volatile BOOL rlExcluded = NO;
static NSString *rlBundleID = nil;

static int rlGlobalToken = -1;
static int rlAppToken    = -1;

static os_log_t sLog = nil;

static void RLDebugLog(NSString *format, ...) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLog = os_log_create("com.local.rightlights", "debug");
    });
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(sLog, "%{public}s", [msg UTF8String] ?: "(nil)");
}

static void RLSettingsLoad(void) {
    // Read global enabled state from notifyd
    // Encoding: 0=never set (default: enabled), 1=enabled, 2=disabled
    if (rlGlobalToken >= 0) {
        uint64_t state = 0;
        uint32_t status = notify_get_state(rlGlobalToken, &state);
        if (status == NOTIFY_STATUS_OK) {
            rlEnabled = (state != 2);
            RLDebugLog(@"notifyd global: state=%llu enabled=%d", state, rlEnabled);
        } else {
            rlEnabled = YES;
            RLDebugLog(@"notifyd global: get_state failed, default enabled");
        }
    }

    // Read per-app exclusion state from notifyd
    // Encoding: 0=never set (default: not excluded), 1=not excluded, 2=excluded
    if (rlAppToken >= 0) {
        uint64_t state = 0;
        uint32_t status = notify_get_state(rlAppToken, &state);
        if (status == NOTIFY_STATUS_OK) {
            rlExcluded = (state == 2);
            RLDebugLog(@"notifyd app: state=%llu excluded=%d", state, rlExcluded);
        } else {
            rlExcluded = NO;
            RLDebugLog(@"notifyd app: get_state failed, not excluded");
        }
    } else {
        rlExcluded = NO;
    }
}

static BOOL RLShouldActivate(void) {
    if (!rlEnabled) return NO;
    if (rlExcluded) return NO;
    return YES;
}

// Forward declaration — defined later
static NSView *RLGetTitlebarView(NSWindow *window);

#pragma mark - Darwin notification listener

static void RLNotificationCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        RLDebugLog(@"=== Notification received ===");

        RLSettingsLoad();

        // Trigger relayout of all existing windows so buttons move
        // to their new position immediately (left or right).
        NSUInteger windowCount = [[NSApp windows] count];
        RLDebugLog(@"relayout: %lu windows, shouldActivate=%d", (unsigned long)windowCount, RLShouldActivate());

        for (NSWindow *window in [NSApp windows]) {
            NSView *themeFrame = window.contentView.superview;
            if (themeFrame && [themeFrame respondsToSelector:@selector(_updateButtonPositions)]) {
                ((void(*)(id,SEL))objc_msgSend)(themeFrame, @selector(_updateButtonPositions));
            }
            // Also trigger NSTitlebarView layout to update title rect
            NSView *tv = RLGetTitlebarView(window);
            if (tv && [tv respondsToSelector:@selector(layout)]) {
                ((void(*)(id,SEL))objc_msgSend)(tv, @selector(layout));
            }
        }
    });
}

#pragma mark - Original IMPs

static IMP orig_updateButtonPositions  = NULL;
static IMP orig_layout                 = NULL;
static IMP orig_titlebarTitleRect      = NULL;
static IMP orig_minXTitlebarBtnWidth   = NULL;
static IMP orig_maxXTitlebarBtnWidth   = NULL;
static IMP orig_leftButtonGroupFrame   = NULL;
static IMP orig_titlebarSetFrameSize   = NULL;
static IMP orig_titlebarLayout         = NULL;

#pragma mark - Re-entrancy guard

static BOOL sInReposition = NO;

#pragma mark - Helpers

static NSView *RLGetTitlebarView(NSWindow *window) {
    if (!window) return nil;
    id container = [window valueForKeyPath:@"_titlebarContainerView"];
    if (!container || ![container isKindOfClass:[NSView class]]) return nil;
    for (NSView *sub in [container subviews]) {
        if ([[sub className] isEqualToString:@"NSTitlebarView"]) return sub;
    }
    return nil;
}

static CGFloat RLTitlebarWidth(NSWindow *window) {
    NSView *tv = RLGetTitlebarView(window);
    if (tv) return tv.bounds.size.width;
    return window.frame.size.width;
}

#pragma mark - Core: Reposition buttons to the right

static void RLRepositionButtons(NSWindow *window) {
    if (!window || sInReposition) return;
    if ((window.styleMask & NSWindowStyleMaskFullScreen) != 0) return;

    CGFloat tw = RLTitlebarWidth(window);
    if (tw <= 0) return;

    sInReposition = YES;

    NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
    NSButton *minBtn   = [window standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomBtn  = [window standardWindowButton:NSWindowZoomButton];

    // Preserve each button's original Y — system computes it differently
    // for toolbar vs non-toolbar windows (y=9 for 32px titlebar, y=33 for 66px)
    if (closeBtn) {
        CGFloat y = closeBtn.frame.origin.y;
        [closeBtn setFrameOrigin:NSMakePoint(tw - kRightInset - kButtonSize, y)];
    }
    if (minBtn) {
        CGFloat y = minBtn.frame.origin.y;
        [minBtn setFrameOrigin:NSMakePoint(tw - kRightInset - kButtonSize - kButtonSpacing, y)];
    }
    if (zoomBtn) {
        CGFloat y = zoomBtn.frame.origin.y;
        [zoomBtn setFrameOrigin:NSMakePoint(tw - kRightInset - kButtonSize - 2 * kButtonSpacing, y)];
    }

    sInReposition = NO;
}

static NSRect RLComputeTitleRect(NSRect origRect, NSWindow *window) {
    if (!window) return origRect;

    CGFloat tw = RLTitlebarWidth(window);
    CGFloat rightLimit = tw - RLRightGroupWidth() - 10.0;
    CGFloat titleWidth = rightLimit - kRightInset;
    if (titleWidth < 0) titleWidth = 0;

    return NSMakeRect(kRightInset, origRect.origin.y, titleWidth, origRect.size.height);
}

#pragma mark - NSThemeFrame hooks

static void RL_updateButtonPositions(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_updateButtonPositions)(self, _cmd);
    if (RLShouldActivate()) {
        RLRepositionButtons([(NSView *)self window]);
    }
}

static void RL_layout(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_layout)(self, _cmd);
    if (RLShouldActivate()) {
        RLRepositionButtons([(NSView *)self window]);
    }
}

static NSRect RL_titlebarTitleRect(id self, SEL _cmd) {
    NSRect orig = ((NSRect(*)(id,SEL))orig_titlebarTitleRect)(self, _cmd);
    if (!RLShouldActivate()) return orig;
    return RLComputeTitleRect(orig, [(NSView *)self window]);
}

static CGFloat RL_minXTitlebarButtonsWidth(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((CGFloat(*)(id,SEL))orig_minXTitlebarBtnWidth)(self, _cmd);
    }
    return 0.0;
}

static CGFloat RL_maxXTitlebarButtonsWidth(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((CGFloat(*)(id,SEL))orig_maxXTitlebarBtnWidth)(self, _cmd);
    }
    return RLRightGroupWidth();
}

static NSRect RL_leftButtonGroupFrameInTitlebarView(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((NSRect(*)(id,SEL))orig_leftButtonGroupFrame)(self, _cmd);
    }

    NSWindow *window = [(NSView *)self window];
    if (!window) {
        return ((NSRect(*)(id,SEL))orig_leftButtonGroupFrame)(self, _cmd);
    }

    CGFloat tw = RLTitlebarWidth(window);
    CGFloat groupWidth = RLRightGroupWidth() - kRightInset;

    NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
    CGFloat btnY = closeBtn ? closeBtn.frame.origin.y : 9.0;
    CGFloat btnH = closeBtn ? closeBtn.frame.size.height : 14.0;

    return NSMakeRect(tw - RLRightGroupWidth(), btnY, groupWidth, btnH);
}

#pragma mark - NSTitlebarView hooks

static void RL_titlebarSetFrameSize(id self, SEL _cmd, NSSize size) {
    ((void(*)(id,SEL,NSSize))orig_titlebarSetFrameSize)(self, _cmd, size);
    if (RLShouldActivate()) {
        RLRepositionButtons([(NSView *)self window]);
    }
}

static void RL_titlebarLayout(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_titlebarLayout)(self, _cmd);
    if (RLShouldActivate()) {
        RLRepositionButtons([(NSView *)self window]);
    }
}

#pragma mark - Swizzle helper

static void RLSwizzle(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        fprintf(stderr, "[RightLights] WARNING: method not found: %s\n",
                [NSStringFromSelector(sel) UTF8String]);
        return;
    }
    *origPtr = method_setImplementation(m, newImp);
    fprintf(stderr, "[RightLights] swizzled %s.%s\n",
            [NSStringFromClass(cls) UTF8String],
            [NSStringFromSelector(sel) UTF8String]);
}

#pragma mark - Init

__attribute__((constructor))
static void RLInit(void) {
    Class themeFrame = NSClassFromString(@"NSThemeFrame");
    if (!themeFrame) return;

    Class titlebarView = NSClassFromString(@"NSTitlebarView");
    if (!titlebarView) return;

    rlBundleID = [[NSBundle mainBundle] bundleIdentifier];

    // Register with notifyd for state reads (works in sandbox)
    // Global enabled/disabled
    notify_register_check([kRLGlobalStateName UTF8String], &rlGlobalToken);
    RLDebugLog(@"registered global token=%d", rlGlobalToken);

    // Per-app exclusion (only if we have a bundle ID)
    if (rlBundleID) {
        NSString *appNotifName = [kRLAppStatePrefix stringByAppendingString:rlBundleID];
        notify_register_check([appNotifName UTF8String], &rlAppToken);
        RLDebugLog(@"registered app token=%d for %@", rlAppToken, rlBundleID);
    }

    // Load settings from notifyd
    RLSettingsLoad();

    RLDebugLog(@"init: bundle=%@ enabled=%d excluded=%d",
               rlBundleID ?: @"(none)", rlEnabled, rlExcluded);

    // Listen for reload notifications
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        RLNotificationCallback,
        (__bridge CFStringRef)kRLReloadNotifName,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Always install swizzles — hooks check RLShouldActivate() on every call.
    BOOL active = RLShouldActivate();
    RLDebugLog(@"active=%d — swizzles always installed", active);

    // --- NSThemeFrame swizzles ---
    RLSwizzle(themeFrame, @selector(_updateButtonPositions),
              (IMP)RL_updateButtonPositions, &orig_updateButtonPositions);
    RLSwizzle(themeFrame, @selector(layout),
              (IMP)RL_layout, &orig_layout);
    RLSwizzle(themeFrame, @selector(_titlebarTitleRect),
              (IMP)RL_titlebarTitleRect, &orig_titlebarTitleRect);
    RLSwizzle(themeFrame, @selector(_minXTitlebarButtonsWidth),
              (IMP)RL_minXTitlebarButtonsWidth, &orig_minXTitlebarBtnWidth);
    RLSwizzle(themeFrame, @selector(_maxXTitlebarButtonsWidth),
              (IMP)RL_maxXTitlebarButtonsWidth, &orig_maxXTitlebarBtnWidth);
    RLSwizzle(themeFrame, @selector(leftButtonGroupFrameInTitlebarView),
              (IMP)RL_leftButtonGroupFrameInTitlebarView, &orig_leftButtonGroupFrame);

    // --- NSTitlebarView swizzles ---
    RLSwizzle(titlebarView, @selector(setFrameSize:),
              (IMP)RL_titlebarSetFrameSize, &orig_titlebarSetFrameSize);
    RLSwizzle(titlebarView, @selector(layout),
              (IMP)RL_titlebarLayout, &orig_titlebarLayout);

    RLDebugLog(@"all swizzles installed");
}
