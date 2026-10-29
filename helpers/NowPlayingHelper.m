// Reads macOS's system-wide Now Playing (any app or browser tab: YouTube, Suno, VLC…) for
// the notch. Since macOS 15.4, MediaRemote answers only Apple's own processes, so this is
// a dylib that Apple's /usr/bin/perl loads and runs (see NowPlayingSystem.swift); MediaRemote
// then answers as it does for any Apple tool. Uses only Foundation and MediaRemote.
//
// Out, on stdout: one JSON object per line, sent whenever what's playing changes:
//   {"Player State": "Playing"|"Paused"|"Stopped", "Name", "Artist", "Album",
//    "Duration" (s), "Bundle" (the app, a browser rather than its WebKit helper),
//    "Art" (base64, only when the cover changed)}
// In, on stdin: "playpause", "next" or "previous", one per line. End of input (the app quit
// or crashed) exits, so this never outlives the notch.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientStringFn)(id);
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);

static GetInfoFn getInfo;
static GetClientFn getClient;
static ClientStringFn clientBundle, clientParent;
static IsPlayingFn getIsPlaying;
static SendCommandFn sendCommand;

static dispatch_queue_t queue;          // serial; every MediaRemote reply and all state below
static NSString *lastLine;              // last JSON sent, without art, so repeats are skipped
static NSString *lastTrack;             // app, title, artist and album of the last cover sent
static NSData *lastArt;
static BOOL refreshPending;

/// Sends `message` unless it repeats the last one. The cover goes along when it changed,
/// or when the track did (the next song on the same album has the same cover).
static void emit(NSDictionary *message, NSData *art) {
    NSMutableDictionary *out = [message mutableCopy];
    NSData *plain = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    NSString *line = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
    NSString *track = [NSString stringWithFormat:@"%@|%@|%@|%@", message[@"Bundle"], message[@"Name"],
                       message[@"Artist"], message[@"Album"]];
    BOOL sendArt = art.length > 0 && (![art isEqualToData:lastArt] || ![track isEqualToString:lastTrack]);
    if (!line || ([line isEqualToString:lastLine] && !sendArt)) return;
    if (sendArt) {
        out[@"Art"] = [art base64EncodedStringWithOptions:0];
        lastArt = art;
        lastTrack = track;
    }
    lastLine = line;
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *text(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

/// Asks for the app, play state and track, in that order, then sends one line.
static void refresh(void) {
    refreshPending = NO;
    getClient(queue, ^(id client) {
        NSString *bundle = @"";
        if (client) {
            NSString *parent = clientParent ? clientParent(client) : nil;
            bundle = parent.length ? parent : (clientBundle ? text(clientBundle(client)) : @"");
        }
        getIsPlaying(queue, ^(BOOL playing) {
            getInfo(queue, ^(NSDictionary *info) {
                NSString *title = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                if (info.count == 0 || (title.length == 0 && bundle.length == 0)) {
                    lastArt = nil;
                    lastTrack = nil;
                    emit(@{@"Player State": @"Stopped"}, nil);
                    return;
                }
                NSMutableDictionary *m = [@{
                    @"Player State": playing ? @"Playing" : @"Paused",
                    @"Name": title,
                    @"Artist": text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]),
                    @"Album": text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]),
                    @"Bundle": bundle,
                } mutableCopy];
                id duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
                if ([duration isKindOfClass:[NSNumber class]] && isfinite([duration doubleValue])) m[@"Duration"] = duration;
                id art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                emit(m, [art isKindOfClass:[NSData class]] ? art : nil);
            });
        });
    });
}

/// Changes come in bursts (app, state, info and art separately); one refresh per burst.
static void scheduleRefresh(void) {
    if (refreshPending) return;
    refreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), queue, ^{ refresh(); });
}

static void observe(void *framework, const char *symbol) {
    void *name = dlsym(framework, symbol);
    NSString *notification = name ? *(__unsafe_unretained NSString **)name : [NSString stringWithUTF8String:symbol];
    [[NSNotificationCenter defaultCenter] addObserverForName:notification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        dispatch_async(queue, ^{ scheduleRefresh(); });
    }];
}

/// MediaRemote's command numbers: kMRTogglePlayPause 2, kMRNextTrack 4, kMRPreviousTrack 5.
static void readCommands(void) {
    char buffer[64];
    while (fgets(buffer, sizeof buffer, stdin)) {
        NSString *command = [[NSString stringWithUTF8String:buffer]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        int code = [command isEqualToString:@"playpause"] ? 2
                 : [command isEqualToString:@"next"] ? 4
                 : [command isEqualToString:@"previous"] ? 5 : -1;
        if (code >= 0) sendCommand(code, nil);
    }
    exit(0);
}

/// Called from perl; never returns.
void dn_nowplaying_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "MediaRemote not found\n"); exit(2); }
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    getIsPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    RegisterFn registerForNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getClient || !getIsPlaying || !sendCommand || !registerForNotifications) {
        fprintf(stderr, "MediaRemote is missing a function\n");
        exit(2);
    }

    queue = dispatch_queue_create("local.dynamicnotch.nowplaying-helper", DISPATCH_QUEUE_SERIAL);
    registerForNotifications(queue);
    observe(mr, "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    observe(mr, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
    observe(mr, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
    dispatch_async(queue, ^{ refresh(); });

    [NSThread detachNewThreadWithBlock:^{ readCommands(); }];
    CFRunLoopRun();
}
