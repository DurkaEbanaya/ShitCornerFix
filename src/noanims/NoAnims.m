// NoAnims.m — Complete animation elimination for macOS 26 Tahoe
//
// Swizzles:
//   1. NSAnimationContext.runAnimationGroup: → instant (CATransaction)
//   2. NSAnimationContext.duration/setDuration: → 0.0
//   3. NSWindow.setFrame:display:animate: → animate=NO
//   4. NSWindow.miniaturize: → capture own window (CGWindowListCreateImage +
//      IncludingWindow, no Screen Recording permission needed for own window),
//      alpha=0, call original, setMiniwindowImage: (custom Dock thumbnail).
//      SKIPPED in fullscreen (different WindowServer path, causes black content).
//   5. NSWindow.deminiaturize: → alpha=0, call original, restore alpha=1.0 after 0.7s.
//      SKIPPED in fullscreen.
//   6. NSAnimation.duration/setDuration: → 0.0 (covers NSSpringAnimation)
//   7. NSSpringAnimation.initWithDuration: → 0.0
//   8. CALayer.addAnimation:forKey: → skip (kills CA-level animations)
//   9. NSWindow.toggleFullScreen: → passthrough (property injection below handles it)
//  10. _NSFullScreenTransitionOverlayWindow.startEnter/ExitFullScreenAnimationWithDuration:
//      → duration=0 (kills crossfade)
//  11. _NSEnterFullScreenTransitionController.start → doInProcessAnimation=NO,
//      nonAnimatingSlideAnimation=YES (kills in-process animation + Space slide)
//  12. _NSExitFullScreenTransitionController.start → doInProcessAnimation=NO, duration=0
//
// The alpha trick for minimize/deminiaturize: WindowServer renders the
// animation from the window's actual content. By setting alphaValue=0,
// the animation runs on a transparent window — user sees nothing.
// miniaturize: captures the window image via CGWindowListCreateImage BEFORE
// setting alpha=0, then sets it as the Dock thumbnail via the private API
// setMiniwindowImage:. This gives both invisible animation AND visible
// thumbnail. deminiaturize: restores alpha=1.0 via dispatch_after(0.7s)
// after the WindowServer animation finishes. Both always use 1.0 (never
// stored "original" alpha) — the old code stored origAlpha which could get
// stuck at 0, causing windows to permanently disappear.
//
// Fullscreen: the transition uses _NSFullScreenTransitionOverlayWindow whose
// layers are hosted in WindowServer (_hostsLayersInWindowServer), so app-level
// alpha and CALayer.addAnimation skip don't affect it. We swizzle the overlay
// window's animation methods (duration=0) and transition controllers
// (doInProcessAnimation=NO, nonAnimatingSlideAnimation=YES). NOTE: in macOS 26
// Tahoe these swizzles are installed but never called — the system uses a
// different code path. Fullscreen transition animation is currently NOT
// eliminated; deferred.
//
// This doesn't break Finder desktop icons because the desktop window is
// never miniaturized (no miniaturize: call on it).

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/log.h>
#import <dlfcn.h>

static os_log_t sLog;
static BOOL sNAEnabled = YES;

static NSString *const kNAStateName    = @"com.local.noanims.enabled";
static NSString *const kNAReloadName   = @"com.local.noanims.reload";
static NSString *const kNASettingsPath = @"~/Library/Application Support/MacTweaks/noanims.plist";

#define NALog(fmt, ...) os_log_info(sLog, fmt, ##__VA_ARGS__)

// ── CGWindowListCreateImage (removed from macOS 15+ SDK, loaded via dlsym) ─
// CGWindowListCreateImage was removed from the SDK headers in macOS 15 but
// still exists in the CoreGraphics dylib at runtime. We load it via dlsym
// to capture window thumbnails for the Dock. The constant values are stable
// ABI (from the original CGWindow.h):
//   kCGWindowListOptionAll              = 0
//   kCGWindowListOptionOnScreenBelowWindow = (1 << 0) = 1
//   kCGWindowListOptionOnScreenAboveWindow = (1 << 1) = 2
//   kCGWindowListOptionOnScreenOnly     = (1 << 2) = 4
//   kCGWindowListOptionIncludingWindow  = (1 << 3) = 8
//   kCGWindowListExcludeDesktopElements = (1 << 4) = 16
typedef CGImageRef (*NA_CGWindowListCreateImage_t)(CGRect, uint32_t, uint32_t, uint32_t);
static NA_CGWindowListCreateImage_t NA_CGWindowListCreateImage = NULL;
#define NA_kCGWindowListOptionOnScreenOnly     (1u << 2)  // 4
#define NA_kCGWindowListOptionIncludingWindow  (1u << 3)  // 8
#define NA_kCGWindowImageDefault               0u

