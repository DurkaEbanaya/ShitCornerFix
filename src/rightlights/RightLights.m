// RightLights.m
// Move traffic light buttons to the right side of the window (Windows-style)
// Optional Win10-style buttons: flat rectangles with Win10 symbols and hover colors
// Injected via DYLD_INSERT_LIBRARIES
//
// Settings: ~/Library/Application Support/MacTweaks/rightlights.plist
// Notification: com.local.rightlights.reload
//
// Win10 order from left to right: [minimize] [maximize] [close]
// Close at the top-right corner, just like Windows 10.

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

// Win10 button dimensions
static const CGFloat kWLButtonWidth = 46.0;

// Forward-declare settings variable used by RLRightGroupWidth
static volatile BOOL rlWin10Enabled = NO;

static CGFloat RLRightGroupWidth(void) {
    if (rlWin10Enabled) {
        return kWLButtonWidth * 3;  // 138
    }
    return kRightInset + kButtonSize + 2 * kButtonSpacing;  // 69
}

#pragma mark - Settings

static NSString *const kRLSettingsPath     = @"~/Library/Application Support/MacTweaks/rightlights.plist";
static NSString *const kRLReloadNotifName = @"com.local.rightlights.reload";
static NSString *const kRLGlobalStateName = @"com.local.rightlights.global";
static NSString *const kRLWin10StateName  = @"com.local.rightlights.win10";
static NSString *const kRLAppStatePrefix  = @"com.local.rightlights.app.";

static volatile BOOL rlEnabled    = YES;
// rlWin10Enabled is forward-declared above (before RLRightGroupWidth)
static volatile BOOL rlExcluded   = NO;
static NSString *rlBundleID = nil;

static int rlGlobalToken = -1;
static int rlWin10Token  = -1;
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
    // Global enabled/disabled: 0=never set (default on), 1=enabled, 2=disabled
    if (rlGlobalToken >= 0) {
        uint64_t state = 0;
        uint32_t status = notify_get_state(rlGlobalToken, &state);
        if (status == NOTIFY_STATUS_OK) {
            rlEnabled = (state != 2);
            RLDebugLog(@"notifyd global: state=%llu enabled=%d", state, rlEnabled);
        } else {
            rlEnabled = YES;
        }
    }

    // Win10 style: 0=never set (default off), 1=enabled, 2=disabled
    if (rlWin10Token >= 0) {
        uint64_t state = 0;
        uint32_t status = notify_get_state(rlWin10Token, &state);
        if (status == NOTIFY_STATUS_OK) {
            rlWin10Enabled = (state == 1);
            RLDebugLog(@"notifyd win10: state=%llu enabled=%d", state, rlWin10Enabled);
        } else {
            rlWin10Enabled = NO;
        }
    }

    // Per-app exclusion: 0=never set (default not excluded), 1=not excluded, 2=excluded
    if (rlAppToken >= 0) {
        uint64_t state = 0;
        uint32_t status = notify_get_state(rlAppToken, &state);
        if (status == NOTIFY_STATUS_OK) {
            rlExcluded = (state == 2);
            RLDebugLog(@"notifyd app: state=%llu excluded=%d", state, rlExcluded);
        } else {
            rlExcluded = NO;
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

static BOOL RLShouldActivateWin10(void) {
    if (!RLShouldActivate()) return NO;
    return rlWin10Enabled;
}

static void RLRepositionButtons(NSWindow *window);
static NSView *RLGetTitlebarView(NSWindow *window);

// Bug 1 fix: delayed reposition to catch post-zoom layout passes.
// During zoom, multiple layout passes fire with intermediate widths.
// We schedule cascading delayed repositions (50ms + 150ms) to catch
// the final stable width after all animation/layout passes settle.
static void RLScheduleDelayedReposition(NSWindow *window) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (!window) return;
        if ([window respondsToSelector:@selector(isClosed)] && [window performSelector:@selector(isClosed)]) return;
        RLRepositionButtons(window);

        // Second cascade for slow animations
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (!window) return;
            if ([window respondsToSelector:@selector(isClosed)] && [window performSelector:@selector(isClosed)]) return;
            RLRepositionButtons(window);
        });
    });
}

