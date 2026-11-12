#import "MRGDJListen.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

@implementation MRGDJListener {
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    NSString *_best;
    void (^_partial)(NSString *);
    void (^_done)(NSString *);
    BOOL _tapped;
    BOOL _ducked;
    // The session as Spotify had it, put back after.
    AVAudioSessionCategory _oldCategory;
    AVAudioSessionMode _oldMode;
    AVAudioSessionCategoryOptions _oldOptions;
    BOOL _changedSession;
    NSUInteger _token;
}

+ (instancetype)shared {
    static MRGDJListener *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [MRGDJListener new]; });
    return l;
}

- (BOOL)isListening { return _engine.isRunning; }

static void onMain(void (^b)(void)) { if (NSThread.isMainThread) b(); else dispatch_async(dispatch_get_main_queue(), b); }

// Both permissions, asked once each. YES in `ready` only when both are granted now; a first grant still answers NO
// (the hold is over by the time the alerts are answered) with a note to hold again.
- (void)permissions:(void (^)(BOOL ready, NSString *why))done {
    SFSpeechRecognizerAuthorizationStatus speech = [SFSpeechRecognizer authorizationStatus];
    if (speech == SFSpeechRecognizerAuthorizationStatusDenied || speech == SFSpeechRecognizerAuthorizationStatusRestricted) {
        done(NO, @"Speech recognition is off for Spotify. Turn it on in Settings → Spotify, or type instead.");
        return;
    }
    if (speech == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s) {
            onMain(^{
                if (s != SFSpeechRecognizerAuthorizationStatusAuthorized) { done(NO, @"Speech recognition wasn't allowed, so the mic can't hear you. You can type instead."); return; }
                [self permissions:^(BOOL ready, NSString *why) { done(NO, why ?: @"All set. Hold the mic again and talk."); }];
            });
        }];
        return;
    }
    AVAudioSessionRecordPermission mic = AVAudioSession.sharedInstance.recordPermission;
    if (mic == AVAudioSessionRecordPermissionDenied) { done(NO, @"Microphone access is off for Spotify. Turn it on in Settings → Spotify, or type instead."); return; }
    if (mic == AVAudioSessionRecordPermissionUndetermined) {
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            onMain(^{ done(NO, granted ? @"All set. Hold the mic again and talk." : @"Microphone access wasn't allowed. You can type instead."); });
        }];
        return;
    }
    done(YES, nil);
}

- (void)startWithPartial:(void (^)(NSString *))partial failed:(void (^)(NSString *))failed {
    [self cancel];
    NSUInteger token = ++_token;
    [self permissions:^(BOOL ready, NSString *why) {
        if (token != self->_token) return;
        if (!ready) { failed(why ?: @"The mic isn't available right now."); return; }
        NSString *err = [self begin:partial];
        if (err) { [self teardown]; failed(err); }
    }];
}

- (NSString *)begin:(void (^)(NSString *))partial {
    @try {
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:NSLocale.currentLocale] ?: [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
        if (!_recognizer.isAvailable) return @"Speech recognition isn't available right now (it may need a connection on this phone).";
        AVAudioSession *session = AVAudioSession.sharedInstance;
        _oldCategory = session.category; _oldMode = session.mode; _oldOptions = session.categoryOptions;
        _changedSession = NO;
        if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
            NSError *e = nil;
            // Keeps Spotify's music going through the speaker or AirPods (A2DP); only the phone's mic records.
            [session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
                         options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionAllowAirPlay error:&e];
            if (e) return [@"The mic couldn't start: " stringByAppendingString:e.localizedDescription ?: @"audio session refused"];
            _changedSession = YES;
        }
        _engine = [AVAudioEngine new];
        AVAudioInputNode *input = _engine.inputNode;
        AVAudioFormat *format = [input outputFormatForBus:0];
        if (format.sampleRate <= 0 || format.channelCount == 0) return @"No microphone is available right now.";
        _request = [SFSpeechAudioBufferRecognitionRequest new];
        _request.shouldReportPartialResults = YES;
        _request.taskHint = SFSpeechRecognitionTaskHintSearch;
        if (_recognizer.supportsOnDeviceRecognition) _request.requiresOnDeviceRecognition = YES;   // stays on the phone
        if (@available(iOS 16.0, *)) _request.addsPunctuation = NO;
        _best = @"";
        _partial = [partial copy];
        SFSpeechAudioBufferRecognitionRequest *req = _request;
        [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) { [req appendAudioPCMBuffer:buffer]; }];
        _tapped = YES;
        NSUInteger token = _token;
        __weak MRGDJListener *weak = self;
        _task = [_recognizer recognitionTaskWithRequest:_request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            onMain(^{
                MRGDJListener *s = weak;
                if (!s || token != s->_token) return;
                if (result) {
                    s->_best = result.bestTranscription.formattedString ?: s->_best;
                    if (s->_partial) s->_partial(s->_best);
                }
                if (error || result.isFinal) [s deliver];
            });
        }];
        [_engine prepare];
        NSError *e = nil;
        if (![_engine startAndReturnError:&e]) return [@"The mic couldn't start: " stringByAppendingString:e.localizedDescription ?: @"?"];
        _ducked = MRGDuckMusic(YES);
        MRGDJLog(@"voice in: listening (%@)", _request.requiresOnDeviceRecognition ? @"on the phone" : @"Apple's speech service");
        return nil;
    } @catch (NSException *x) {
        return [@"The mic couldn't start: " stringByAppendingString:x.reason ?: @"?"];
    }
}

- (void)finish:(void (^)(NSString *))done {
    if (!_engine) { if (done) done(_best ?: @""); return; }
    _done = [done copy];
    @try {
        [_engine stop];
        if (_tapped) { [_engine.inputNode removeTapOnBus:0]; _tapped = NO; }
        [_request endAudio];
    } @catch (NSException *x) {}
    [self restoreAudio];
    // The final result usually follows within a moment; past 1.5 s the best partial is used.
    NSUInteger token = _token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (token == self->_token) [self deliver]; });
}

- (void)deliver {
    void (^done)(NSString *) = _done;
    if (!done && _engine.isRunning) return;   // still holding: an error mid-way is reported when they let go
    _done = nil;
    NSString *text = [_best stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    [self teardown];
    if (done) done(text);
}

- (void)restoreAudio {
    if (_ducked) { MRGDuckMusic(NO); _ducked = NO; }
    if (_changedSession) {
        _changedSession = NO;
        @try { [AVAudioSession.sharedInstance setCategory:_oldCategory mode:_oldMode options:_oldOptions error:nil]; } @catch (NSException *x) {}
    }
}

- (void)teardown {
    _token++;
    @try {
        if (_engine.isRunning) [_engine stop];
        if (_tapped) { [_engine.inputNode removeTapOnBus:0]; _tapped = NO; }
        [_task cancel];
    } @catch (NSException *x) {}
    _task = nil; _request = nil; _engine = nil; _partial = nil;
    [self restoreAudio];
}

- (void)cancel { _done = nil; [self teardown]; }
@end