// ── Original IMPs ────────────────────────────────────────

static double  (*orig_ctx_duration)(id, SEL);
static void    (*orig_ctx_setDuration)(id, SEL, double);
static void    (*orig_runAnimGroup)(Class, SEL, void(^)(NSAnimationContext *), void(^)(void));
static void    (*orig_setFrameDisplayAnimate)(id, SEL, NSRect, BOOL, BOOL);
static void    (*orig_miniaturize)(id, SEL, id);
static void    (*orig_deminiaturize)(id, SEL, id);
static void    (*orig_toggleFullScreen)(id, SEL, id);
// Fullscreen transition
static void    (*orig_enterFSAnim)(id, SEL, NSTimeInterval, BOOL, void(^)(void));
static void    (*orig_exitFSAnim)(id, SEL, NSTimeInterval, BOOL, CGFloat, void(^)(void));
static void    (*orig_enterFSStart)(id, SEL);
static void    (*orig_exitFSStart)(id, SEL);
static double  (*orig_anim_duration)(id, SEL);
static void    (*orig_anim_setDuration)(id, SEL, double);
static id      (*orig_spring_initWithDuration)(id, SEL, NSTimeInterval);
static void    (*orig_addAnimation)(id, SEL, CAAnimation *, NSString *);

// ── Settings ─────────────────────────────────────────────

static int NAReadPlistEnabled(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        [kNASettingsPath stringByExpandingTildeInPath]];
    if (!d || d[@"enabled"] == nil) return -1;
    return [d[@"enabled"] boolValue] ? 1 : 0;
}

static int NAReadNotifydState(void) {
    int token;
    if (notify_register_check([kNAStateName UTF8String], &token) != NOTIFY_STATUS_OK)
        return 0;
    uint32_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return (int)state;
}

static void NAWriteNotifydState(int state) {
    int token;
    notify_register_check([kNAStateName UTF8String], &token);
    notify_set_state(token, (uint32_t)state);
    notify_cancel(token);
}

#define NAShouldActivate() (sNAEnabled)

// ── Swizzle helpers ──────────────────────────────────────

static IMP SwizzleInstance(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NALog("FAILED: no method %s on %@", sel_getName(sel), NSStringFromClass(cls)); return NULL; }
    IMP orig = method_setImplementation(m, newImp);
    NALog("swizzled %@.%s", NSStringFromClass(cls), sel_getName(sel));
    return orig;
}

static IMP SwizzleClass(Class cls, SEL sel, IMP newImp) {
    Class meta = object_getClass(cls);
    Method m = class_getInstanceMethod(meta, sel);
    if (!m) { NALog("FAILED: no class method %s on %@", sel_getName(sel), NSStringFromClass(cls)); return NULL; }
    IMP orig = method_setImplementation(m, newImp);
    NALog("swizzled +%@.%s", NSStringFromClass(cls), sel_getName(sel));
    return orig;
}

// ── Swizzled: NSAnimationContext ─────────────────────────

static double NA_ctx_duration(id self, SEL _cmd) {
    if (NAShouldActivate()) return 0.0;
    return orig_ctx_duration ? orig_ctx_duration(self, _cmd) : 0.25;
}

static void NA_ctx_setDuration(id self, SEL _cmd, double dur) {
    if (NAShouldActivate()) {
        if (orig_ctx_setDuration) orig_ctx_setDuration(self, _cmd, 0.0);
        return;
    }
    if (orig_ctx_setDuration) orig_ctx_setDuration(self, _cmd, dur);
}

static void NA_runAnimGroup(Class cls, SEL _cmd,
                            void(^block)(NSAnimationContext *),
                            void(^handler)(void)) {
    if (NAShouldActivate()) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        NSAnimationContext *ctx = [NSAnimationContext currentContext];
        if (orig_ctx_setDuration) orig_ctx_setDuration(ctx, @selector(setDuration:), 0.0);
        if (block) block(ctx);
        [CATransaction commit];
        if (handler) handler();
        return;
    }
    if (orig_runAnimGroup) orig_runAnimGroup(cls, _cmd, block, handler);
}