#pragma mark - Helpers

typedef NS_ENUM(NSInteger, WLButtonType) {
    WLButtonTypeMinimize,
    WLButtonTypeMaximize,
    WLButtonTypeClose,
};

@interface WLButton : NSView {
    WLButtonType _type;
    BOOL _hovered;
    BOOL _pressed;
    NSTrackingArea *_trackingArea;
    id _target;     // original button's target (the window)
    SEL _action;    // original button's action
}
- (instancetype)initWithFrame:(NSRect)frame
                         type:(WLButtonType)type
                       target:(id)target
                       action:(SEL)action;
@end

@implementation WLButton

- (instancetype)initWithFrame:(NSRect)frame
                         type:(WLButtonType)type
                       target:(id)target
                       action:(SEL)action {
    self = [super initWithFrame:frame];
    if (self) {
        _type = type;
        _target = target;
        _action = action;
        _hovered = NO;
        _pressed = NO;
        _trackingArea = nil;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
    return self;
}

- (BOOL)isFlipped {
    return NO;  // standard coordinate system (bottom-left origin)
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited |
                                 NSTrackingActiveInActiveApp |
                                 NSTrackingInVisibleRect;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:opts
                                                   owner:self
                                               userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (BOOL)isDarkAppearance {
    NSAppearance *appearance = self.effectiveAppearance;
    if (!appearance) return NO;
    NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua,
        NSAppearanceNameVibrantLight,
        NSAppearanceNameVibrantDark,
        NSAppearanceNameAccessibilityHighContrastAqua,
        NSAppearanceNameAccessibilityHighContrastDarkAqua,
    ]];
    if ([match isEqualToString:NSAppearanceNameDarkAqua] ||
        [match isEqualToString:NSAppearanceNameVibrantDark] ||
        [match isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua]) {
        return YES;
    }
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL isDark = [self isDarkAppearance];

    // Background
    if (_hovered || _pressed) {
        NSColor *bgColor;
        if (_type == WLButtonTypeClose) {
            // Close: red background
            if (_pressed) {
                bgColor = [NSColor colorWithRed:0.70f green:0.07f blue:0.09f alpha:1.0f];  // #B20014
            } else {
                bgColor = [NSColor colorWithRed:0.91f green:0.07f blue:0.14f alpha:1.0f];  // #E81123
            }
        } else {
            // Min/Max: gray background
            if (_pressed) {
                bgColor = isDark
                    ? [NSColor colorWithWhite:0.16f alpha:1.0f]  // #292929
                    : [NSColor colorWithWhite:0.82f alpha:1.0f];  // #D1D1D1
            } else {
                bgColor = isDark
                    ? [NSColor colorWithWhite:0.20f alpha:1.0f]  // #333333
                    : [NSColor colorWithWhite:0.90f alpha:1.0f];  // #E5E5E5
            }
        }
        [bgColor setFill];
        NSRectFill(self.bounds);
    }

    // Symbol color
    NSColor *symbolColor;
    if (_type == WLButtonTypeClose && (_hovered || _pressed)) {
        symbolColor = [NSColor whiteColor];
    } else if (isDark) {
        symbolColor = [NSColor whiteColor];
    } else {
        symbolColor = [NSColor blackColor];
    }

    [symbolColor setStroke];

    CGFloat cx = self.bounds.size.width / 2.0;
    CGFloat cy = self.bounds.size.height / 2.0;
    CGFloat symSize = 10.0;
    CGFloat lineW = 1.0;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = lineW;

    switch (_type) {
        case WLButtonTypeMinimize:
            // Horizontal line: —
            [path moveToPoint:NSMakePoint(cx - symSize/2, cy)];
            [path lineToPoint:NSMakePoint(cx + symSize/2, cy)];
            break;

        case WLButtonTypeMaximize: {
            // Square outline: □
            NSRect sq = NSMakeRect(cx - symSize/2, cy - symSize/2, symSize, symSize);
            [path appendBezierPathWithRect:sq];
            break;
        }

        case WLButtonTypeClose:
            // X: two diagonal lines
            [path moveToPoint:NSMakePoint(cx - symSize/2, cy + symSize/2)];
            [path lineToPoint:NSMakePoint(cx + symSize/2, cy - symSize/2)];
            [path moveToPoint:NSMakePoint(cx - symSize/2, cy - symSize/2)];
            [path lineToPoint:NSMakePoint(cx + symSize/2, cy + symSize/2)];
            break;
    }

    [path stroke];
}

