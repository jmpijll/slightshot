// Review driver for issue #43. Injected with DYLD_INSERT_LIBRARIES into an
// isolated copy of the built app. It opens the production Settings window,
// clicks the production shortcut recorders and posts key events into the app's
// own event queue. After each step it writes step-N.json to SLIGHTSHOT_REVIEW_DIR
// and waits for shot-N.done, so the shell can capture the window between steps.
// It also reports Screen Recording as granted so the copy does not open the
// first-run permission prompt; the review never captures the screen.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>

static bool reviewScreenCaptureAccess(void) { return true; }
__attribute__((used, section("__DATA,__interpose"))) static struct {
    const void *replacement;
    const void *replacee;
} interposers[] = {{(const void *)reviewScreenCaptureAccess, (const void *)CGPreflightScreenCaptureAccess}};

static NSString *reviewDir;
static NSMutableArray *results;
static int stepIndex;

static NSWindow *settingsWindow(void) {
    for (NSWindow *window in NSApp.windows)
        if ([window.title isEqualToString:@"Slightshot Settings"]) return window;
    return nil;
}

static void collectRecorders(NSView *view, NSMutableArray *out) {
    if ([NSStringFromClass(view.class) containsString:@"ShortcutRecorderView"]) [out addObject:view];
    for (NSView *sub in view.subviews) collectRecorders(sub, out);
}

static NSArray<NSView *> *recorders(void) {
    NSMutableArray *found = [NSMutableArray array];
    collectRecorders(settingsWindow().contentView, found);
    return [found sortedArrayUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        CGFloat ya = [a convertRect:a.bounds toView:nil].origin.y;
        CGFloat yb = [b convertRect:b.bounds toView:nil].origin.y;
        return ya > yb ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static BOOL selectTab(NSView *view, NSString *title) {
    if ([view isKindOfClass:NSTabView.class]) {
        NSTabView *tabs = (NSTabView *)view;
        for (NSTabViewItem *item in tabs.tabViewItems)
            if ([item.label isEqualToString:title]) { [tabs selectTabViewItem:item]; return YES; }
    }
    if ([view isKindOfClass:NSSegmentedControl.class]) {
        NSSegmentedControl *segments = (NSSegmentedControl *)view;
        for (NSInteger i = 0; i < segments.segmentCount; i++)
            if ([[segments labelForSegment:i] isEqualToString:title]) {
                segments.selectedSegment = i;
                [segments sendAction:segments.action to:segments.target];
                return YES;
            }
    }
    for (NSView *sub in view.subviews) if (selectTab(sub, title)) return YES;
    return NO;
}

static void clickRecorder(NSUInteger index) {
    NSView *view = recorders()[index];
    NSWindow *window = view.window;
    NSPoint point = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0
                                      timestamp:NSProcessInfo.processInfo.systemUptime
                                   windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [view mouseDown:down];
}

static void pressKey(unsigned short keyCode, NSEventModifierFlags flags, NSString *characters) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:settingsWindow().windowNumber context:nil
                                    characters:characters charactersIgnoringModifiers:characters
                                     isARepeat:NO keyCode:keyCode];
    [NSApp postEvent:event atStart:NO];
}

/// Whether this process can claim ⌘⇧9 exclusively right now, i.e. Slightshot released it.
static OSStatus probeCaptureAreaHotKey(void) {
    EventHotKeyRef ref = NULL;
    OSStatus status = RegisterEventHotKey(kVK_ANSI_9, cmdKey | shiftKey, (EventHotKeyID){'RVW4', 1},
                                          GetApplicationEventTarget(), kEventHotKeyExclusive, &ref);
    if (ref) UnregisterEventHotKey(ref);
    return status;
}

static NSDictionary *storedShortcuts(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return @{
        @"captureArea": [defaults stringForKey:@"hotkey.captureArea"] ?: @"",
        @"saveFullScreen": [defaults stringForKey:@"hotkey.saveFullScreen"] ?: @"",
        @"copyFullScreen": [defaults stringForKey:@"hotkey.copyFullScreen"] ?: @"",
    };
}

static void writeResults(void) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [json writeToFile:[reviewDir stringByAppendingPathComponent:@"driver-results.json"] atomically:YES];
}

static void acceptShortcuts(void);

static void waitForShot(int shot, dispatch_block_t then) {
    NSString *done = [reviewDir stringByAppendingPathComponent:[NSString stringWithFormat:@"shot-%d.done", shot]];
    if ([NSFileManager.defaultManager fileExistsAtPath:done]) { then(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        waitForShot(shot, then);
    });
}