// ── Swizzled: NSWindow ───────────────────────────────────

static void NA_setFrameDisplayAnimate(id self, SEL _cmd, NSRect frame, BOOL display, BOOL animate) {
    if (!orig_setFrameDisplayAnimate) return;
    if (NAShouldActivate() && animate) {
        orig_setFrameDisplayAnimate(self, _cmd, frame, display, NO);
    } else {
        orig_setFrameDisplayAnimate(self, _cmd, frame, display, animate);
    }
}

// ── Swizzled: NSWindow miniaturize / deminiaturize ───────

// Helper: restore alpha to 1.0 if window is visible (not minimised)
static void NARestoreAlphaIfNeeded(NSWindow *window) {
    if (!window) return;
    if (window.alphaValue < 1.0f) {
        ((void(*)(id,SEL,CGFloat))objc_msgSend)(window, @selector(setAlphaValue:), 1.0f);
    }
}

// miniaturize: → capture window image, alpha=0, call original, set Dock thumbnail.
//
// The alpha trick makes the minimize animation invisible, but WindowServer
// captures the Dock thumbnail from the live window content at alpha=0 →
// blank thumbnail. To fix this, we capture the window image BEFORE setting
// alpha=0 (via CGWindowListCreateImage, which captures through WindowServer
// including titlebar), then set it as the Dock thumbnail via the private
// API setMiniwindowImage: after minimize.
//
// Flow:
//   1. CGWindowListCreateImage captures the window at alpha=1.0 (visible)
//   2. setAlphaValue:0 → window content transparent
//   3. orig_miniaturize → WindowServer animates transparent content (invisible)
//   4. setMiniwindowImage: → Dock displays our pre-captured image as thumbnail
//
// setMiniwindowImage: is a private NSWindow method that overrides the Dock's
// default thumbnail (which is captured from live window content). We check
// for its existence at runtime and fall back to _setMiniwindowImage:.
//
// Alpha is restored to 1.0 ONLY in deminiaturize:, which is called for all
// standard restore paths (app icon click, thumbnail click, keyboard shortcut).
// We always restore to 1.0 (never stored "original" alpha) — if deminiaturize
// somehow fails to fire, the NSWindowDidBecomeKey safety net restores alpha.
static void NA_miniaturize(id self, SEL _cmd, id sender) {
    if (NAShouldActivate()) {
        NSWindow *window = (NSWindow *)self;

        // Skip alpha trick in fullscreen — minimize in fullscreen uses a
        // different WindowServer path. The alpha trick causes black content
        // and the window doesn't actually minimize. Just call original.
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
            if (orig_miniaturize) orig_miniaturize(self, _cmd, sender);
            return;
        }

        // 1. Capture window image BEFORE setting alpha=0.
        // Using kCGWindowListOptionIncludingWindow with the window's own
        // windowNumber captures only that window's content (including titlebar).
        // This does NOT require Screen Recording permission because the app
        // is capturing its own window — not compositing screen content from
        // other processes. CGRectNull = capture at the window's full bounds.
        NSImage *thumbnail = nil;
        NSInteger winNum = [window windowNumber];
        if (NA_CGWindowListCreateImage && winNum > 0) {
            CGImageRef cgImg = NA_CGWindowListCreateImage(
                CGRectNull,
                NA_kCGWindowListOptionIncludingWindow,
                (uint32_t)winNum,
                NA_kCGWindowImageDefault
            );
            if (cgImg) {
                // Use logical (point) dimensions as NSImage size.
                // CGWindowListCreateImage captures at pixel resolution (2x on
                // Retina). Passing the logical size tells NSImage the correct
                // points-per-pixel ratio, preventing distortion.
                NSSize logicalSize = window.frame.size;
                if (logicalSize.width > 0 && logicalSize.height > 0) {
                    thumbnail = [[NSImage alloc] initWithCGImage:cgImg size:logicalSize];
                } else {
                    thumbnail = [[NSImage alloc] initWithCGImage:cgImg size:NSZeroSize];
                }
                CGImageRelease(cgImg);
            }
        }

        // 2. Set alpha=0 to make the minimize animation invisible
        ((void(*)(id,SEL,CGFloat))objc_msgSend)(self, @selector(setAlphaValue:), 0.0f);

        // 3. Call original miniaturize
        if (orig_miniaturize) orig_miniaturize(self, _cmd, sender);

        // 4. Set custom Dock thumbnail via private API.
        // Called immediately after miniaturize: — the window is in minimized
        // state, so setMiniwindowImage: should take effect. The Dock reads
        // this image when displaying the thumbnail, overriding its default
        // capture from live (transparent) content.
        if (thumbnail) {
            SEL imgSel = @selector(setMiniwindowImage:);
            if (![window respondsToSelector:imgSel]) {
                imgSel = @selector(_setMiniwindowImage:);
            }
            if ([window respondsToSelector:imgSel]) {
                ((void(*)(id,SEL,id))objc_msgSend)(window, imgSel, thumbnail);
            }
        }

        return;
    }
    if (orig_miniaturize) orig_miniaturize(self, _cmd, sender);
}

