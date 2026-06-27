// FluentSidebar.m
// Remove Liquid Glass "pill" backgrounds from source-list sidebars (Finder, Settings, etc.)
// Add Windows 10 Fluent Reveal Highlight on hover + accent strip for selected items.
// Injected via DYLD_INSERT_LIBRARIES
//
// Settings: ~/Library/Application Support/MacTweaks/fluentsidebar.plist
// Notifications: com.local.fluentsidebar.reload
//
// Architecture: The pill view (NSTableRowSidebarSelectionView) is still created by
// the system, but its updateLayer is a no-op and it's hidden on didMoveToSuperview.
// This avoids crashes in apps that access _selectedBackgroundView but expect it non-nil.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/log.h>
#import <notify.h>

#pragma mark - Constants

static const CGFloat kAccentStripWidth = 4.0;
static const CGFloat kRevealSegmentLength = 8.0;
static const CGFloat kRevealEdgeWidth = 1.35;
static const CGFloat kRevealRadiusFactor = 1.85;

#pragma mark - Settings

static NSString *const kFSSettingsPath     = @"~/Library/Application Support/MacTweaks/fluentsidebar.plist";
static NSString *const kFSReloadNotifName = @"com.local.fluentsidebar.reload";
static NSString *const kFSGlobalStateName = @"com.local.fluentsidebar.global";
static NSString *const kFSAccentStateName = @"com.local.fluentsidebar.accentstrip";
static NSString *const kFSRevealStateName = @"com.local.fluentsidebar.reveal";
static NSString *const kFSAppStatePrefix   = @"com.local.fluentsidebar.app.";

static volatile BOOL fsEnabled      = YES;
static volatile BOOL fsAccentStrip  = YES;
static volatile BOOL fsReveal       = YES;
static volatile BOOL fsExcluded     = NO;
static NSString *fsBundleID = nil;

static int fsGlobalToken  = -1;
static int fsAccentToken  = -1;
static int fsRevealToken  = -1;
static int fsAppToken     = -1;

static os_log_t sLog = nil;

static void FSDebugLog(NSString *format, ...) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLog = os_log_create("com.local.fluentsidebar", "debug");
    });
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(sLog, "%{public}s", [msg UTF8String] ?: "(nil)");
}

#pragma mark - Excluded bundle IDs

static NSArray<NSString *> *FSExcludedBundleIDs(void) {
    return @[
        @"one.ayugram.AyuGramDesktop",
        @"ru.ayugram.macos",
        @"com.obsproject.obs-studio",
        @"ru.oneme.desktop",             // Max messenger — crashes on nil selection views
    ];
}

static BOOL FSIsExcludedBundle(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) return NO;
    for (NSString *blocked in FSExcludedBundleIDs()) {
        if ([bundleIdentifier isEqualToString:blocked]) return YES;
    }
    return NO;
}

#pragma mark - Settings load

static void FSSettingsLoad(void) {
    if (fsGlobalToken >= 0) {
        uint64_t state = 0;
        if (notify_get_state(fsGlobalToken, &state) == NOTIFY_STATUS_OK) {
            fsEnabled = (state != 2);
        }
    }
    if (fsAccentToken >= 0) {
        uint64_t state = 0;
        if (notify_get_state(fsAccentToken, &state) == NOTIFY_STATUS_OK) {
            fsAccentStrip = (state != 2);
        }
    }
    if (fsRevealToken >= 0) {
        uint64_t state = 0;
        if (notify_get_state(fsRevealToken, &state) == NOTIFY_STATUS_OK) {
            fsReveal = (state != 2);
        }
    }
    if (fsAppToken >= 0) {
        uint64_t state = 0;
        if (notify_get_state(fsAppToken, &state) == NOTIFY_STATUS_OK) {
            fsExcluded = (state == 2);
        }
    }
}

