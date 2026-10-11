#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// Diagnostic application only. Synthetic installed metadata and isolated defaults.
// The only updater operation is Sparkle's information-only discovery API.
@interface DiscoveryProbe : NSObject <NSApplicationDelegate, SPUUpdaterDelegate>
@property NSWindow *window;
@property NSTextField *resultLabel;
@property NSTextField *feedLabel;
@property NSTextField *detailLabel;
@property SPUUpdater *updater;
@property SPUStandardUserDriver *driver;
@property NSMutableArray *events;
@property NSMutableDictionary *report;
@property NSString *outputDirectory;
@property NSString *label;
@property NSString *expectedResult;
@property BOOL completed;
@end

static NSString *Argument(NSString *name, NSString *fallback) {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [args indexOfObject:name];
    return index != NSNotFound && index + 1 < args.count ? args[index + 1] : fallback;
}

static NSTextField *Label(NSView *view, NSString *text, NSRect frame, CGFloat size, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
    label.textColor = color;
    [view addSubview:label];
    return label;
}

@implementation DiscoveryProbe
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSBundle *bundle = NSBundle.mainBundle;
    self.events = [NSMutableArray array];
    self.outputDirectory = Argument(@"--output", @"/tmp/slightshot-updater-1.5.1/output");
    self.label = Argument(@"--label", @"Information-only discovery");
    self.expectedResult = Argument(@"--expected", @"unspecified");
    [[NSFileManager defaultManager] createDirectoryAtPath:self.outputDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    self.report = [@{
        @"fixture": @"Automated native AppKit diagnostic harness; synthetic installed bundle metadata; real Sparkle SDK 2.10.0. This is not a pristine published Slightshot binary.",
        @"operation": @"SPUUpdater.checkForUpdateInformation (no update offering, download or installation)",
        @"hostBundleIdentifier": bundle.bundleIdentifier,
        @"hostMarketingVersion": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        @"hostBuild": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"],
        @"feedURL": [bundle objectForInfoDictionaryKey:@"SUFeedURL"],
        @"sourceCommit": Argument(@"--source-commit", @"unspecified"),
        @"phase": self.label,
        @"expectedResult": self.expectedResult,
        @"startedAt": [NSISO8601DateFormatter.new stringFromDate:NSDate.date],
        @"automaticChecks": @NO,
        @"automaticDownloadsAllowed": @NO,
        @"events": self.events
    } mutableCopy];

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 880, 510)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Slightshot updater · isolated Sparkle discovery fixture";
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    NSView *view = self.window.contentView;
    Label(view, @"Slightshot update discovery", NSMakeRect(30, 439, 820, 38), 27, NSColor.labelColor);
    Label(view, self.label, NSMakeRect(30, 399, 820, 28), 17, NSColor.secondaryLabelColor);
    Label(view, @"SYNTHETIC INSTALLED METADATA", NSMakeRect(30, 341, 820, 23), 12, NSColor.secondaryLabelColor);
    Label(view, [NSString stringWithFormat:@"Slightshot %@  ·  build %@",
        self.report[@"hostMarketingVersion"], self.report[@"hostBuild"]], NSMakeRect(30, 299, 820, 40), 25, NSColor.labelColor);
    self.feedLabel = Label(view, @"Fetching appcast through Sparkle…", NSMakeRect(30, 238, 820, 46), 17, NSColor.secondaryLabelColor);
    self.resultLabel = Label(view, @"Checking…", NSMakeRect(30, 160, 820, 64), 29, NSColor.labelColor);
    self.detailLabel = Label(view, @"Waiting for real SPUUpdater delegate callbacks.", NSMakeRect(30, 97, 820, 48), 15, NSColor.secondaryLabelColor);
    Label(view, @"Automated native fixture · Sparkle 2.10.0 · Information-only check\nIsolated bundle ID and preferences; no download or installation.",
        NSMakeRect(30, 23, 820, 54), 12, NSColor.secondaryLabelColor);
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    self.driver = [[SPUStandardUserDriver alloc] initWithHostBundle:bundle delegate:nil];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self.driver delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) {
        self.report[@"result"] = @"configuration-error";
        self.report[@"error"] = error.localizedDescription;
        [self finish];
        return;
    }
    [self.events addObject:@"startUpdater succeeded"];
    [self.updater checkForUpdateInformation];
    [self.events addObject:@"checkForUpdateInformation invoked"];
    [NSTimer scheduledTimerWithTimeInterval:45 repeats:NO block:^(NSTimer *timer) {
        if (!self.completed) {
            self.report[@"result"] = @"timeout";
            [self finish];
        }
    }];
}

- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    NSMutableArray *items = [NSMutableArray array];
    for (SUAppcastItem *item in appcast.items) {
        [items addObject:@{@"marketingVersion": item.displayVersionString, @"build": item.versionString,
            @"downloadURL": item.fileURL.absoluteString ?: @""}];
    }
    self.report[@"appcastItems"] = items;
    [self.events addObject:[NSString stringWithFormat:@"didFinishLoadingAppcast: %lu items", (unsigned long)items.count]];
    if (appcast.items.count) {
        SUAppcastItem *item = appcast.items.firstObject;
        self.feedLabel.stringValue = [NSString stringWithFormat:@"Feed latest: %@  ·  build %@\n%@",
            item.displayVersionString, item.versionString, self.report[@"feedURL"]];
    }
}

- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
    self.report[@"result"] = @"update-found";
    self.report[@"selectedUpdate"] = @{@"marketingVersion": item.displayVersionString, @"build": item.versionString,
        @"downloadURL": item.fileURL.absoluteString ?: @""};
    [self.events addObject:@"didFindValidUpdate"];
    self.resultLabel.stringValue = [NSString stringWithFormat:@"Update found: %@", item.displayVersionString];
    self.resultLabel.textColor = NSColor.systemGreenColor;
    self.detailLabel.stringValue = @"Sparkle's real didFindValidUpdate callback.\nThe information-only check ends without offering an update.";
}

- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error {
    self.report[@"result"] = @"no-update";
    self.report[@"noUpdateError"] = @{@"domain": error.domain, @"code": @(error.code), @"description": error.localizedDescription};
    id reason = error.userInfo[SPUNoUpdateFoundReasonKey];
    if (reason) self.report[@"noUpdateReason"] = reason;
    SUAppcastItem *latest = error.userInfo[SPULatestAppcastItemFoundKey];
    if (latest) self.report[@"latestRejectedItem"] = @{@"marketingVersion": latest.displayVersionString, @"build": latest.versionString};
    [self.events addObject:@"updaterDidNotFindUpdate:error:"];
    self.resultLabel.stringValue = @"Sparkle reports: no update";
    self.resultLabel.textColor = NSColor.systemOrangeColor;
    self.detailLabel.stringValue = @"Actual updaterDidNotFindUpdate:error: callback.\nSparkle compares CFBundleVersion values using its standard comparator.";
}

- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)updateCheck error:(NSError *)error {
    self.report[@"updateCheckType"] = @(updateCheck);
    if (error) self.report[@"cycleError"] = @{@"domain": error.domain, @"code": @(error.code), @"description": error.localizedDescription};
    [self.events addObject:@"didFinishUpdateCycleForUpdateCheck:error:"];
    [self finish];
}

- (void)finish {
    if (self.completed) return;
    self.completed = YES;
    self.report[@"finishedAt"] = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    self.report[@"matchesExpectedResult"] = @([self.report[@"result"] isEqualToString:self.expectedResult]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 250), dispatch_get_main_queue(), ^{
        [self capture];
    });
}

- (void)saveCapture:(NSBitmapImageRep *)bitmap source:(NSString *)source {
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [self.outputDirectory stringByAppendingPathComponent:@"native-discovery.png"];
    NSError *error = nil;
    BOOL saved = [png writeToFile:path options:NSDataWritingAtomic error:&error];
    self.report[@"capture"] = @{@"file": @"native-discovery.png", @"source": source, @"saved": @(saved)};
    if (error) self.report[@"captureError"] = error.localizedDescription;
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    [json writeToFile:[self.outputDirectory stringByAppendingPathComponent:@"discovery-report.json"] atomically:YES];
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--stay-open"]) [NSApp terminate:nil];
}

- (void)captureFallback:(NSError *)error {
    NSView *view = self.window.contentView.superview ?: self.window.contentView;
    [view displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [self.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    }];
    [self saveCapture:bitmap source:[NSString stringWithFormat:@"Native AppKit rendering of the running NSWindow; ScreenCaptureKit unavailable: %@", error.localizedDescription]];
}

- (void)capture {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SCWindow *sharedWindow = nil;
            for (SCWindow *candidate in content.windows) if (candidate.windowID == self.window.windowNumber) sharedWindow = candidate;
            if (!sharedWindow) {
                [self captureFallback:error ?: [NSError errorWithDomain:@"ProbeCapture" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Own window not available"}]];
                return;
            }
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = self.window.frame.size.width * self.window.backingScaleFactor;
            configuration.height = self.window.frame.size.height * self.window.backingScaleFactor;
            configuration.showsCursor = NO;
            configuration.ignoreShadowsSingleWindow = YES;
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:sharedWindow];
            [SCScreenshotManager captureImageWithFilter:filter configuration:configuration completionHandler:^(CGImageRef image, NSError *captureError) {
                NSBitmapImageRep *bitmap = image ? [[NSBitmapImageRep alloc] initWithCGImage:image] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (bitmap) [self saveCapture:bitmap source:@"ScreenCaptureKit screenshot of the actual running native NSWindow"];
                    else [self captureFallback:captureError];
                });
            }];
        });
    }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        DiscoveryProbe *delegate = [DiscoveryProbe new];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