// deminiaturize: → alpha=0 (already 0 from miniaturize, but set again for
// safety), call original, restore alpha=1.0 after 0.7s.
// WindowServer renders the deminiaturize animation from Dock to desktop.
// We keep alpha=0 during the animation (0.7s covers scale/genie duration),
// then restore to 1.0.
//
// CRITICAL: always restore to 1.0, never store "original" alpha.
// dispatch_after(0.7s) is used because dispatch_async fires too early —
// before WindowServer starts the animation, making it visible.
static void NA_deminiaturize(id self, SEL _cmd, id sender) {
    if (NAShouldActivate()) {
        NSWindow *window = (NSWindow *)self;

        // Skip alpha trick in fullscreen — deminiaturize in fullscreen uses
        // a different WindowServer path. Just call original.
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
            if (orig_deminiaturize) orig_deminiaturize(self, _cmd, sender);
            return;
        }

        ((void(*)(id,SEL,CGFloat))objc_msgSend)(self, @selector(setAlphaValue:), 0.0f);
        if (orig_deminiaturize) orig_deminiaturize(self, _cmd, sender);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ((void(*)(id,SEL,CGFloat))objc_msgSend)(self, @selector(setAlphaValue:), 1.0f);
        });
        return;
    }
    if (orig_deminiaturize) orig_deminiaturize(self, _cmd, sender);
}

// ── Swizzled: NSAnimation ────────────────────────────────

// toggleFullScreen: → alpha=0, call original, restore alpha after delay
// WindowServer renders the fullscreen scale/fade transition from the
// window's content. With alpha=0, the transition is invisible — the
// window appears to instantly enter/exit fullscreen. dispatch_after
// restores alpha after the WindowServer transition completes (~0.7s).
// toggleFullScreen: → we don't use alpha trick here (it doesn't work for
// fullscreen — the transition uses _NSFullScreenTransitionOverlayWindow
// whose layers are hosted in WindowServer, not affected by app-level alpha).
// Instead, we swizzle the transition controller and overlay window directly.
static void NA_toggleFullScreen(id self, SEL _cmd, id sender) {
    if (orig_toggleFullScreen) orig_toggleFullScreen(self, _cmd, sender);
}

// ── Swizzled: Fullscreen Transition ──────────────────────
// The fullscreen transition uses _NSFullScreenTransitionOverlayWindow
// whose layers are hosted in WindowServer (_hostsLayersInWindowServer).
// CALayer.addAnimation skip doesn't help because the animation is not
// in the app's CALayer tree. We hook the overlay window's animation
// methods to use duration=0, and the transition controllers to disable
// in-process animation.

// Overlay window: startEnterFullScreenAnimationWithDuration:reduced:completionHandler:
static void NA_enterFSAnim(id self, SEL _cmd, NSTimeInterval duration, BOOL reduced, void(^handler)(void)) {
    if (orig_enterFSAnim) orig_enterFSAnim(self, _cmd, 0.0, reduced, handler);
}

// Overlay window: startExitFullScreenAnimationWithDuration:reduced:cornerRadius:completionHandler:
static void NA_exitFSAnim(id self, SEL _cmd, NSTimeInterval duration, BOOL reduced, CGFloat cornerRadius, void(^handler)(void)) {
    if (orig_exitFSAnim) orig_exitFSAnim(self, _cmd, 0.0, reduced, cornerRadius, handler);
}

