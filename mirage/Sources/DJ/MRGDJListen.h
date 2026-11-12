// Talking to the DJ (0.6.7): hold-to-talk speech recognition, on-device when the phone has it.
// Speech.framework's SFSpeechRecognizer on the microphone (AVAudioEngine). Spotify keeps playing (ducked) while you talk.
#import <Foundation/Foundation.h>

@interface MRGDJListener : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly, getter=isListening) BOOL listening;
// Starts listening. `partial` gets the transcript so far (main queue); `failed` one line when it can't
// (permissions off, no microphone, recognizer unavailable). A first use asks for permission and then says to hold again.
- (void)startWithPartial:(void (^)(NSString *text))partial failed:(void (^)(NSString *why))failed;
// Stops and hands over the best transcript (maybe empty), main queue.
- (void)finish:(void (^)(NSString *text))done;
- (void)cancel;
// 0.6.8: makes the recognizer ahead (off the main thread), so holding the mic starts without a hitch.
- (void)prewarm;
@end
