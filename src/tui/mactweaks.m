// mactweaks.m — Terminal UI for MacTweaks control panel
// Requires: ncurses, Foundation
//
// Build: clang -fobjc-arc -framework Foundation -lncurses -o mactweaks mactweaks.m
//
// Controls:
//   ↑↓      Navigate
//   Space   Toggle on/off
//   Enter   Edit / expand
//   a       Add excluded app
//   d       Delete excluded app
//   q/Esc   Quit / back

#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#include <ncurses.h>
#include <string.h>
#include <stdlib.h>

#pragma mark - Constants

#define kCornerFixDomain       @"com.makalin.cornerfix"
#define kCFXReloadNotif        @"com.makalin.cornerfix.reload"
#define kRLSettingsPath        @"~/Library/Application Support/MacTweaks/rightlights.plist"
#define kRLReloadNotif         @"com.local.rightlights.reload"

#pragma mark - Utility

static void ensureDir(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static void postDarwinNotification(NSString *name) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name,
        NULL,
        NULL,
        TRUE);
}

#pragma mark - CornerFix settings (reads/writes ~/Library/Application Support/CornerFix/settings.plist)

#define kCFXSettingsFile @"~/Library/Application Support/CornerFix/settings.plist"

static NSString *cfSettingsPath(void) {
    return [kCFXSettingsFile stringByExpandingTildeInPath];
}

static NSMutableDictionary *cfLoadSettings(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:cfSettingsPath()];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static void cfSaveSettings(NSDictionary *settings) {
    ensureDir(cfSettingsPath());
    [settings writeToFile:cfSettingsPath() atomically:YES];
    postDarwinNotification(kCFXReloadNotif);
}