static void requestShot(NSString *name, NSInteger windowNumber, dispatch_block_t then) {
    int shot = ++stepIndex;
    NSDictionary *request = @{@"name": name, @"window": @(windowNumber)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    [json writeToFile:[reviewDir stringByAppendingPathComponent:[NSString stringWithFormat:@"step-%d.json", shot]] atomically:YES];
    waitForShot(shot, then);
}

static void record(NSString *step, NSDictionary *extra) {
    NSMutableDictionary *entry = [@{@"step": step, @"stored": storedShortcuts()} mutableCopy];
    [entry addEntriesFromDictionary:extra];
    [results addObject:entry];
    writeResults();
}

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static NSString *fn(unichar c) { return [NSString stringWithCharacters:&c length:1]; }

static id swiftIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

/// Reads the production status menu after AppKit's own update callback.
static void readStatusMenu(void) {
    NSStatusItem *item = swiftIvar(swiftIvar(NSApp.delegate, "statusItem"), "statusItem");
    NSMenu *menu = item.menu;
    [menu.delegate menuNeedsUpdate:menu];
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *menuItem in menu.itemArray) {
        if (menuItem.isSeparatorItem) continue;
        NSMutableString *codes = [NSMutableString string];
        for (NSUInteger i = 0; i < menuItem.keyEquivalent.length; i++)
            [codes appendFormat:@"%s0x%04X", i ? " " : "", [menuItem.keyEquivalent characterAtIndex:i]];
        [items addObject:@{@"title": menuItem.title, @"keyEquivalent": codes,
                           @"modifierMask": @(menuItem.keyEquivalentModifierMask)}];
    }
    record(@"status menu items", @{@"items": items});
    [NSApp terminate:nil];
}

static void run(void) {
    results = [NSMutableArray array];
    [(id)NSApp.delegate applicationShouldHandleReopen:NSApp hasVisibleWindows:NO];
    after(1.0, ^{
        NSWindow *window = settingsWindow();
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        BOOL tab = selectTab(window.contentView.superview, @"Shortcuts");
        after(1.0, ^{
            record(@"open Shortcuts tab", @{@"tabSelected": @(tab), @"recorders": @(recorders().count)});
            if (recorders().count != 3) { [NSApp terminate:nil]; return; }
            requestShot(@"mac-shortcuts-default", window.windowNumber, ^{
                clickRecorder(0);
                OSStatus whileRecording = probeCaptureAreaHotKey();
                pressKey(kVK_ANSI_A, NSEventModifierFlagShift, @"A");
                after(0.8, ^{
                    record(@"Capture area: press Shift-A", @{@"probeCmdShift9WhileRecording": @(whileRecording)});
                    requestShot(@"mac-shift-only-rejected", window.windowNumber, ^{
                        pressKey(kVK_Return, 0, @"\r");
                        after(0.5, ^{
                            OSStatus afterRecording = probeCaptureAreaHotKey();
                            clickRecorder(2);
                            pressKey(kVK_ANSI_8, NSEventModifierFlagCommand | NSEventModifierFlagShift, @"8");
                            after(0.8, ^{
                                record(@"Copy full screen: press Cmd-Shift-8", @{@"probeCmdShift9AfterRecording": @(afterRecording)});
                                requestShot(@"mac-duplicate-rejected", window.windowNumber, ^{
                                    pressKey(kVK_Return, 0, @"\r");
                                    after(0.5, ^{
                                        clickRecorder(2);
                                        pressKey(kVK_Space, NSEventModifierFlagCommand, @" ");
                                        after(0.8, ^{
                                            record(@"Copy full screen: press Cmd-Space", @{});
                                            requestShot(@"mac-reserved-rejected", window.windowNumber, ^{
                                                pressKey(kVK_Return, 0, @"\r");
                                                after(0.5, ^{ acceptShortcuts(); });
                                            });
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
}

static void acceptShortcuts(void) {
    NSWindow *window = settingsWindow();
    clickRecorder(0);
    pressKey(kVK_F13, NSEventModifierFlagFunction, fn(NSF13FunctionKey));
    after(0.6, ^{
        clickRecorder(1);
        pressKey(kVK_Space, NSEventModifierFlagControl | NSEventModifierFlagOption, @" ");
        after(0.6, ^{
            clickRecorder(2);
            pressKey(kVK_RightArrow, NSEventModifierFlagControl | NSEventModifierFlagOption
                     | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad, fn(NSRightArrowFunctionKey));
            after(0.8, ^{
                record(@"accept F13, Ctrl-Option-Space, Ctrl-Option-Right", @{});
                requestShot(@"mac-accepted", window.windowNumber, ^{ readStatusMenu(); });
            });
        });
    });
}

__attribute__((constructor)) static void startReview(void) {
    reviewDir = NSProcessInfo.processInfo.environment[@"SLIGHTSHOT_REVIEW_DIR"];
    if (!reviewDir) return;
    after(3.0, ^{ run(); });
}