- (void)mouseEntered:(NSEvent *)event {
    _hovered = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    _hovered = NO;
    _pressed = NO;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    _pressed = YES;
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    // Only trigger action if mouse was released inside the button
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    if (_pressed && NSMouseInRect(loc, self.bounds, [self isFlipped])) {
        if (_target && _action) {
            [NSApp sendAction:_action to:_target from:self];
        }
    }
    _pressed = NO;
    // Check if mouse is still inside for hover state
    if (NSMouseInRect(loc, self.bounds, [self isFlipped])) {
        _hovered = YES;
    } else {
        _hovered = NO;
    }
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL inside = NSMouseInRect(loc, self.bounds, [self isFlipped]);
    if (!inside && _pressed) {
        // Dragged outside — cancel press
        _pressed = NO;
        _hovered = NO;
        self.needsDisplay = YES;
    } else if (inside && !_pressed) {
        // Dragged back inside
        _pressed = YES;
        _hovered = YES;
        self.needsDisplay = YES;
    }
}

@end

#pragma mark - Win10 button management

static const char *kWLButtonAssocKey = "com.local.rightlights.wlbuttons";
static const char *kWLOriginalButtonsAssocKey = "com.local.rightlights.origbuttons";

@interface WLButtonGroup : NSObject
@property (strong) WLButton *minButton;
@property (strong) WLButton *maxButton;
@property (strong) WLButton *closeButton;
@property (strong) NSButton *origClose;
@property (strong) NSButton *origMin;
@property (strong) NSButton *origZoom;
@property (strong) NSWindow *window;
@end

@implementation WLButtonGroup
@end

