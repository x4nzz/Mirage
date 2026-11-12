#import "MRGDJListen.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>

// 0.6.8 root cause of the mic freezing for about a second: everything ran on the main thread when the mic was held:
// a new SFSpeechRecognizer, the audio session's switch to play-and-record (which waits on the audio server), a new
// AVAudioEngine, its input node and its start. Now that work runs on a queue of its own, the recognizer is made once
// and kept (prewarm makes it ahead, when the DJ sheet opens), and the main thread only gets the transcript.
@implementation MRGDJListener {
    dispatch_queue_t _q;                         // everything below is touched on _q only
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    NSString *_best;
    void (^_partial)(NSString *);
    void (^_done)(NSString *);
    BOOL _tapped;
    BOOL _ducked;
    AVAudioSessionCategory _oldCategory;
    AVAudioSessionMode _oldMode;
    AVAudioSessionCategoryOptions _oldOptions;
    BOOL _changedSession;
    NSUInteger _token;
    atomic_bool _listening;                      // read from any thread
}

+ (instancetype)shared {
    static MRGDJListener *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [MRGDJListener new]; });
    return l;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q = dispatch_queue_create("mirage.dj.listen", DISPATCH_QUEUE_SERIAL);
    atomic_store(&_listening, false);
    return self;
}

- (BOOL)isListening { return atomic_load(&_listening); }

static void onMain(void (^b)(void)) { if (NSThread.isMainThread) b(); else dispatch_async(dispatch_get_main_queue(), b); }

- (SFSpeechRecognizer *)recognizerOnQueue {
    if (_recognizer) return _recognizer;
    _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:NSLocale.currentLocale] ?: [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    return _recognizer;
}

- (void)prewarm {
    if ([SFSpeechRecognizer authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) return;
    dispatch_async(_q, ^{
        @try {
            SFSpeechRecognizer *r = [self recognizerOnQueue];
            (void)r.isAvailable;
            (void)r.supportsOnDeviceRecognition;
        } @catch (NSException *e) {}
    });
}

// Both permissions, asked once each. YES in `ready` only when both are granted now; a first grant still answers NO
// (the hold is over by the time the alerts are answered) with a note to hold again. Main queue.
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
                [self prewarm];
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
    void (^p)(NSString *) = [partial copy], (^f)(NSString *) = [failed copy];
    [self permissions:^(BOOL ready, NSString *why) {
        if (!ready) { if (f) f(why ?: @"The mic isn't available right now."); return; }
        dispatch_async(self->_q, ^{
            [self teardownOnQueue];
            NSString *err = [self beginOnQueue:p];
            if (err) { [self teardownOnQueue]; onMain(^{ if (f) f(err); }); }
        });
    }];
}

- (NSString *)beginOnQueue:(void (^)(NSString *))partial {
    @try {
        NSUInteger token = ++_token;
        SFSpeechRecognizer *recognizer = [self recognizerOnQueue];
        if (!recognizer.isAvailable) return @"Speech recognition isn't available right now (it may need a connection on this phone).";
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
        if (recognizer.supportsOnDeviceRecognition) _request.requiresOnDeviceRecognition = YES;   // stays on the phone
        if (@available(iOS 16.0, *)) _request.addsPunctuation = NO;
        _best = @"";
        _partial = [partial copy];
        SFSpeechAudioBufferRecognitionRequest *req = _request;
        [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) { [req appendAudioPCMBuffer:buffer]; }];
        _tapped = YES;
        __weak MRGDJListener *weak = self;
        _task = [recognizer recognitionTaskWithRequest:_request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            NSString *text = result.bestTranscription.formattedString;
            BOOL final = error != nil || result.isFinal;
            MRGDJListener *s = weak;
            if (!s) return;
            dispatch_async(s->_q, ^{
                if (token != s->_token) return;
                if (text) s->_best = text;
                void (^p)(NSString *) = s->_partial;
                NSString *best = s->_best;
                if (text && p) onMain(^{ p(best); });
                if (final) [s deliverOnQueue];
            });
        }];
        [_engine prepare];
        NSError *e = nil;
        if (![_engine startAndReturnError:&e]) return [@"The mic couldn't start: " stringByAppendingString:e.localizedDescription ?: @"?"];
        atomic_store(&_listening, true);
        _ducked = MRGDuckHold(@"mic", ^BOOL { return MRGDJListener.shared.isListening; });
        MRGDJLog(@"voice in: listening (%@)", _request.requiresOnDeviceRecognition ? @"on the phone" : @"Apple's speech service");
        return nil;
    } @catch (NSException *x) {
        return [@"The mic couldn't start: " stringByAppendingString:x.reason ?: @"?"];
    }
}

- (void)finish:(void (^)(NSString *))done {
    void (^d)(NSString *) = [done copy];
    dispatch_async(_q, ^{
        if (!self->_engine) { NSString *b = self->_best ?: @""; onMain(^{ if (d) d(b); }); return; }
        self->_done = d;
        @try {
            [self->_engine stop];
            if (self->_tapped) { [self->_engine.inputNode removeTapOnBus:0]; self->_tapped = NO; }
            [self->_request endAudio];
        } @catch (NSException *x) {}
        atomic_store(&self->_listening, false);
        [self restoreAudioOnQueue];
        // The final result usually follows within a moment; past 1.5 s the best partial is used.
        NSUInteger token = self->_token;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), self->_q, ^{ if (token == self->_token) [self deliverOnQueue]; });
    });
}

- (void)deliverOnQueue {
    void (^done)(NSString *) = _done;
    if (!done && _engine.isRunning) return;   // still holding: an error mid-way is reported when they let go
    _done = nil;
    NSString *text = [_best stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    [self teardownOnQueue];
    if (done) onMain(^{ done(text); });
}

- (void)restoreAudioOnQueue {
    if (_ducked) { MRGDuckRelease(@"mic"); _ducked = NO; }
    if (_changedSession) {
        _changedSession = NO;
        @try { [AVAudioSession.sharedInstance setCategory:_oldCategory mode:_oldMode options:_oldOptions error:nil]; } @catch (NSException *x) {}
    }
}

- (void)teardownOnQueue {
    _token++;
    @try {
        if (_engine.isRunning) [_engine stop];
        if (_tapped) { [_engine.inputNode removeTapOnBus:0]; _tapped = NO; }
        [_task cancel];
    } @catch (NSException *x) {}
    _task = nil; _request = nil; _engine = nil; _partial = nil;
    atomic_store(&_listening, false);
    [self restoreAudioOnQueue];
}

- (void)cancel { dispatch_async(_q, ^{ self->_done = nil; [self teardownOnQueue]; }); }
@end