static BOOL FSShouldActivate(void) {
    if (!fsEnabled) return NO;
    if (fsExcluded) return NO;
    if (FSIsExcludedBundle(fsBundleID)) return NO;
    return YES;
}

#pragma mark - Source-list detection

static BOOL FSIsSourceListRow(NSView *rowView) {
    NSTableView *tv = nil;
    if ([rowView respondsToSelector:@selector(tableView)]) {
        tv = [rowView performSelector:@selector(tableView)];
    }
    if (!tv) return NO;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (tv.selectionHighlightStyle == NSTableViewSelectionHighlightStyleSourceList)
        return YES;
#pragma clang diagnostic pop

    if ([tv respondsToSelector:@selector(_hasSourceListBackground)]) {
        if ([tv performSelector:@selector(_hasSourceListBackground)]) return YES;
    }

    if ([tv respondsToSelector:@selector(style)]) {
        long style = (long)[tv performSelector:@selector(style)];
        if (style == 3 || style == 2) return YES;
    }

    return NO;
}

#pragma mark - Dark mode detection

static BOOL FSIsDarkMode(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"]
               .length > 0;
}

#pragma mark - Reveal drawing (ported from Acrylic Calendar Swift)

static void FSDrawRevealInRect(NSRect rect, NSPoint mousePoint, BOOL isDarkMode) {
    NSColor *accentColor = [NSColor controlAccentColor];
    CGFloat maxDim = MAX(rect.size.width, rect.size.height);
    CGFloat radius = maxDim * kRevealRadiusFactor;

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, NSRectToCGRect(rect));

    NSColor *centerColor = isDarkMode
        ? [[NSColor whiteColor] colorWithAlphaComponent:0.18]
        : [accentColor colorWithAlphaComponent:0.14];
    NSColor *midColor = isDarkMode
        ? [[NSColor whiteColor] colorWithAlphaComponent:0.06]
        : [accentColor colorWithAlphaComponent:0.07];
    NSColor *edgeColor = [NSColor clearColor];

    CGFloat locations[] = {0.0, 0.42, 1.0};
    CGColorRef c0 = [centerColor CGColor];
    CGColorRef c1 = [midColor CGColor];
    CGColorRef c2 = [edgeColor CGColor];
    CGColorRef cgColors[] = {c0, c1, c2};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CFArrayRef colorArray = CFArrayCreate(NULL, (const void **)cgColors, 3, &kCFTypeArrayCallBacks);
    CGGradientRef gradient = CGGradientCreateWithColors(cs, colorArray, locations);
    CFRelease(colorArray);
    CGColorSpaceRelease(cs);
    if (gradient) {
        CGContextDrawRadialGradient(ctx, gradient,
                                     CGPointMake(mousePoint.x, mousePoint.y), 0,
                                     CGPointMake(mousePoint.x, mousePoint.y), radius,
                                     kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(gradient);
    }

    // Edge segments
    NSColor *edgeColorBase = isDarkMode ? [NSColor whiteColor] : accentColor;
    CGFloat edgeAlphaBase = isDarkMode ? 0.82 : 0.58;
    NSRect edgeRect = NSInsetRect(rect, 0.5, 0.5);

    void (^drawSegment)(NSPoint, NSPoint) = ^(NSPoint start, NSPoint end) {
        NSPoint mid = NSMakePoint((start.x + end.x) / 2.0, (start.y + end.y) / 2.0);
        CGFloat distance = hypotf(mid.x - mousePoint.x, mid.y - mousePoint.y);
        CGFloat intensity = MAX(0.0, 1.0 - distance / radius);
        if (intensity <= 0.02) return;
        CGFloat alpha = edgeAlphaBase * intensity * intensity;
        NSBezierPath *seg = [NSBezierPath bezierPath];
        [seg moveToPoint:start];
        [seg lineToPoint:end];
        seg.lineWidth = kRevealEdgeWidth;
        [[edgeColorBase colorWithAlphaComponent:alpha] setStroke];
        [seg stroke];
    };

    for (CGFloat x = edgeRect.origin.x; x < edgeRect.origin.x + edgeRect.size.width; x += kRevealSegmentLength) {
        CGFloat nextX = MIN(x + kRevealSegmentLength, edgeRect.origin.x + edgeRect.size.width);
        drawSegment(NSMakePoint(x, edgeRect.origin.y), NSMakePoint(nextX, edgeRect.origin.y));
        drawSegment(NSMakePoint(x, edgeRect.origin.y + edgeRect.size.height),
                     NSMakePoint(nextX, edgeRect.origin.y + edgeRect.size.height));
    }
    for (CGFloat y = edgeRect.origin.y; y < edgeRect.origin.y + edgeRect.size.height; y += kRevealSegmentLength) {
        CGFloat nextY = MIN(y + kRevealSegmentLength, edgeRect.origin.y + edgeRect.size.height);
        drawSegment(NSMakePoint(edgeRect.origin.x, y), NSMakePoint(edgeRect.origin.x, nextY));
        drawSegment(NSMakePoint(edgeRect.origin.x + edgeRect.size.width, y),
                     NSMakePoint(edgeRect.origin.x + edgeRect.size.width, nextY));
    }

    CGContextRestoreGState(ctx);
}

