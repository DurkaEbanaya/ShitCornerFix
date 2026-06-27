// NoAnims.m — Complete animation elimination for macOS 26 Tahoe
//
// Swizzles:
//   1. NSAnimationContext.runAnimationGroup: → instant (CATransaction)
//   2. NSAnimationContext.duration/setDuration: → 0.0
//   3. NSWindow.setFrame:display:animate: → animate=NO
//   4. NSWindow.miniaturize: → alpha=0 before, WindowServer genie on invisible window
//   5. NSWindow.deminiaturize: → alpha=0 before, alpha=1 after
//   6. NSAnimation.duration/setDuration: → 0.0 (covers NSSpringAnimation)
//   7. NSSpringAnimation.initWithDuration: → 0.0
//   8. CALayer.addAnimation:forKey: → skip (kills CA-level animations)
//
// The alpha trick: WindowServer renders the genie/scale minimize animation
// from the window's actual content. By setting alphaValue=0 instantly (which
// works because addAnimation skip prevents fade), the genie effect runs on
// a fully transparent window — user sees nothing. On deminiaturize, we keep
// alpha=0 during the animation, then restore to 1.0 instantly.
//
// This doesn't break Finder desktop icons because the desktop window is
// never miniaturized (no miniaturize: call on it).

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/log.h>

static os_log_t sLog;
static BOOL sNAEnabled = YES;

static NSString *const kNAStateName    = @"com.local.noanims.enabled";
static NSString *const kNAReloadName   = @"com.local.noanims.reload";
static NSString *const kNASettingsPath = @"~/Library/Application Support/MacTweaks/noanims.plist";

#define NALog(fmt, ...) os_log_debug(sLog, fmt, ##__VA_ARGS__)

// ── Original IMPs ────────────────────────────────────────

static double  (*orig_ctx_duration)(id, SEL);
static void    (*orig_ctx_setDuration)(id, SEL, double);
static void    (*orig_runAnimGroup)(Class, SEL, void(^)(NSAnimationContext *), void(^)(void));
static void    (*orig_setFrameDisplayAnimate)(id, SEL, NSRect, BOOL, BOOL);
static void    (*orig_miniaturize)(id, SEL, id);
static void    (*orig_deminiaturize)(id, SEL, id);
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

// miniaturize: → alpha=0, call original (genie on invisible window)
// WindowServer renders genie from window content. With alpha=0, content is
// transparent — genie effect is invisible to user. Window still properly
// minimizes to Dock (WindowServer tracks state correctly).
static void NA_miniaturize(id self, SEL _cmd, id sender) {
    if (NAShouldActivate()) {
        CGFloat origAlpha = [(NSWindow *)self alphaValue];
        // Instantly invisible (addAnimation skip ensures no fade)
        ((void(*)(id,SEL,CGFloat))objc_msgSend)(self, @selector(setAlphaValue:), 0.0f);
        // Original miniaturize — WindowServer does genie on transparent window
        if (orig_miniaturize) orig_miniaturize(self, _cmd, sender);
        // Store original alpha in window for deminiaturize to restore
        objc_setAssociatedObject(self, "na_origAlpha",
            [NSNumber numberWithFloat:origAlpha], OBJC_ASSOCIATION_RETAIN);
        return;
    }
    if (orig_miniaturize) orig_miniaturize(self, _cmd, sender);
}

// deminiaturize: → alpha=0, call original, restore alpha after delay
// WindowServer renders genie from Dock to desktop. We keep alpha=0 during
// the entire animation, then restore. dispatch_after ensures the restore
// happens AFTER the WindowServer animation completes (~0.5s genie).
static void NA_deminiaturize(id self, SEL _cmd, id sender) {
    if (NAShouldActivate()) {
        NSNumber *origAlphaNum = objc_getAssociatedObject(self, "na_origAlpha");
        CGFloat origAlpha = origAlphaNum ? [origAlphaNum floatValue] : 1.0f;
        // Stay invisible during genie
        ((void(*)(id,SEL,CGFloat))objc_msgSend)(self, @selector(setAlphaValue:), 0.0f);
        // Original deminiaturize — WindowServer does genie on transparent window
        if (orig_deminiaturize) orig_deminiaturize(self, _cmd, sender);
        // Restore alpha after WindowServer animation finishes
        // 0.7s covers genie/scale duration even at slow settings
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ((void(*)(id,SEL,CGFloat))objc_msgSend)(self, @selector(setAlphaValue:), origAlpha);
        });
        return;
    }
    if (orig_deminiaturize) orig_deminiaturize(self, _cmd, sender);
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
