//
//  AppDelegate.m
//  CorridorKey for Final Cut Pro — wrapper app
//
//  The FxPlug lives in this app's PlugIns folder; launching the app once
//  registers it with PlugInKit. The window also manages the Python render
//  server (ck_server.py) and installs the Final Cut Pro effect template.
//

#import "AppDelegate.h"
#import "CKClient.h"

static NSString *const kRepoKey = @"CorridorKeyRepoPath";
static NSString *const kPythonKey = @"CorridorKeyPythonPath";
static NSString *const kPortKey = @"CorridorKeyPort";
static NSString *const kAgentLabel = @"com.corridorkey.fxplug.server";
static const int kDefaultPort = 47823;

@interface AppDelegate ()
@property (strong) NSWindow *window;
@property (strong) NSTextField *repoField;
@property (strong) NSTextField *pythonField;
@property (strong) NSTextField *portField;
@property (strong) NSTextField *statusLabel;
@property (strong) NSButton *agentCheckbox;
@property (strong) NSTask *serverTask;
@property (strong) NSTimer *statusTimer;
@end

@implementation AppDelegate

#pragma mark Paths

- (NSString *)logPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/CorridorKey"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"ck_server.log"];
}

- (NSString *)agentPlistPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/LaunchAgents/%@.plist", kAgentLabel]];
}

- (NSString *)repoPath { return [self.repoField.stringValue stringByExpandingTildeInPath]; }

- (NSString *)pythonPath {
    NSString *p = [self.pythonField.stringValue stringByExpandingTildeInPath];
    if (p.length == 0) p = [[self repoPath] stringByAppendingPathComponent:@"venv/bin/python"];
    return p;
}

- (int)port {
    int p = self.portField.intValue;
    return (p >= 1024 && p <= 65535) ? p : kDefaultPort;
}

#pragma mark UI

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame {
    NSTextField *l = [NSTextField labelWithString:text];
    l.frame = frame;
    [self.window.contentView addSubview:l];
    return l;
}

- (NSTextField *)field:(NSString *)value frame:(NSRect)frame {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    f.stringValue = value ?: @"";
    f.target = self;
    f.action = @selector(savePrefs:);
    [self.window.contentView addSubview:f];
    return f;
}

- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.frame = frame;
    [self.window.contentView addSubview:b];
    return b;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenu];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *repo = [d stringForKey:kRepoKey] ?: @"~/CorridorKey2.0";
    NSString *python = [d stringForKey:kPythonKey] ?: @"";
    NSInteger port = [d integerForKey:kPortKey] ?: kDefaultPort;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 330)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"CorridorKey for Final Cut Pro";
    [self.window center];

    CGFloat y = 280;
    [self label:@"CorridorKey folder:" frame:NSMakeRect(20, y, 140, 20)];
    self.repoField = [self field:repo frame:NSMakeRect(165, y - 2, 320, 24)];
    [self button:@"Choose…" action:@selector(chooseRepo:) frame:NSMakeRect(490, y - 4, 90, 28)];
    y -= 36;
    [self label:@"Python:" frame:NSMakeRect(20, y, 140, 20)];
    self.pythonField = [self field:python frame:NSMakeRect(165, y - 2, 320, 24)];
    self.pythonField.placeholderString = @"<folder>/venv/bin/python";
    y -= 36;
    [self label:@"Port:" frame:NSMakeRect(20, y, 140, 20)];
    self.portField = [self field:[NSString stringWithFormat:@"%ld", (long)port] frame:NSMakeRect(165, y - 2, 80, 24)];

    y -= 48;
    [self button:@"Start Server" action:@selector(startServer:) frame:NSMakeRect(160, y, 130, 32)];
    [self button:@"Stop Server" action:@selector(stopServer:) frame:NSMakeRect(295, y, 130, 32)];
    [self button:@"Open Log" action:@selector(openLog:) frame:NSMakeRect(430, y, 130, 32)];
    y -= 36;
    self.agentCheckbox = [NSButton checkboxWithTitle:@"Start server automatically at login"
                                              target:self action:@selector(toggleAgent:)];
    self.agentCheckbox.frame = NSMakeRect(163, y, 380, 24);
    self.agentCheckbox.state = [[NSFileManager defaultManager] fileExistsAtPath:[self agentPlistPath]]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [self.window.contentView addSubview:self.agentCheckbox];
    y -= 44;
    [self button:@"Install Final Cut Pro Effect" action:@selector(installTemplate:) frame:NSMakeRect(160, y, 265, 32)];

    self.statusLabel = [self label:@"Checking server…" frame:NSMakeRect(20, 18, 560, 34)];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.maximumNumberOfLines = 2;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
                                                      selector:@selector(refreshStatus)
                                                      userInfo:nil repeats:YES];
    [self refreshStatus];
}