static WLButtonGroup *RLGetOrCreateButtonGroup(NSWindow *window) {
    WLButtonGroup *group = objc_getAssociatedObject(window, kWLButtonAssocKey);

    // Get titlebar view — needed both for creating and for re-adding buttons
    NSView *titlebarView = RLGetTitlebarView(window);
    if (!titlebarView) {
        return nil;
    }

    if (group) {
        // Group exists — make sure buttons are in the titlebar view
        // (they may have been removed by the system during a layout pass)
        if (!group.minButton.superview) {
            [titlebarView addSubview:group.minButton];
            [titlebarView addSubview:group.maxButton];
            [titlebarView addSubview:group.closeButton];
        }
        return group;
    }

    group = [[WLButtonGroup alloc] init];
    group.window = window;

    // Get original buttons
    group.origClose = [window standardWindowButton:NSWindowCloseButton];
    group.origMin   = [window standardWindowButton:NSWindowMiniaturizeButton];
    group.origZoom  = [window standardWindowButton:NSWindowZoomButton];

    // Get titlebar height for button height
    CGFloat titlebarHeight = titlebarView.bounds.size.height;

    // Create WLButtons
    // Win10 order: [minimize] [maximize] [close] (left to right in right group)
    // Close at the far right
    group.closeButton = [[WLButton alloc] initWithFrame:NSMakeRect(0, 0, kWLButtonWidth, titlebarHeight)
                                                   type:WLButtonTypeClose
                                                 target:group.origClose.target
                                                 action:group.origClose.action];
    group.maxButton = [[WLButton alloc] initWithFrame:NSMakeRect(0, 0, kWLButtonWidth, titlebarHeight)
                                                 type:WLButtonTypeMaximize
                                               target:group.origZoom.target
                                               action:group.origZoom.action];
    group.minButton = [[WLButton alloc] initWithFrame:NSMakeRect(0, 0, kWLButtonWidth, titlebarHeight)
                                                 type:WLButtonTypeMinimize
                                               target:group.origMin.target
                                               action:group.origMin.action];

    // No autoresizing mask — we position buttons manually on every layout pass.
    // Autoresizing masks fight our positioning by moving buttons based on old
    // margins when the titlebar view resizes during zoom/resize animations.

    [titlebarView addSubview:group.minButton];
    [titlebarView addSubview:group.maxButton];
    [titlebarView addSubview:group.closeButton];

    objc_setAssociatedObject(window, kWLButtonAssocKey, group, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return group;
}

static void RLShowWin10Buttons(NSWindow *window) {
    WLButtonGroup *group = RLGetOrCreateButtonGroup(window);
    if (!group) return;

    // Hide original buttons
    if (group.origClose) group.origClose.hidden = YES;
    if (group.origMin)   group.origMin.hidden = YES;
    if (group.origZoom)  group.origZoom.hidden = YES;

    // Show WLButtons
    group.closeButton.hidden = NO;
    group.maxButton.hidden = NO;
    group.minButton.hidden = NO;

    // Position them
    RLRepositionButtons(window);
}

static void RLHideWin10Buttons(NSWindow *window) {
    WLButtonGroup *group = objc_getAssociatedObject(window, kWLButtonAssocKey);
    if (!group) return;

    // Hide WLButtons
    group.closeButton.hidden = YES;
    group.maxButton.hidden = YES;
    group.minButton.hidden = YES;

    // Show original buttons
    if (group.origClose) group.origClose.hidden = NO;
    if (group.origMin)   group.origMin.hidden = NO;
    if (group.origZoom)  group.origZoom.hidden = NO;
}

static void RLRemoveWin10Buttons(NSWindow *window) {
    WLButtonGroup *group = objc_getAssociatedObject(window, kWLButtonAssocKey);
    if (!group) return;

    // Show original buttons
    if (group.origClose) group.origClose.hidden = NO;
    if (group.origMin)   group.origMin.hidden = NO;
    if (group.origZoom)  group.origZoom.hidden = NO;

    // Remove WLButtons from superview
    [group.closeButton removeFromSuperview];
    [group.maxButton removeFromSuperview];
    [group.minButton removeFromSuperview];

    // Clear association
    objc_setAssociatedObject(window, kWLButtonAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Darwin notification listener

static void RLNotificationCallback(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        RLDebugLog(@"=== Notification received ===");

        BOOL wasWin10 = rlWin10Enabled;
        RLSettingsLoad();
        BOOL isWin10 = rlWin10Enabled;

        RLDebugLog(@"relayout: win10 was=%d now=%d shouldActivate=%d",
                   wasWin10, isWin10, RLShouldActivate());

        for (NSWindow *window in [NSApp windows]) {
            if (RLShouldActivate()) {
                if (isWin10 && !wasWin10) {
                    // Win10 just turned ON
                    RLShowWin10Buttons(window);
                } else if (!isWin10 && wasWin10) {
                    // Win10 just turned OFF
                    RLHideWin10Buttons(window);
                }

                // Trigger relayout
                NSView *themeFrame = window.contentView.superview;
                if (themeFrame && [themeFrame respondsToSelector:@selector(_updateButtonPositions)]) {
                    ((void(*)(id,SEL))objc_msgSend)(themeFrame, @selector(_updateButtonPositions));
                }
                NSView *tv = RLGetTitlebarView(window);
                if (tv && [tv respondsToSelector:@selector(layout)]) {
                    ((void(*)(id,SEL))objc_msgSend)(tv, @selector(layout));
                }
            } else {
                // RightLights disabled — remove Win10 buttons if any
                RLRemoveWin10Buttons(window);

                // Trigger relayout to restore original button positions
                NSView *themeFrame = window.contentView.superview;
                if (themeFrame && [themeFrame respondsToSelector:@selector(_updateButtonPositions)]) {
                    ((void(*)(id,SEL))objc_msgSend)(themeFrame, @selector(_updateButtonPositions));
                }
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

// Bug 2 fix: layout spacing methods
static IMP orig_toolbarLeadingSpace         = NULL;
static IMP orig_toolbarTrailingSpace        = NULL;
static IMP orig_minXTitlebarWidgetInset     = NULL;
static IMP orig_maxXTitlebarWidgetInset     = NULL;
static IMP orig_minXTitlebarDragWidth       = NULL;
static IMP orig_maxXTitlebarDragWidth       = NULL;
static IMP orig_minXTitlebarDecorationMinW  = NULL;
static IMP orig_maxXTitlebarDecorationMinW  = NULL;
static IMP orig_minXInsetForAccessoryViews  = NULL;

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
    // Window frame width is the source of truth.
    // The titlebar view's bounds may lag behind during resize/zoom —
    // macOS doesn't resize it synchronously with the window frame.
    // Using window.frame.size.width ensures we always position buttons
    // relative to the actual window edge, not a stale titlebar view width.
    return window.frame.size.width;
}

#pragma mark - Core: Reposition buttons to the right

static void RLRepositionButtons(NSWindow *window) {
    if (!window) return;

    CGFloat tw = RLTitlebarWidth(window);
    if (tw <= 0) return;

    if (RLShouldActivateWin10()) {
        // Win10 mode: position WLButtons
        WLButtonGroup *group = objc_getAssociatedObject(window, kWLButtonAssocKey);
        if (group) {
            // Always hide original buttons — in fullscreen, the system
            // toggles their hidden state when showing/hiding the titlebar
            // on hover. We must re-hide them on every layout pass to
            // prevent them from appearing at the left position.
            if (group.origClose) group.origClose.hidden = YES;
            if (group.origMin)   group.origMin.hidden = YES;
            if (group.origZoom)  group.origZoom.hidden = YES;

            NSView *titlebarView = RLGetTitlebarView(window);
            CGFloat titlebarHeight = titlebarView ? titlebarView.bounds.size.height : 32.0;

            // Ensure titlebar view bounds match window width —
            // macOS may leave titlebar view at old width during resize,
            // causing WLButtons (positioned at tw-kWLButtonWidth) to be
            // clipped or invisible if they fall outside the view's bounds.
            if (titlebarView && titlebarView.bounds.size.width < tw) {
                NSRect newBounds = titlebarView.bounds;
                newBounds.size.width = tw;
                [titlebarView setBounds:newBounds];
            }

            // Order: [minimize] [maximize] [close] (left to right)
            // Close at far right
            CGFloat closeX = tw - kWLButtonWidth;
            CGFloat maxX   = tw - kWLButtonWidth * 2;
            CGFloat minX   = tw - kWLButtonWidth * 3;

            [group.closeButton setFrame:NSMakeRect(closeX, 0, kWLButtonWidth, titlebarHeight)];
            [group.maxButton  setFrame:NSMakeRect(maxX, 0, kWLButtonWidth, titlebarHeight)];
            [group.minButton  setFrame:NSMakeRect(minX, 0, kWLButtonWidth, titlebarHeight)];
        }
    } else {
        // Classic mode: reposition original buttons
        NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
        NSButton *minBtn   = [window standardWindowButton:NSWindowMiniaturizeButton];
        NSButton *zoomBtn  = [window standardWindowButton:NSWindowZoomButton];

        // Order: [zoom] [min] [close] (left to right in right group)
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
    }

    // No re-entrancy guard — setFrame: on WLButton and setFrameOrigin: on
    // original buttons cannot trigger layout recursion. The guard was
    // causing the outermost call (with the correct final titlebar width)
    // to be skipped when nested layout passes set it to YES.
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
        NSWindow *window = [(NSView *)self window];
        if (RLShouldActivateWin10()) {
            RLShowWin10Buttons(window);
        }
        RLRepositionButtons(window);
    }
}

static void RL_layout(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_layout)(self, _cmd);
    if (RLShouldActivate()) {
        NSWindow *window = [(NSView *)self window];
        if (RLShouldActivateWin10()) {
            RLShowWin10Buttons(window);
        }
        RLRepositionButtons(window);
        RLScheduleDelayedReposition(window);  // Bug 1: catch post-zoom layout
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

#pragma mark - Bug 2 fix: layout spacing hooks

// These methods tell the layout system how much space to reserve for buttons.
// Original: left-side methods return ~78-88px, right-side methods return 0.
// Swizzled: left-side methods return 0, right-side methods return our width.
// This makes toolbar items, accessory views, and decorations avoid the right side.

static double RL_toolbarLeadingSpace(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_toolbarLeadingSpace)(self, _cmd);
    }
    return 0.0;  // no buttons on the left
}

static double RL_toolbarTrailingSpace(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_toolbarTrailingSpace)(self, _cmd);
    }
    return RLRightGroupWidth();  // reserve space on the right for buttons
}

static double RL_minXTitlebarWidgetInset(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_minXTitlebarWidgetInset)(self, _cmd);
    }
    return 0.0;  // no left widget inset
}