static void FSDrawAccentStrip(NSRect bounds) {
    [[NSColor controlAccentColor] setFill];
    NSRectFill(NSMakeRect(0, 0, kAccentStripWidth, bounds.size.height));
}

#pragma mark - Associated objects for hover state

static char kHoveredKey;
static char kMousePointKey;
static char kTrackingAreaKey;

static BOOL FSGetHovered(NSView *view) {
    id val = objc_getAssociatedObject(view, &kHoveredKey);
    return val ? [val boolValue] : NO;
}
static void FSSetHovered(NSView *view, BOOL hovered) {
    objc_setAssociatedObject(view, &kHoveredKey, @(hovered), OBJC_ASSOCIATION_RETAIN);
}
static NSPoint FSGetMousePoint(NSView *view) {
    id val = objc_getAssociatedObject(view, &kMousePointKey);
    if ([val isKindOfClass:[NSValue class]]) { NSPoint p; [val getValue:&p]; return p; }
    return NSZeroPoint;
}
static void FSSetMousePoint(NSView *view, NSPoint point) {
    objc_setAssociatedObject(view, &kMousePointKey, [NSValue valueWithPoint:point], OBJC_ASSOCIATION_RETAIN);
}
static NSTrackingArea *FSGetTrackingArea(NSView *view) {
    return objc_getAssociatedObject(view, &kTrackingAreaKey);
}
static void FSSetTrackingArea(NSView *view, NSTrackingArea *area) {
    objc_setAssociatedObject(view, &kTrackingAreaKey, area, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark - Swizzle originals

static IMP orig_sidebarSel_updateLayer         = NULL;
static IMP orig_sidebarSel_didMoveToSuperview  = NULL;
static IMP orig_rowView_updateTrackingAreas    = NULL;
static IMP orig_rowView_mouseEntered           = NULL;
static IMP orig_rowView_mouseExited            = NULL;
static IMP orig_rowView_mouseMoved             = NULL;
static IMP orig_rowView_drawRect               = NULL;
static IMP orig_rowView_drawBackgroundInRect   = NULL;
static IMP orig_tableView_drawSourceListHL     = NULL;
static IMP orig_tableView_drawSourceListHLButt = NULL;
static IMP orig_styleData_wantsSolarium        = NULL;

#pragma mark - Swizzle implementations

// --- NSTableRowSidebarSelectionView.updateLayer → no-op ---
// The pill view exists but never draws its glass material.
static void FS_SIDEBAR_SELECTION_updateLayer(id self, SEL _cmd) {
    // No-op: don't draw the glass pill
}

// --- NSTableRowSidebarSelectionView.didMoveToSuperview → hide self ---
// Belt-and-suspenders: hide the pill view when it enters the view hierarchy.
static void FS_SIDEBAR_SELECTION_didMoveToSuperview(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_sidebarSel_didMoveToSuperview)(self, _cmd);
    if (!FSShouldActivate()) return;
    NSView *view = self;
    view.hidden = YES;
    if (view.layer) {
        view.layer.backgroundColor = [NSColor clearColor].CGColor;
        view.layer.cornerRadius = 0;
    }
}

// --- NSTableRowView.drawBackgroundInRect: → no-op for source-list rows ---
static void FS_rowView_drawBackgroundInRect(id self, SEL _cmd, NSRect rect) {
    if (FSShouldActivate() && FSIsSourceListRow(self)) {
        return;
    }
    ((void(*)(id, SEL, NSRect))orig_rowView_drawBackgroundInRect)(self, _cmd, rect);
}

// --- NSTableView._drawSourceListHighlightInRect: → no-op ---
static void FS_tableView_drawSourceListHighlight(id self, SEL _cmd, NSRect rect) {
    if (FSShouldActivate()) {
        return;
    }
    ((void(*)(id, SEL, NSRect))orig_tableView_drawSourceListHL)(self, _cmd, rect);
}

// --- NSTableView._drawSourceListHighlightInRect:isButtedUpRow: → no-op ---
static void FS_tableView_drawSourceListHighlightButt(id self, SEL _cmd, NSRect rect, BOOL butted) {
    if (FSShouldActivate()) {
        return;
    }
    ((void(*)(id, SEL, NSRect, BOOL))orig_tableView_drawSourceListHLButt)(self, _cmd, rect, butted);
}

// --- NSTableViewStyleData.wantsSolariumAppearance → NO ---
static BOOL FS_styleData_wantsSolariumAppearance(id self, SEL _cmd) {
    if (FSShouldActivate()) {
        return NO;
    }
    return ((BOOL(*)(id, SEL))orig_styleData_wantsSolarium)(self, _cmd);
}

// --- NSTableRowView.updateTrackingAreas → add hover tracking ---
static void FS_rowView_updateTrackingAreas(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_rowView_updateTrackingAreas)(self, _cmd);
    if (!FSShouldActivate() || !FSIsSourceListRow(self)) return;
    if (!fsReveal) return;

    NSTrackingArea *oldArea = FSGetTrackingArea(self);
    if (oldArea) [(NSView *)self removeTrackingArea:oldArea];

    NSView *view = self;
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited |
                                  NSTrackingMouseMoved |
                                  NSTrackingActiveInActiveApp |
                                  NSTrackingInVisibleRect;
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:view.bounds
                                                         options:opts
                                                           owner:view
                                                        userInfo:nil];
    FSSetTrackingArea(view, area);
    [view addTrackingArea:area];
}