- (void)buildMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit CorridorKey" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSApp.mainMenu = bar;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    // A server we launched ourselves goes away with the app. Use the login
    // agent to keep one running while Final Cut Pro is open.
    if (self.serverTask.isRunning) [self.serverTask terminate];
}

- (void)savePrefs:(id)sender {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.repoField.stringValue forKey:kRepoKey];
    [d setObject:self.pythonField.stringValue forKey:kPythonKey];
    [d setInteger:[self port] forKey:kPortKey];
}

- (void)chooseRepo:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.message = @"Choose your CorridorKey2.0 folder (the one containing ck_server.py)";
    if ([panel runModal] == NSModalResponseOK) {
        self.repoField.stringValue = [panel.URL.path stringByAbbreviatingWithTildeInPath];
        [self savePrefs:nil];
    }
}

- (void)setStatus:(NSString *)text { self.statusLabel.stringValue = text; }

- (void)refreshStatus {
    int port = [self port];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *ping = [CKClient pingPort:port timeout:1.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ping == nil) {
                [self setStatus:[NSString stringWithFormat:@"Server: not running on port %d.", port]];
            } else if ([ping[@"ready"] boolValue]) {
                [self setStatus:[NSString stringWithFormat:@"Server: ready on port %d (device: %@).", port, ping[@"device"]]];
            } else if (ping[@"error"] != nil && ping[@"error"] != [NSNull null]) {
                [self setStatus:[NSString stringWithFormat:@"Server error: %@", ping[@"error"]]];
            } else {
                [self setStatus:@"Server: loading model weights…"];
            }
        });
    });
}

#pragma mark Server

- (BOOL)checkInstall {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *script = [[self repoPath] stringByAppendingPathComponent:@"ck_server.py"];
    if (![fm fileExistsAtPath:script]) {
        [self alert:@"ck_server.py not found" info:[NSString stringWithFormat:@"Looked in %@. Choose your CorridorKey2.0 folder.", [self repoPath]]];
        return NO;
    }
    if (![fm isExecutableFileAtPath:[self pythonPath]]) {
        [self alert:@"Python not found" info:[NSString stringWithFormat:@"%@ isn't executable. Create the venv (see fcpx/README.md) or set the Python path.", [self pythonPath]]];
        return NO;
    }
    return YES;
}

- (NSArray<NSString *> *)serverArguments {
    return @[[[self repoPath] stringByAppendingPathComponent:@"ck_server.py"],
             @"--port", [NSString stringWithFormat:@"%d", [self port]]];
}

- (void)startServer:(id)sender {
    [self savePrefs:nil];
    if ([CKClient pingPort:[self port] timeout:1.0] != nil) {
        [self setStatus:@"Server is already running."];
        return;
    }
    if (![self checkInstall]) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self agentPlistPath]]) {
        [self launchctl:@[@"kickstart", @"-k", [self agentTarget]]];
        return;
    }
    NSString *log = [self logPath];
    [[NSFileManager defaultManager] createFileAtPath:log contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:log];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:[self pythonPath]];
    task.arguments = [self serverArguments];
    task.currentDirectoryURL = [NSURL fileURLWithPath:[self repoPath]];
    task.standardOutput = out;
    task.standardError = out;
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PYTHONUNBUFFERED"] = @"1";
    env[@"PYTORCH_ENABLE_MPS_FALLBACK"] = @"1";
    task.environment = env;
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        [self alert:@"Couldn't start the server" info:err.localizedDescription];
        return;
    }
    self.serverTask = task;
    [self setStatus:@"Server starting… (first start loads ~5 GB of weights)"];
}

- (void)stopServer:(id)sender {
    if (self.serverTask.isRunning) {
        [self.serverTask terminate];
        self.serverTask = nil;
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:[self agentPlistPath]]) {
        [self launchctl:@[@"kill", @"SIGTERM", [self agentTarget]]];
    } else {
        [self setStatus:@"No server started from this app (one started in Terminal must be stopped there)."];
        return;
    }
    [self setStatus:@"Server stopping…"];
}