static double RL_maxXTitlebarWidgetInset(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_maxXTitlebarWidgetInset)(self, _cmd);
    }
    return rlWin10Enabled ? 0.0 : kRightInset;  // right widget inset
}

static double RL_minXTitlebarDragWidth(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_minXTitlebarDragWidth)(self, _cmd);
    }
    return 0.0;  // no left drag area
}

static double RL_maxXTitlebarDragWidth(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_maxXTitlebarDragWidth)(self, _cmd);
    }
    return RLRightGroupWidth();  // right drag area = button area
}

static double RL_minXTitlebarDecorationMinWidth(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_minXTitlebarDecorationMinW)(self, _cmd);
    }
    return 0.0;  // no left decoration
}

static double RL_maxXTitlebarDecorationMinWidth(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_maxXTitlebarDecorationMinW)(self, _cmd);
    }
    return RLRightGroupWidth();  // right decoration = button area
}

static double RL_minXInsetForAccessoryViews(id self, SEL _cmd) {
    if (!RLShouldActivate()) {
        return ((double(*)(id,SEL))orig_minXInsetForAccessoryViews)(self, _cmd);
    }
    return 0.0;  // no left inset for accessories
}

#pragma mark - NSTitlebarView hooks

static void RL_titlebarSetFrameSize(id self, SEL _cmd, NSSize size) {
    ((void(*)(id,SEL,NSSize))orig_titlebarSetFrameSize)(self, _cmd, size);
    if (RLShouldActivate()) {
        NSWindow *window = [(NSView *)self window];
        if (RLShouldActivateWin10()) {
            RLShowWin10Buttons(window);
        }
        RLRepositionButtons(window);
        RLScheduleDelayedReposition(window);  // Bug 1: catch post-resize layout
    }
}