static BOOL cfGetEnabled(void) {
    id v = cfLoadSettings()[@"enabled"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
}

static void cfSetEnabled(BOOL enabled) {
    NSMutableDictionary *s = cfLoadSettings();
    s[@"enabled"] = @(enabled);
    cfSaveSettings(s);
}

static double cfGetRadius(void) {
    id v = cfLoadSettings()[@"radius"];
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0.0;
}

static void cfSetRadius(double radius) {
    NSMutableDictionary *s = cfLoadSettings();
    s[@"radius"] = @(radius);
    cfSaveSettings(s);
}

static NSArray *cfGetExcludedApps(void) {
    NSDictionary *appSettings = cfLoadSettings()[@"appSettings"];
    if (![appSettings isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *bundleID in appSettings) {
        NSDictionary *entry = appSettings[bundleID];
        NSNumber *en = entry[@"enabled"];
        if (en && ![en boolValue]) {
            [result addObject:bundleID];
        }
    }
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

static void cfAddExclusion(NSString *bundleID) {
    NSMutableDictionary *s = cfLoadSettings();
    NSMutableDictionary *appSettings = s[@"appSettings"] ? [s[@"appSettings"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = appSettings[bundleID] ? [appSettings[bundleID] mutableCopy] : [NSMutableDictionary dictionary];
    entry[@"enabled"] = @NO;
    appSettings[bundleID] = entry;
    s[@"appSettings"] = appSettings;
    cfSaveSettings(s);
}

static void cfRemoveExclusion(NSString *bundleID) {
    NSMutableDictionary *s = cfLoadSettings();
    NSMutableDictionary *appSettings = s[@"appSettings"] ? [s[@"appSettings"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = appSettings[bundleID] ? [appSettings[bundleID] mutableCopy] : [NSMutableDictionary dictionary];
    entry[@"enabled"] = @YES;
    appSettings[bundleID] = entry;
    s[@"appSettings"] = appSettings;
    cfSaveSettings(s);
}

#pragma mark - RightLights settings (via notifyd state — works in sandbox)

// notifyd state protocol:
//   com.local.rightlights.global  — 0=disabled, 1=enabled
//   com.local.rightlights.app.<bundleID> — 0=excluded, 1=not-excluded
// Plist file is written for persistence across reboots (non-sandboxed apps only).

#define kRLSettingsPath        @"~/Library/Application Support/MacTweaks/rightlights.plist"
#define kRLReloadNotif         @"com.local.rightlights.reload"
#define kRLGlobalStateName     @"com.local.rightlights.global"
#define kRLAppStatePrefix      @"com.local.rightlights.app."

static NSString *rlSettingsPath(void) {
    return [kRLSettingsPath stringByExpandingTildeInPath];
}

// Read global enabled from notifyd
// Encoding: 0=never set (default: enabled), 1=enabled, 2=disabled
static BOOL rlGetEnabled(void) {
    int token = -1;
    uint32_t s = notify_register_check([kRLGlobalStateName UTF8String], &token);
    if (s != NOTIFY_STATUS_OK) return YES;

    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return (state != 2);
}

// Write global enabled to notifyd + plist
static void rlSetEnabled(BOOL enabled) {
    int token = -1;
    notify_register_check([kRLGlobalStateName UTF8String], &token);
    uint64_t state = enabled ? 1 : 2;
    notify_set_state(token, state);
    notify_cancel(token);

    // Write to plist for persistence
    NSMutableDictionary *p = [NSMutableDictionary dictionaryWithContentsOfFile:rlSettingsPath()] ?: [NSMutableDictionary dictionary];
    p[@"enabled"] = @(enabled);
    ensureDir(rlSettingsPath());
    [p writeToFile:rlSettingsPath() atomically:YES];

    // Notify all running apps
    postDarwinNotification(kRLReloadNotif);
}

// Check if a bundle ID is excluded (via notifyd)
// Encoding: 0=never set (default: not excluded), 1=not excluded, 2=excluded
static BOOL rlIsExcluded(NSString *bundleID) {
    NSString *name = [kRLAppStatePrefix stringByAppendingString:bundleID];
    int token = -1;
    uint32_t s = notify_register_check([name UTF8String], &token);
    if (s != NOTIFY_STATUS_OK) return NO;

    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return (state == 2);
}

// Read excluded apps from plist (for display in TUI)
static NSArray *rlGetExcludedApps(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:rlSettingsPath()];
    NSArray *bids = d[@"excludedBundleIDs"];
    if (![bids isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *bid in bids) {
        if (rlIsExcluded(bid)) [result addObject:bid];
    }
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

// Set exclusion for a specific app
static void rlSetExcluded(NSString *bundleID, BOOL excluded) {
    NSString *name = [kRLAppStatePrefix stringByAppendingString:bundleID];
    int token = -1;
    notify_register_check([name UTF8String], &token);
    uint64_t state = excluded ? 2 : 1;
    notify_set_state(token, state);
    notify_cancel(token);

    // Update plist for persistence
    NSMutableDictionary *p = [NSMutableDictionary dictionaryWithContentsOfFile:rlSettingsPath()] ?: [NSMutableDictionary dictionary];
    NSMutableArray *bids = [p[@"excludedBundleIDs"] mutableCopy] ?: [NSMutableArray array];
    if (excluded && ![bids containsObject:bundleID]) {
        [bids addObject:bundleID];
    } else if (!excluded) {
        [bids removeObject:bundleID];
    }
    p[@"excludedBundleIDs"] = bids;
    ensureDir(rlSettingsPath());
    [p writeToFile:rlSettingsPath() atomically:YES];

    postDarwinNotification(kRLReloadNotif);
}

static void rlAddExclusion(NSString *bundleID) {
    rlSetExcluded(bundleID, YES);
}

static void rlRemoveExclusion(NSString *bundleID) {
    rlSetExcluded(bundleID, NO);
}

#pragma mark - ncurses helpers

static void drawBox(int y, int x, int h, int w) {
    mvaddch(y, x, ACS_ULCORNER);
    mvaddch(y, x + w, ACS_URCORNER);
    mvaddch(y + h, x, ACS_LLCORNER);
    mvaddch(y + h, x + w, ACS_LRCORNER);
    mvhline(y, x + 1, ACS_HLINE, w - 1);
    mvhline(y + h, x + 1, ACS_HLINE, w - 1);
    mvvline(y + 1, x, ACS_VLINE, h - 1);
    mvvline(y + 1, x + w, ACS_VLINE, h - 1);
}

static double promptDouble(const char *prompt, double current) {
    int row = LINES - 3;
    move(row, 0);
    clrtoeol();
    mvprintw(row, 2, "%s (current: %.1f): ", prompt, current);
    refresh();

    char buf[32];
    int len = 0;
    int ch;
    echo();
    curs_set(1);
    while ((ch = getch()) != '\n') {
        if (ch == 27) { noecho(); curs_set(0); move(row, 0); clrtoeol(); refresh(); return -1; }
        if (ch == KEY_BACKSPACE || ch == 127) {
            if (len > 0) { len--; int cx, cy; getyx(stdscr, cy, cx); move(cy, cx-1); delch(); }
        } else if (len < 31 && ((ch >= '0' && ch <= '9') || ch == '.' || ch == '-')) {
            buf[len++] = (char)ch;
        }
    }
    noecho();
    curs_set(0);
    buf[len] = '\0';
    move(row, 0);
    clrtoeol();
    refresh();
    if (len == 0) return -1;
    return atof(buf);
}

#pragma mark - App list builder

// Build a deduplicated, sorted list of all GUI apps (running + installed)
// Each entry: { "name": NSString, "bundleID": NSString }
static NSArray *buildAppList(void) {
    NSMutableDictionary *byBundleID = [NSMutableDictionary dictionary];

    // 1. Running apps with regular activation policy (real GUI apps only)
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSString *bid = app.bundleIdentifier;
        NSString *name = app.localizedName;
        if (!bid || !name) continue;
        byBundleID[bid] = @{ @"name": name, @"bundleID": bid };
    }

    // 2. Installed apps from /Applications and ~/Applications
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = @[@"/Applications", [@"~/Applications" stringByExpandingTildeInPath]];
    for (NSString *dir in dirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *appPath = [dir stringByAppendingPathComponent:item];
            NSBundle *bundle = [NSBundle bundleWithPath:appPath];
            NSString *bid = bundle.bundleIdentifier;
            if (!bid) continue;
            if (!byBundleID[bid]) {
                byBundleID[bid] = @{ @"name": [item stringByDeletingPathExtension], @"bundleID": bid };
            }
        }
    }

    // Sort by name (case-insensitive)
    return [byBundleID.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
        }];
}

// Check if a bundle ID is in the excluded list
static BOOL isExcluded(NSString *bundleID, BOOL isCornerFix) {
    if (isCornerFix) {
        NSArray *excl = cfGetExcludedApps();
        return [excl containsObject:bundleID];
    } else {
        return rlIsExcluded(bundleID);
    }
}

// Toggle exclusion for a bundle ID
static void toggleExclusion(NSString *bundleID, BOOL isCornerFix) {
    if (isExcluded(bundleID, isCornerFix)) {
        if (isCornerFix) cfRemoveExclusion(bundleID);
        else             rlRemoveExclusion(bundleID);
    } else {
        if (isCornerFix) cfAddExclusion(bundleID);
        else             rlAddExclusion(bundleID);
    }
}

#pragma mark - Exclusions picker (scrollable app list)

static void showExclusions(NSString *title, BOOL isCornerFix) {
    NSArray *apps = buildAppList();
    int count = (int)apps.count;
    int selected = 0;
    int scrollOffset = 0;
    int ch;

    while (1) {
        clear();

        int boxW = 72;
        int boxH = LINES - 4;
        if (boxH > count + 7) boxH = (int)count + 7;
        if (boxH < 10) boxH = 10;
        int boxX = (COLS - boxW) / 2;
        int boxY = 1;

        drawBox(boxY, boxX, boxH, boxW);

        // Title
        attron(A_BOLD);
        mvprintw(boxY, boxX + 2, " Exclusions - %s ", [title UTF8String] ?: "");
        attroff(A_BOLD);

        // Column headers
        int colCheck = boxX + 3;
        int colName  = boxX + 8;
        int colID    = boxX + 38;
        int listY = boxY + 2;
        int listH = boxH - 4;  // space for title + footer

        attron(A_DIM);
        mvprintw(listY, colCheck, "   ");
        mvprintw(listY, colName,  "App Name");
        mvprintw(listY, colID,    "Bundle ID");
        attroff(A_DIM);

        listY++;
        listH--;

        // Ensure scrollOffset is valid
        if (scrollOffset < 0) scrollOffset = 0;
        if (scrollOffset > count - listH) scrollOffset = count - listH;
        if (scrollOffset < 0) scrollOffset = 0;

        // Adjust scroll if selected is out of view
        if (selected < scrollOffset) scrollOffset = selected;
        if (selected >= scrollOffset + listH) scrollOffset = selected - listH + 1;

        // Draw visible items
        int visibleEnd = scrollOffset + listH;
        if (visibleEnd > count) visibleEnd = count;

        for (int i = scrollOffset; i < visibleEnd; i++) {
            int row = listY + (i - scrollOffset);
            NSDictionary *app = apps[i];
            NSString *name = app[@"name"];
            NSString *bid = app[@"bundleID"];
            BOOL excluded = isExcluded(bid, isCornerFix);

            if (i == selected) attron(A_REVERSE);

            // Checkbox
            if (excluded) {
                attron(A_BOLD);
                mvprintw(row, colCheck, "[x]");
                attroff(A_BOLD);
            } else {
                mvprintw(row, colCheck, "[ ]");
            }

            // App name (truncate to fit)
            const char *nameStr = [name UTF8String] ?: "?";
            char nameBuf[30];
            strncpy(nameBuf, nameStr, 29);
            nameBuf[29] = '\0';
            mvprintw(row, colName, "%s", nameBuf);

            // Bundle ID (truncate to fit)
            const char *bidStr = [bid UTF8String] ?: "?";
            char bidBuf[34];
            strncpy(bidBuf, bidStr, 33);
            bidBuf[33] = '\0';
            mvprintw(row, colID, "%s", bidBuf);

            if (i == selected) attroff(A_REVERSE);
        }

        // Scroll indicator
        if (count > listH) {
            int indicatorY = listY + (int)((float)scrollOffset / (count - listH) * (listH - 1));
            mvaddch(indicatorY, boxX + boxW, ACS_RARROW);
        }

        // Footer
        int footerY = boxY + boxH - 1;
        attron(A_DIM);
        mvprintw(footerY, boxX + 2, " %d apps  |  ^/v Navigate  Space Toggle  Esc Back ", count);
        attroff(A_DIM);

        refresh();

        ch = getch();
        switch (ch) {
            case KEY_UP:
            case 'k':
                if (selected > 0) selected--;
                break;
            case KEY_DOWN:
            case 'j':
                if (selected < count - 1) selected++;
                break;
            case KEY_PPAGE: // Page Up
                selected -= listH;
                if (selected < 0) selected = 0;
                break;
            case KEY_NPAGE: // Page Down
                selected += listH;
                if (selected > count - 1) selected = count - 1;
                break;
            case ' ':       // Space — toggle exclusion
            case '\n':
            case KEY_ENTER: {
                NSDictionary *app = apps[selected];
                NSString *bid = app[@"bundleID"];
                toggleExclusion(bid, isCornerFix);
                break;
            }
            case 27: // Esc
            case 'b':
                return;
            case 'q':
                return;
        }
    }
}

#pragma mark - Bundle ID to app name mapping

// Build a lookup table from bundle ID → display name, using the same
// source as buildAppList (running apps + /Applications).
// Built once at startup, reused for displaying exclusion names.
static NSDictionary *sBundleIDToName = nil;

static void buildBundleNameMap(void) {
    if (sBundleIDToName) return;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSString *bid = app.bundleIdentifier;
        NSString *name = app.localizedName;
        if (bid && name) map[bid] = name;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[@"/Applications", [@"~/Applications" stringByExpandingTildeInPath]]) {
        if (![fm fileExistsAtPath:dir]) continue;
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSBundle *b = [NSBundle bundleWithPath:[dir stringByAppendingPathComponent:item]];
            if (!b.bundleIdentifier) continue;
            if (!map[b.bundleIdentifier])
                map[b.bundleIdentifier] = [item stringByDeletingPathExtension];
        }
    }
    sBundleIDToName = map;
}

// Return a comma-separated string of excluded app display names
static NSString *excludedAppNames(BOOL isCornerFix) {
    NSArray *bids = isCornerFix ? cfGetExcludedApps() : rlGetExcludedApps();
    if (bids.count == 0) return @"none";

    NSMutableArray *names = [NSMutableArray array];
    for (NSString *bid in bids) {
        NSString *name = sBundleIDToName[bid];
        [names addObject:name ?: bid];
    }
    return [names componentsJoinedByString:@", "];
}

#pragma mark - Main menu

typedef enum {
    MENU_CF_TOGGLE = 0,
    MENU_CF_RADIUS,
    MENU_CF_EXCLUDE,
    MENU_RL_TOGGLE,
    MENU_RL_EXCLUDE,
    MENU_QUIT,
    MENU_COUNT
} MenuItem;

static const char *menuLabels[] = {
    "Corner Fix",
    "  Radius",
    "  Excluded Apps",
    "Right Lights",
    "  Excluded Apps",
    "Quit",
};

static void drawMainMenu(int selected) {
    clear();

    int w = 56;
    int h = MENU_COUNT + 8;
    int x = (COLS - w) / 2;
    int y = 1;

    drawBox(y, x, h, w);

    // Title
    attron(A_BOLD);
    mvprintw(y, x + 2, " MacTweaks Control Panel ");
    attroff(A_BOLD);

    // Menu items
    for (int i = 0; i < MENU_COUNT; i++) {
        int row = y + 3 + i;
        if (i == MENU_QUIT) row++;  // gap before quit

        if (i == selected) attron(A_REVERSE);

        mvprintw(row, x + 4, "%s", menuLabels[i]);

        // Right-align the value
        switch (i) {
            case MENU_CF_TOGGLE: {
                BOOL on = cfGetEnabled();
                int valX = x + w - 8;
                if (on) { attron(A_BOLD); mvprintw(row, valX, "[ON]"); attroff(A_BOLD); }
                else    { attron(A_DIM);  mvprintw(row, valX, "[OFF]"); attroff(A_DIM); }
                break;
            }
            case MENU_CF_RADIUS: {
                double r = cfGetRadius();
                mvprintw(row, x + w - 10, "%.0f pt", r);
                break;
            }
            case MENU_CF_EXCLUDE: {
                NSUInteger c = cfGetExcludedApps().count;
                mvprintw(row, x + w - 10, "(%lu)", (unsigned long)c);
                if (c > 0) {
                    if (i == selected) attroff(A_REVERSE);
                    attron(A_DIM);
                    NSString *names = excludedAppNames(YES);
                    const char *ns = [names UTF8String] ?: "";
                    char buf[48];
                    strncpy(buf, ns, 47);
                    buf[47] = '\0';
                    mvprintw(row + 1, x + 6, "%s", buf);
                    attroff(A_DIM);
                    if (i == selected) attron(A_REVERSE);
                }
                break;
            }
            case MENU_RL_TOGGLE: {
                BOOL on = rlGetEnabled();
                int valX = x + w - 8;
                if (on) { attron(A_BOLD); mvprintw(row, valX, "[ON]"); attroff(A_BOLD); }
                else    { attron(A_DIM);  mvprintw(row, valX, "[OFF]"); attroff(A_DIM); }
                break;
            }
            case MENU_RL_EXCLUDE: {
                NSUInteger c = rlGetExcludedApps().count;
                mvprintw(row, x + w - 10, "(%lu)", (unsigned long)c);
                if (c > 0) {
                    if (i == selected) attroff(A_REVERSE);
                    attron(A_DIM);
                    NSString *names = excludedAppNames(NO);
                    const char *ns = [names UTF8String] ?: "";
                    char buf[48];
                    strncpy(buf, ns, 47);
                    buf[47] = '\0';
                    mvprintw(row + 1, x + 6, "%s", buf);
                    attroff(A_DIM);
                    if (i == selected) attron(A_REVERSE);
                }
                break;
            }
        }

        if (i == selected) attroff(A_REVERSE);
    }

    // Footer
    int footerY = y + h - 2;
    attron(A_DIM);
    mvprintw(footerY, x + 2, "^/v Navigate  Space Toggle  Enter Edit  q Quit");
    attroff(A_DIM);

    refresh();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Build bundle ID → name map for displaying exclusions
        buildBundleNameMap();

        // Sync RightLights plist → notifyd state on startup
        {
            NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:rlSettingsPath()];
            BOOL enabled = [p[@"enabled"] isKindOfClass:[NSNumber class]] ? [p[@"enabled"] boolValue] : YES;
            int token = -1;
            notify_register_check([kRLGlobalStateName UTF8String], &token);
            notify_set_state(token, enabled ? 1 : 2);
            notify_cancel(token);
            NSArray *bids = p[@"excludedBundleIDs"];
            if ([bids isKindOfClass:[NSArray class]]) {
                for (NSString *bid in bids) {
                    NSString *name = [kRLAppStatePrefix stringByAppendingString:bid];
                    notify_register_check([name UTF8String], &token);
                    notify_set_state(token, 2);  // excluded
                    notify_cancel(token);
                }
            }
        }

        // ncurses init
        initscr();
        cbreak();
        noecho();
        curs_set(0);
        keypad(stdscr, TRUE);

        int selected = 0;
        int ch;

        while (1) {
            drawMainMenu(selected);
            ch = getch();

            switch (ch) {
                case KEY_UP:
                case 'k':
                    if (selected > 0) selected--;
                    else selected = MENU_COUNT - 1;
                    // skip gap (no gap item, but keep logic clean)
                    break;

                case KEY_DOWN:
                case 'j':
                    if (selected < MENU_COUNT - 1) selected++;
                    else selected = 0;
                    break;

                case ' ':
                    if (selected == MENU_CF_TOGGLE) {
                        cfSetEnabled(!cfGetEnabled());
                    } else if (selected == MENU_RL_TOGGLE) {
                        rlSetEnabled(!rlGetEnabled());
                    }
                    break;

                case '\n':
                case KEY_ENTER:
                    switch (selected) {
                        case MENU_CF_TOGGLE:
                            cfSetEnabled(!cfGetEnabled());
                            break;
                        case MENU_CF_RADIUS: {
                            double r = promptDouble("Corner radius", cfGetRadius());
                            if (r >= 0) cfSetRadius(r);
                            break;
                        }
                        case MENU_CF_EXCLUDE:
                            showExclusions(@"Corner Fix", YES);
                            break;
                        case MENU_RL_TOGGLE:
                            rlSetEnabled(!rlGetEnabled());
                            break;
                        case MENU_RL_EXCLUDE:
                            showExclusions(@"Right Lights", NO);
                            break;
                        case MENU_QUIT:
                            endwin();
                            return 0;
                    }
                    break;

                case 'q':
                    endwin();
                    return 0;

                case 27: // Esc
                    endwin();
                    return 0;
            }
        }
    }
    return 0;
}