- (void)openLog:(id)sender {
    NSString *log = [self logPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:log]) {
        [[NSFileManager defaultManager] createFileAtPath:log contents:nil attributes:nil];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:log]];
}

#pragma mark Login agent

- (NSString *)agentTarget {
    return [NSString stringWithFormat:@"gui/%d/%@", getuid(), kAgentLabel];
}

- (int)launchctl:(NSArray<NSString *> *)args {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    t.arguments = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return -1;
    [t waitUntilExit];
    return t.terminationStatus;
}

- (void)toggleAgent:(id)sender {
    [self savePrefs:nil];
    NSString *plistPath = [self agentPlistPath];
    if (self.agentCheckbox.state == NSControlStateValueOn) {
        if (![self checkInstall]) { self.agentCheckbox.state = NSControlStateValueOff; return; }
        if (self.serverTask.isRunning) { [self.serverTask terminate]; self.serverTask = nil; }
        NSDictionary *plist = @{
            @"Label": kAgentLabel,
            @"ProgramArguments": [@[[self pythonPath]] arrayByAddingObjectsFromArray:[self serverArguments]],
            @"WorkingDirectory": [self repoPath],
            @"RunAtLoad": @YES,
            @"KeepAlive": @{@"SuccessfulExit": @NO},
            @"ThrottleInterval": @30,
            @"ProcessType": @"Interactive",
            @"EnvironmentVariables": @{@"PYTHONUNBUFFERED": @"1", @"PYTORCH_ENABLE_MPS_FALLBACK": @"1"},
            @"StandardOutPath": [self logPath],
            @"StandardErrorPath": [self logPath],
        };
        [[NSFileManager defaultManager] createDirectoryAtPath:[plistPath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if (![plist writeToURL:[NSURL fileURLWithPath:plistPath] error:nil]) {
            [self alert:@"Couldn't write the login agent" info:plistPath];
            self.agentCheckbox.state = NSControlStateValueOff;
            return;
        }
        [self launchctl:@[@"bootout", [self agentTarget]]];
        int rc = [self launchctl:@[@"bootstrap", [NSString stringWithFormat:@"gui/%d", getuid()], plistPath]];
        [self setStatus:rc == 0 ? @"Login agent installed; server starting…"
                                : [NSString stringWithFormat:@"launchctl bootstrap failed (%d); see %@", rc, plistPath]];
    } else {
        [self launchctl:@[@"bootout", [self agentTarget]]];
        [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
        [self setStatus:@"Login agent removed."];
    }
}

#pragma mark Motion template

- (void)installTemplate:(id)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Bundle layout: Motion Templates/CorridorKey/CorridorKey.moef. Installed as
    // Effects.localized/CorridorKey (category)/CorridorKey (template)/CorridorKey.moef
    NSString *src = [[NSBundle mainBundle] pathForResource:@"Motion Templates" ofType:nil];
    NSString *effects = [NSHomeDirectory() stringByAppendingPathComponent:
                         @"Movies/Motion Templates.localized/Effects.localized"];
    NSString *dst = [effects stringByAppendingPathComponent:@"CorridorKey"];
    NSError *err = nil;
    if (![fm fileExistsAtPath:src]) {
        [self alert:@"Template missing from app bundle" info:src ?: @"(nil)"];
        return;
    }
    if (![fm createDirectoryAtPath:effects withIntermediateDirectories:YES attributes:nil error:&err]) {
        [self alert:@"Couldn't create the Motion Templates folder" info:err.localizedDescription];
        return;
    }
    if ([fm fileExistsAtPath:dst]) {
        [fm trashItemAtURL:[NSURL fileURLWithPath:dst] resultingItemURL:nil error:nil];
    }
    if (![fm copyItemAtPath:src toPath:dst error:&err]) {
        [self alert:@"Couldn't install the effect" info:err.localizedDescription];
        return;
    }
    [self alert:@"Effect installed"
           info:@"In Final Cut Pro, find it in the Effects browser under the CorridorKey category "
                @"(restart Final Cut Pro if it was open)."];
}

- (void)alert:(NSString *)message info:(NSString *)info {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = message;
    a.informativeText = info ?: @"";
    [a runModal];
}

@end