// Enter transition controller: start → disable in-process animation
static void NA_enterFSStart(id self, SEL _cmd) {
    NALog("enterFSStart: doInProcessAnimation=NO nonAnimatingSlideAnimation=YES");
    @try {
        [self setValue:@NO forKey:@"doInProcessAnimation"];
        [self setValue:@YES forKey:@"nonAnimatingSlideAnimation"];
    } @catch (NSException *e) {
        NALog("enterFSStart: props failed: %{public}@", e);
    }
    if (orig_enterFSStart) orig_enterFSStart(self, _cmd);
}

// Exit transition controller: start → disable in-process animation + duration=0
static void NA_exitFSStart(id self, SEL _cmd) {
    NALog("exitFSStart: doInProcessAnimation=NO duration=0");
    @try {
        [self setValue:@NO forKey:@"doInProcessAnimation"];
        [self setValue:@0.0 forKey:@"duration"];
    } @catch (NSException *e) {
        NALog("exitFSStart: props failed: %{public}@", e);
    }
    if (orig_exitFSStart) orig_exitFSStart(self, _cmd);
}

// ── Swizzled: NSAnimation ────────────────────────────────

static double NA_anim_duration(id self, SEL _cmd) {
    if (NAShouldActivate()) return 0.0;
    return orig_anim_duration ? orig_anim_duration(self, _cmd) : 0.25;
}

static void NA_anim_setDuration(id self, SEL _cmd, double dur) {
    if (NAShouldActivate()) {
        if (orig_anim_setDuration) orig_anim_setDuration(self, _cmd, 0.0);
        return;
    }
    if (orig_anim_setDuration) orig_anim_setDuration(self, _cmd, dur);
}

// NSSpringAnimation.initWithDuration: → 0.0
static id NA_spring_init(id self, SEL _cmd, NSTimeInterval duration) {
    if (NAShouldActivate()) {
        duration = 0.0;
    }
    if (orig_spring_initWithDuration) return orig_spring_initWithDuration(self, _cmd, duration);
    return self;
}

// ── Swizzled: CALayer ────────────────────────────────────

static void NA_addAnimation(id self, SEL _cmd, CAAnimation *anim, NSString *key) {
    if (NAShouldActivate()) {
        return;
    }
    if (orig_addAnimation) orig_addAnimation(self, _cmd, anim, key);
}

// ── Reload callback ──────────────────────────────────────

static void NAReloadCallback(CFNotificationCenterRef center,
                              void *observer, CFStringRef name,
                              const void *object, CFDictionaryRef userInfo) {
    int state = NAReadNotifydState();
    if (state == 1)      sNAEnabled = YES;
    else if (state == 2) sNAEnabled = NO;
    else {
        int pv = NAReadPlistEnabled();
        sNAEnabled = (pv == -1) ? YES : (pv == 1);
    }
    NALog("reload: state=%d enabled=%d", state, sNAEnabled);
}

// ── Constructor ──────────────────────────────────────────