// --- NSTableRowView.mouseEntered: ---
static void FS_rowView_mouseEntered(id self, SEL _cmd, NSEvent *event) {
    ((void(*)(id, SEL, NSEvent *))orig_rowView_mouseEntered)(self, _cmd, event);
    if (!FSShouldActivate() || !FSIsSourceListRow(self) || !fsReveal) return;
    NSView *view = self;
    NSPoint localPoint = [view convertPoint:[event locationInWindow] fromView:nil];
    FSSetMousePoint(view, localPoint);
    FSSetHovered(view, YES);
    [view setNeedsDisplay:YES];
}

// --- NSTableRowView.mouseExited: ---
static void FS_rowView_mouseExited(id self, SEL _cmd, NSEvent *event) {
    ((void(*)(id, SEL, NSEvent *))orig_rowView_mouseExited)(self, _cmd, event);
    if (!FSShouldActivate() || !FSIsSourceListRow(self) || !fsReveal) return;
    FSSetHovered(self, NO);
    [self setNeedsDisplay:YES];
}

// --- NSTableRowView.mouseMoved: ---
static void FS_rowView_mouseMoved(id self, SEL _cmd, NSEvent *event) {
    ((void(*)(id, SEL, NSEvent *))orig_rowView_mouseMoved)(self, _cmd, event);
    if (!FSShouldActivate() || !FSIsSourceListRow(self) || !fsReveal) return;
    NSView *view = self;
    NSPoint localPoint = [view convertPoint:[event locationInWindow] fromView:nil];
    FSSetMousePoint(view, localPoint);
    [view setNeedsDisplay:YES];
}