static void RL_titlebarLayout(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_titlebarLayout)(self, _cmd);
    if (RLShouldActivate()) {
        NSWindow *window = [(NSView *)self window];
        if (RLShouldActivateWin10()) {
            RLShowWin10Buttons(window);
        }
        RLRepositionButtons(window);
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

#pragma mark - Fullscreen notifications

static void RLFullscreenCallback(NSNotification *notification) {
    NSWindow *window = [notification object];
    if (!window) return;
    
    NSString *name = notification.name;
    BOOL entering = [name containsString:@"Enter"];
    
    RLDebugLog(@"Fullscreen: %@ window=%@", entering ? @"ENTERING" : @"EXITING", window);
    
    if (entering) {
        // Reposition at multiple delays — the fullscreen transition animation
        // takes ~0.5-1s, and the titlebar view may not be ready immediately.
        NSTimeInterval delays[] = {0.3, 0.7, 1.5, 3.0};
        for (int i = 0; i < 4; i++) {
            NSTimeInterval delay = delays[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!window) return;
                if ([window respondsToSelector:@selector(isClosed)] && [window performSelector:@selector(isClosed)]) return;
                if (!RLShouldActivate()) return;
                
                if (RLShouldActivateWin10()) {
                    RLShowWin10Buttons(window);
                }
                RLRepositionButtons(window);
            });
        }
    } else {
        // Exiting fullscreen — reposition after exit
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!window) return;
            if ([window respondsToSelector:@selector(isClosed)] && [window performSelector:@selector(isClosed)]) return;
            if (!RLShouldActivate()) return;
            
            if (RLShouldActivateWin10()) {
                RLShowWin10Buttons(window);
            }
            RLRepositionButtons(window);
        });
        // Second pass for slow exit animations
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!window) return;
            if ([window respondsToSelector:@selector(isClosed)] && [window performSelector:@selector(isClosed)]) return;
            if (!RLShouldActivate()) return;
            RLRepositionButtons(window);
        });
    }
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
    notify_register_check([kRLGlobalStateName UTF8String], &rlGlobalToken);
    notify_register_check([kRLWin10StateName UTF8String], &rlWin10Token);

    if (rlBundleID) {
        NSString *appNotifName = [kRLAppStatePrefix stringByAppendingString:rlBundleID];
        notify_register_check([appNotifName UTF8String], &rlAppToken);
    }

    // Load settings from notifyd
    RLSettingsLoad();

    RLDebugLog(@"init: bundle=%@ enabled=%d win10=%d excluded=%d",
               rlBundleID ?: @"(none)", rlEnabled, rlWin10Enabled, rlExcluded);

    // Listen for reload notifications
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        RLNotificationCallback,
        (__bridge CFStringRef)kRLReloadNotifName,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Listen for fullscreen transitions
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        RLFullscreenCallback(n);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        RLFullscreenCallback(n);
    }];

    // Always install swizzles — hooks check RLShouldActivate() on every call.
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

    // Bug 2 fix: layout spacing — tell toolbar/accessories to reserve space on right
    RLSwizzle(themeFrame, @selector(_toolbarLeadingSpace),
              (IMP)RL_toolbarLeadingSpace, &orig_toolbarLeadingSpace);
    RLSwizzle(themeFrame, @selector(_toolbarTrailingSpace),
              (IMP)RL_toolbarTrailingSpace, &orig_toolbarTrailingSpace);
    RLSwizzle(themeFrame, @selector(_minXTitlebarWidgetInset),
              (IMP)RL_minXTitlebarWidgetInset, &orig_minXTitlebarWidgetInset);
    RLSwizzle(themeFrame, @selector(_maxXTitlebarWidgetInset),
              (IMP)RL_maxXTitlebarWidgetInset, &orig_maxXTitlebarWidgetInset);
    RLSwizzle(themeFrame, @selector(_minXTitlebarDragWidth),
              (IMP)RL_minXTitlebarDragWidth, &orig_minXTitlebarDragWidth);
    RLSwizzle(themeFrame, @selector(_maxXTitlebarDragWidth),
              (IMP)RL_maxXTitlebarDragWidth, &orig_maxXTitlebarDragWidth);
    RLSwizzle(themeFrame, @selector(_minXTitlebarDecorationMinWidth),
              (IMP)RL_minXTitlebarDecorationMinWidth, &orig_minXTitlebarDecorationMinW);
    RLSwizzle(themeFrame, @selector(_maxXTitlebarDecorationMinWidth),
              (IMP)RL_maxXTitlebarDecorationMinWidth, &orig_maxXTitlebarDecorationMinW);
    RLSwizzle(themeFrame, @selector(_minXInsetForAccessoryViews),
              (IMP)RL_minXInsetForAccessoryViews, &orig_minXInsetForAccessoryViews);

    RLSwizzle(titlebarView, @selector(setFrameSize:),
              (IMP)RL_titlebarSetFrameSize, &orig_titlebarSetFrameSize);
    RLSwizzle(titlebarView, @selector(layout),
              (IMP)RL_titlebarLayout, &orig_titlebarLayout);

    RLDebugLog(@"all swizzles installed (win10=%d)", rlWin10Enabled);
}