__attribute__((constructor))
static void NAConstructor(void) {
    if (!NSClassFromString(@"NSApplication")) return;

    sLog = os_log_create("com.local.noanims", "debug");

    // Load CGWindowListCreateImage via dlsym (removed from macOS 15+ SDK
    // but still present in CoreGraphics dylib at runtime)
    NA_CGWindowListCreateImage = (NA_CGWindowListCreateImage_t)
        dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    NALog("CGWindowListCreateImage: %p", NA_CGWindowListCreateImage);

    int state = NAReadNotifydState();
    if (state == 1)       sNAEnabled = YES;
    else if (state == 2)  sNAEnabled = NO;
    else {
        int pv = NAReadPlistEnabled();
        if (pv == -1) {
            sNAEnabled = YES;
            NAWriteNotifydState(1);
        } else {
            sNAEnabled = (pv == 1);
            NAWriteNotifydState(pv ? 1 : 2);
        }
    }

    NALog("constructor: state=%d enabled=%d", state, sNAEnabled);

    // NSAnimationContext
    orig_ctx_duration    = (double(*)(id,SEL)) SwizzleInstance([NSAnimationContext class], @selector(duration), (IMP)NA_ctx_duration);
    orig_ctx_setDuration = (void(*)(id,SEL,double)) SwizzleInstance([NSAnimationContext class], @selector(setDuration:), (IMP)NA_ctx_setDuration);
    orig_runAnimGroup    = (void(*)(Class,SEL,void(^)(NSAnimationContext*),void(^)(void))) SwizzleClass([NSAnimationContext class], @selector(runAnimationGroup:completionHandler:), (IMP)NA_runAnimGroup);

    // NSWindow
    orig_setFrameDisplayAnimate = (void(*)(id,SEL,NSRect,BOOL,BOOL)) SwizzleInstance([NSWindow class], @selector(setFrame:display:animate:), (IMP)NA_setFrameDisplayAnimate);
    orig_miniaturize            = (void(*)(id,SEL,id)) SwizzleInstance([NSWindow class], @selector(miniaturize:), (IMP)NA_miniaturize);
    orig_deminiaturize          = (void(*)(id,SEL,id)) SwizzleInstance([NSWindow class], @selector(deminiaturize:), (IMP)NA_deminiaturize);
    orig_toggleFullScreen       = (void(*)(id,SEL,id)) SwizzleInstance([NSWindow class], @selector(toggleFullScreen:), (IMP)NA_toggleFullScreen);

    // Fullscreen transition: overlay window + transition controllers
    // NOTE: In macOS 26 Tahoe, these swizzles are installed but never called.
    // The system uses a different code path for fullscreen transitions.
    // Kept for potential future effectiveness; fullscreen animation is
    // currently not eliminated.
    {
        Class overlayClass = NSClassFromString(@"_NSFullScreenTransitionOverlayWindow");
        if (overlayClass) {
            orig_enterFSAnim = (void(*)(id,SEL,NSTimeInterval,BOOL,void(^)(void)))
                SwizzleInstance(overlayClass,
                    sel_registerName("startEnterFullScreenAnimationWithDuration:reduced:completionHandler:"),
                    (IMP)NA_enterFSAnim);
            orig_exitFSAnim = (void(*)(id,SEL,NSTimeInterval,BOOL,CGFloat,void(^)(void)))
                SwizzleInstance(overlayClass,
                    sel_registerName("startExitFullScreenAnimationWithDuration:reduced:cornerRadius:completionHandler:"),
                    (IMP)NA_exitFSAnim);
        }

        Class enterTC = NSClassFromString(@"_NSEnterFullScreenTransitionController");
        if (enterTC) {
            orig_enterFSStart = (void(*)(id,SEL))
                SwizzleInstance(enterTC, @selector(start), (IMP)NA_enterFSStart);
        }

        Class exitTC = NSClassFromString(@"_NSExitFullScreenTransitionController");
        if (exitTC) {
            orig_exitFSStart = (void(*)(id,SEL))
                SwizzleInstance(exitTC, @selector(start), (IMP)NA_exitFSStart);
        }
    }

    // NSAnimation (covers NSSpringAnimation)
    Class nsAnim = [NSAnimation class];
    if (nsAnim) {
        orig_anim_duration    = (double(*)(id,SEL)) SwizzleInstance(nsAnim, @selector(duration), (IMP)NA_anim_duration);
        orig_anim_setDuration = (void(*)(id,SEL,double)) SwizzleInstance(nsAnim, @selector(setDuration:), (IMP)NA_anim_setDuration);
    }

    // NSSpringAnimation
    Class springAnim = NSClassFromString(@"NSSpringAnimation");
    if (springAnim) {
        orig_spring_initWithDuration = (id(*)(id,SEL,NSTimeInterval)) SwizzleInstance(springAnim, @selector(initWithDuration:), (IMP)NA_spring_init);
    }

    // CALayer.addAnimation:forKey: → skip
    orig_addAnimation = (void(*)(id,SEL,CAAnimation*,NSString*)) SwizzleInstance([CALayer class], @selector(addAnimation:forKey:), (IMP)NA_addAnimation);

    // Alpha restore safety net: when a window becomes key or main after
    // being deminiaturised (via Dock thumbnail, app icon, or any other
    // restore path), restore alpha to 1.0. This catches cases where
    // deminiaturize: is not called (e.g. clicking the Dock thumbnail
    // directly), which would leave the window at alpha=0 permanently.
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        if (!NAShouldActivate()) return;
        NARestoreAlphaIfNeeded([n object]);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidDeminiaturizeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        if (!NAShouldActivate()) return;
        NARestoreAlphaIfNeeded([n object]);
    }];

    // Reload notification
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, NAReloadCallback,
        (__bridge CFStringRef)kNAReloadName,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    NALog("init complete: enabled=%d", sNAEnabled);
}