// --- NSTableRowView.drawRect: → draw reveal + accent strip after super ---
static void FS_rowView_drawRect(id self, SEL _cmd, NSRect dirtyRect) {
    ((void(*)(id, SEL, NSRect))orig_rowView_drawRect)(self, _cmd, dirtyRect);
    if (!FSShouldActivate() || !FSIsSourceListRow(self)) return;

    NSView *view = self;
    NSRect bounds = view.bounds;

    if (fsAccentStrip) {
        BOOL isSelected = NO;
        if ([view respondsToSelector:@selector(isSelected)]) {
            isSelected = ((BOOL(*)(id, SEL))objc_msgSend)(view, @selector(isSelected));
        }
        if (isSelected) FSDrawAccentStrip(bounds);
    }

    if (fsReveal && FSGetHovered(view)) {
        FSDrawRevealInRect(bounds, FSGetMousePoint(view), FSIsDarkMode());
    }
}

#pragma mark - Swizzle helper (os_log only, no stderr)

static void FSSwizzle(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        FSDebugLog(@"WARNING: method not found: %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    *origPtr = method_setImplementation(m, newImp);
    FSDebugLog(@"swizzled %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

#pragma mark - Reload callback

static void FSNotificationCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    FSSettingsLoad();
    FSDebugLog(@"reload: enabled=%d accent=%d reveal=%d excluded=%d",
               fsEnabled, fsAccentStrip, fsReveal, fsExcluded);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *window in [NSApp windows]) {
            [window.contentView setNeedsDisplay:YES];
        }
    });
}

#pragma mark - Init

__attribute__((constructor))
static void FSInit(void) {
    fsBundleID = [[NSBundle mainBundle] bundleIdentifier];

    notify_register_check([kFSGlobalStateName UTF8String], &fsGlobalToken);
    notify_register_check([kFSAccentStateName UTF8String], &fsAccentToken);
    notify_register_check([kFSRevealStateName UTF8String], &fsRevealToken);

    if (fsBundleID) {
        NSString *appNotifName = [kFSAppStatePrefix stringByAppendingString:fsBundleID];
        notify_register_check([appNotifName UTF8String], &fsAppToken);
    }

    // Restore from plist after reboot (notifyd state resets to 0)
    {
        NSString *plistPath = [kFSSettingsPath stringByExpandingTildeInPath];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (plist) {
            if (plist[@"enabled"]) {
                uint64_t cur = 0; notify_get_state(fsGlobalToken, &cur);
                if (cur == 0) notify_set_state(fsGlobalToken, [plist[@"enabled"] boolValue] ? 1 : 2);
            }
            if (plist[@"accentstrip"]) {
                uint64_t cur = 0; notify_get_state(fsAccentToken, &cur);
                if (cur == 0) notify_set_state(fsAccentToken, [plist[@"accentstrip"] boolValue] ? 1 : 2);
            }
            if (plist[@"reveal"]) {
                uint64_t cur = 0; notify_get_state(fsRevealToken, &cur);
                if (cur == 0) notify_set_state(fsRevealToken, [plist[@"reveal"] boolValue] ? 1 : 2);
            }
        }
    }

    FSSettingsLoad();

    FSDebugLog(@"init: bundle=%@ enabled=%d accent=%d reveal=%d excluded=%d",
               fsBundleID ?: @"(none)", fsEnabled, fsAccentStrip, fsReveal, fsExcluded);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        FSNotificationCallback, (__bridge CFStringRef)kFSReloadNotifName,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    Class rowViewClass = NSClassFromString(@"NSTableRowView");
    Class tableViewClass = NSClassFromString(@"NSTableView");
    Class styleDataClass = NSClassFromString(@"NSTableViewStyleData");
    Class sidebarSelectionClass = NSClassFromString(@"NSTableRowSidebarSelectionView");

    if (!rowViewClass || !tableViewClass) {
        FSDebugLog(@"FATAL: NSTableRowView or NSTableView not found");
        return;
    }

    // === Hide Liquid Glass pill (let system create it, but make it invisible) ===

    // 1. NSTableRowSidebarSelectionView.updateLayer → no-op
    if (sidebarSelectionClass) {
        FSSwizzle(sidebarSelectionClass, @selector(updateLayer),
                  (IMP)FS_SIDEBAR_SELECTION_updateLayer, &orig_sidebarSel_updateLayer);
        // 2. Hide pill when added to view hierarchy
        Method superMethod = class_getInstanceMethod([NSView class], @selector(didMoveToSuperview));
        if (superMethod) {
            orig_sidebarSel_didMoveToSuperview = method_getImplementation(superMethod);
            class_addMethod(sidebarSelectionClass, @selector(didMoveToSuperview),
                            (IMP)FS_SIDEBAR_SELECTION_didMoveToSuperview, "v@:");
        }
    }

    // 3. drawBackgroundInRect: → no-op for source-list rows
    FSSwizzle(rowViewClass, @selector(drawBackgroundInRect:),
              (IMP)FS_rowView_drawBackgroundInRect, &orig_rowView_drawBackgroundInRect);

    // 4. _drawSourceListHighlightInRect: → no-op
    FSSwizzle(tableViewClass, @selector(_drawSourceListHighlightInRect:),
              (IMP)FS_tableView_drawSourceListHighlight, &orig_tableView_drawSourceListHL);

    // 5. _drawSourceListHighlightInRect:isButtedUpRow: → no-op
    FSSwizzle(tableViewClass, @selector(_drawSourceListHighlightInRect:isButtedUpRow:),
              (IMP)FS_tableView_drawSourceListHighlightButt, &orig_tableView_drawSourceListHLButt);

    // 6. wantsSolariumAppearance → NO
    if (styleDataClass) {
        FSSwizzle(styleDataClass, @selector(wantsSolariumAppearance),
                  (IMP)FS_styleData_wantsSolariumAppearance, &orig_styleData_wantsSolarium);
    }

    // === Reveal + accent strip ===

    // 7. updateTrackingAreas → hover tracking
    FSSwizzle(rowViewClass, @selector(updateTrackingAreas),
              (IMP)FS_rowView_updateTrackingAreas, &orig_rowView_updateTrackingAreas);

    // 8. mouseEntered:
    FSSwizzle(rowViewClass, @selector(mouseEntered:),
              (IMP)FS_rowView_mouseEntered, &orig_rowView_mouseEntered);

    // 9. mouseExited:
    FSSwizzle(rowViewClass, @selector(mouseExited:),
              (IMP)FS_rowView_mouseExited, &orig_rowView_mouseExited);

    // 10. mouseMoved:
    FSSwizzle(rowViewClass, @selector(mouseMoved:),
              (IMP)FS_rowView_mouseMoved, &orig_rowView_mouseMoved);

    // 11. drawRect: → reveal + accent strip
    FSSwizzle(rowViewClass, @selector(drawRect:),
              (IMP)FS_rowView_drawRect, &orig_rowView_drawRect);

    FSDebugLog(@"all swizzles installed (accent=%d reveal=%d)", fsAccentStrip, fsReveal);
}
