#import "MRGVoice.h"
#import "MRGAI.h"
#import "MRGKeychain.h"
#import "MRGDJLog.h"
#import "MRGDJ.h"
#import "MRGVoiceNet.h"

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *const kEleven = @"elevenlabs-key";
NSString *const MRGVoiceResultNotification = @"MirageVoiceResult";

MRGVoiceEngine MRGVoiceGetEngine(void) {
    id v = [D() objectForKey:@"mirage.dj.voiceEngine"];
    if (![v isKindOfClass:NSNumber.class]) v = nil;
    if (v) { NSInteger e = [v integerValue]; return (e >= 0 && e <= 5 && e != 4) ? e : MRGVoiceEngineFree; }   // 4 was Qwen (0.5.0), gone in 0.5.1
    // 0.2.x kept 0 phone, 1 provider, 2 off; nothing saved: the free voices.
    id old = [D() objectForKey:@"mirage.dj.voice"];
    if (![old isKindOfClass:NSNumber.class]) return MRGVoiceEngineFree;
    return [old integerValue] == 2 ? MRGVoiceEngineOff : [old integerValue] == 1 ? MRGVoiceEngineProvider : MRGVoiceEnginePhone;
}
void MRGVoiceSetEngine(MRGVoiceEngine e) { [D() setInteger:e forKey:@"mirage.dj.voiceEngine"]; }
void MRGVoiceChooseEngine(MRGVoiceEngine e) { MRGVoiceSetEngine(e); [D() setBool:YES forKey:@"mirage.dj.engineChosen"]; }
NSString *MRGVoiceEngineName(MRGVoiceEngine e) {
    switch (e) {
        case MRGVoiceEnginePhone: return @"iPhone";
        case MRGVoiceEngineProvider: return MRGProviderName(MRGAIProvider());
        case MRGVoiceEngineEleven: return @"ElevenLabs";
        case MRGVoiceEngineFree: return @"Free (Microsoft Edge voices, unofficial)";
        default: return @"Off";
    }
}

double MRGVoiceSpeed(void) { id v = [D() objectForKey:@"mirage.dj.speed"]; double s = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0; return MIN(1.5, MAX(0.6, s)); }
void MRGVoiceSetSpeed(double s) { [D() setDouble:s forKey:@"mirage.dj.speed"]; }
double MRGVoicePitch(void) { id v = [D() objectForKey:@"mirage.dj.pitch"]; double p = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0; return MIN(1.5, MAX(0.75, p)); }
void MRGVoiceSetPitch(double p) { [D() setDouble:p forKey:@"mirage.dj.pitch"]; }

static double num(NSString *k, double def, double lo, double hi) {
    id v = [D() objectForKey:k];
    double x = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : def;
    return MIN(hi, MAX(lo, x));
}
double MRGVoiceWarmth(void) { return num(@"mirage.dj.voiceWarmth", 0.5, 0, 1); }
void MRGVoiceSetWarmth(double v) { [D() setDouble:v forKey:@"mirage.dj.voiceWarmth"]; }
double MRGVoiceBreathiness(void) { return num(@"mirage.dj.voiceBreath", 0, 0, 1); }
void MRGVoiceSetBreathiness(double v) { [D() setDouble:v forKey:@"mirage.dj.voiceBreath"]; }
double MRGVoicePause(void) { return num(@"mirage.dj.voicePause", 0.2, 0, 1.5); }
void MRGVoiceSetPause(double v) { [D() setDouble:v forKey:@"mirage.dj.voicePause"]; }
NSString *MRGVoiceStyleText(void) { NSString *t = [D() stringForKey:@"mirage.dj.voiceStyle"]; return t.length ? t : nil; }
void MRGVoiceSetStyleText(NSString *t) {
    NSString *x = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (x.length) [D() setObject:[x substringToIndex:MIN(x.length, (NSUInteger)400)] forKey:@"mirage.dj.voiceStyle"];
    else [D() removeObjectForKey:@"mirage.dj.voiceStyle"];
}
double MRGElevenStability(void) { return num(@"mirage.dj.elevenStability", 0.5, 0, 1); }
void MRGElevenSetStability(double v) { [D() setDouble:v forKey:@"mirage.dj.elevenStability"]; }
double MRGElevenSimilarity(void) { return num(@"mirage.dj.elevenSimilarity", 0.75, 0, 1); }
void MRGElevenSetSimilarity(double v) { [D() setDouble:v forKey:@"mirage.dj.elevenSimilarity"]; }
static double elevenStyle(void) { return num(@"mirage.dj.elevenStyle", 0, 0, 1); }

NSString *MRGVoicePresetID(void) { return [D() stringForKey:@"mirage.dj.voicePreset"]; }
void MRGVoiceMarkCustom(void) { [D() removeObjectForKey:@"mirage.dj.voicePreset"]; }

// How to say the lines, for the engines that take a style (OpenAI's gpt-4o-mini-tts instructions, Gemini's prompt):
// the listener's own Voice style text, then words for the sliders. nil when everything is at its default.
NSString *MRGVoiceInstructions(void) {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *custom = MRGVoiceStyleText();
    if (custom) [parts addObject:custom];
    double speed = MRGVoiceSpeed(), pitch = MRGVoicePitch(), warm = MRGVoiceWarmth(), breath = MRGVoiceBreathiness(), pause = MRGVoicePause();
    if (speed <= 0.8) [parts addObject:@"Speak slowly and unhurried."];
    else if (speed < 0.95) [parts addObject:@"Speak a little slower than normal, relaxed."];
    else if (speed >= 1.2) [parts addObject:@"Speak at a fast, energetic pace."];
    else if (speed > 1.05) [parts addObject:@"Speak at a brisk pace."];
    if (pitch < 0.95) [parts addObject:@"Use a slightly lower, deeper register."];
    else if (pitch > 1.08) [parts addObject:@"Use a slightly higher, brighter register."];
    if (warm >= 0.75) [parts addObject:@"Very warm, gentle and intimate, like talking to one person you care about."];
    else if (warm >= 0.45 && warm != 0.5) [parts addObject:@"Warm and friendly."];
    else if (warm < 0.25) [parts addObject:@"Crisp and neutral."];
    if (breath >= 0.6) [parts addObject:@"Soft and breathy, close to the mic, trailing off gently at the ends of sentences."];
    else if (breath >= 0.3) [parts addObject:@"A little airy and soft."];
    if (pause >= 0.6) [parts addObject:@"Leave calm, noticeable pauses between sentences."];
    else if (pause >= 0.35) [parts addObject:@"Leave short, natural pauses between sentences."];
    if (!parts.count) return nil;
    NSString *joined = [parts componentsJoinedByString:@" "];
    return joined.length > 700 ? [joined substringToIndex:700] : joined;
}

#pragma mark - presets

// id, name, blurb, speed, pitch, warmth, breathiness, pause, style, persona, voices per engine (OpenAI, Gemini, Groq,
// xAI), ElevenLabs names to look for in the account, the iPhone voice's gender, ElevenLabs stability / similarity / style.
NSArray<NSDictionary *> *MRGVoicePresets(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @{@"edge": @"en-US-JennyNeural", @"edgeVol": @0.9, @"id": @"soothing", @"name": @"Soft & Soothing", @"blurb": @"Slow, warm, soothing female voice, close and calm.",
              @"speed": @0.85, @"pitch": @0.92, @"warmth": @0.95, @"breath": @0.55, @"pause": @0.6, @"persona": @6,
              @"style": @"A soft, soothing, warm female voice: slow, gentle and intimate, close to the mic, calm and reassuring, with a hint of a smile. Never loud, never rushed.",
              @"openai": @"shimmer", @"gemini": @"Achernar", @"groq": @"diana", @"xai": @"ara",
              @"eleven": @[@"Sarah", @"Lily", @"Matilda", @"Alice", @"Jessica", @"Laura", @"Charlotte", @"Rachel"], @"gender": @"female",
              @"stability": @0.6, @"similarity": @0.8, @"elStyle": @0.3, @"elModel": @"v3", @"elTag": @"[softly]", @"v3Stab": @0.5, @"phoneVol": @0.85},
            // Alex's pick for his first sample: ElevenLabs "Ivy" (low, soft, slow, close-mic, calm, a bit caring and bossy).
            @{@"edge": @"en-US-AvaNeural", @"edgeVol": @0.85, @"id": @"velvet", @"name": @"Soft & Close", @"blurb": @"Low, soft and slow, right at the mic; calm, caring, a little bossy (ElevenLabs Ivy).",
              @"speed": @0.84, @"pitch": @0.95, @"warmth": @1.0, @"breath": @0.6, @"pause": @0.8,
              @"style": @"A low, soft, slow female voice right at the mic: calm and caring with a gentle, slightly bossy confidence, short phrases with unhurried pauses, a narrow calm melody and a soft smile. Never loud, never bright, never rushed.",
              @"openai": @"shimmer", @"gemini": @"Sulafat", @"groq": @"autumn", @"xai": @"ara",
              @"elevenID": @"KhpuFRhu6kfNvpalcYtz", @"elevenIDName": @"Ivy",
              @"phone": @[@"Ava", @"Zoe", @"Samantha"], @"gender": @"female",
              @"stability": @0.75, @"similarity": @0.8, @"elStyle": @0.1, @"elModel": @"flash", @"phoneVol": @0.85},
            // ElevenLabs' classic "Nicole": a soft, breathy, intimate whisper.
            @{@"edge": @"en-US-AvaMultilingualNeural", @"edgeVol": @0.7, @"edgeSpeed": @0.8, @"edgePitch": @0.94, @"id": @"whisper", @"name": @"Classic Whisper", @"blurb": @"Soft, breathy, intimate whisper; whispers for real on ElevenLabs v3.",
              @"speed": @0.88, @"pitch": @1.05, @"warmth": @0.8, @"breath": @0.95, @"pause": @0.6,
              @"style": @"Whisper the whole time: a soft, breathy, intimate ASMR whisper, light and high, very close to the mic, calm, gentle and hushed, every word unhurried. Never use a normal speaking voice.",
              @"openai": @"shimmer", @"gemini": @"Achernar", @"groq": @"diana", @"xai": @"ara",
              @"elevenID": @"piTKgcLEGmPE4e6mEKli", @"elevenIDName": @"Nicole",
              @"phone": @[@"Zoe", @"Ava", @"Samantha"], @"gender": @"female",
              @"stability": @0.25, @"similarity": @0.7, @"elStyle": @0.8, @"elModel": @"v3", @"elTag": @"[whispers]", @"elEvery": @YES, @"v3Stab": @0.0,
              @"elSpeed": @0.85, @"phoneVol": @0.5},
            // Modeled on Alex's second sample (ElevenLabs "Arabella" v3 demo: young bright American female, very expressive).
            @{@"edge": @"en-US-EmmaMultilingualNeural", @"edgeVol": @1.0, @"id": @"spark", @"name": @"Playful Spark", @"blurb": @"Young, bright and super expressive; laughs, whispers, big swings.",
              @"speed": @1.06, @"pitch": @1.05, @"warmth": @0.6, @"breath": @0.25, @"pause": @0.35, @"persona": @0,
              @"style": @"A young, bright American female voice, playful and very expressive: big pitch swings, quick excited delivery that drops to a conspiratorial whisper, little laughs and giggles, dramatic pauses before the reveal, sounds amazed by everything, like a friend gushing about a song.",
              @"openai": @"coral", @"gemini": @"Zephyr", @"groq": @"hannah", @"xai": @"eve",
              @"elevenID": @"Z3R5wn05IrDiVCyEkUrK", @"elevenIDName": @"Arabella",
              @"phone": @[@"Zoe", @"Ava", @"Nicky"], @"gender": @"female",
              @"stability": @0.3, @"similarity": @0.75, @"elStyle": @0.65, @"elModel": @"v3", @"elTag": @"[excited]", @"v3Stab": @0.0, @"phoneVol": @1.0},
            @{@"edge": @"en-US-GuyNeural", @"id": @"hype", @"name": @"Hype Radio DJ", @"blurb": @"Loud, fast, big energy.",
              @"speed": @1.15, @"pitch": @1.05, @"warmth": @0.4, @"breath": @0.0, @"pause": @0.15, @"persona": @2,
              @"style": @"A high-energy radio DJ: punchy, excited and confident, big smile, hits the artist names hard, fast pace.",
              @"openai": @"ash", @"gemini": @"Fenrir", @"groq": @"troy", @"xai": @"rex",
              @"eleven": @[@"Liam", @"Charlie", @"Will", @"Chris", @"Josh", @"Adam"], @"gender": @"male",
              @"stability": @0.3, @"similarity": @0.75, @"elStyle": @0.6, @"elModel": @"v3", @"elTag": @"[energetic, loud radio voice]", @"v3Stab": @0.0, @"phoneVol": @1.0},
            @{@"edge": @"en-US-ChristopherNeural", @"id": @"latenight", @"name": @"Late Night", @"blurb": @"Low, smooth and slow, like 2 a.m. radio.",
              @"speed": @0.9, @"pitch": @0.93, @"warmth": @0.85, @"breath": @0.35, @"pause": @0.5, @"persona": @1,
              @"style": @"A late-night radio host: low, smooth, velvety and relaxed, like it's 2 a.m.; slow, intimate, quiet confidence.",
              @"openai": @"onyx", @"gemini": @"Algieba", @"groq": @"daniel", @"xai": @"leo",
              @"eleven": @[@"Brian", @"Daniel", @"George", @"Bill", @"Eric"], @"gender": @"male",
              @"stability": @0.55, @"similarity": @0.8, @"elStyle": @0.35, @"elModel": @"v3", @"elTag": @"[low, smooth late-night voice]", @"v3Stab": @0.5, @"phoneVol": @0.8},
            @{@"edge": @"en-US-BrianMultilingualNeural", @"id": @"narrator", @"name": @"Chill Narrator", @"blurb": @"Calm, clear and easygoing.",
              @"speed": @0.95, @"pitch": @1.0, @"warmth": @0.6, @"breath": @0.1, @"pause": @0.4, @"persona": @4,
              @"style": @"A calm, clear, friendly narrator: easygoing and even, like a documentary voice-over by someone who loves music.",
              @"openai": @"sage", @"gemini": @"Callirrhoe", @"groq": @"austin", @"xai": @"sal",
              @"eleven": @[@"George", @"Alice", @"Matilda", @"Brian"], @"gender": @"",
              @"stability": @0.65, @"similarity": @0.75, @"elStyle": @0.1, @"elModel": @"v2", @"phoneVol": @0.9},
            @{@"edge": @"en-US-AndrewNeural", @"id": @"classic", @"name": @"Classic Spotify DJ", @"blurb": @"Friendly, casual, like Spotify's own DJ.",
              @"speed": @1.0, @"pitch": @1.0, @"warmth": @0.6, @"breath": @0.0, @"pause": @0.3, @"persona": @0,
              @"style": @"A friendly, casual music host like Spotify's DJ: upbeat but relaxed, warm and genuine, conversational, like a friend who knows your taste.",
              @"openai": @"ash", @"gemini": @"Puck", @"groq": @"troy", @"xai": @"eve",
              @"eleven": @[@"Chris", @"Liam", @"Brian", @"Eric"], @"gender": @"male",
              @"stability": @0.45, @"similarity": @0.75, @"elStyle": @0.3, @"elModel": @"v2", @"phoneVol": @0.95},
        ];
    });
    return list;
}

// The best installed iPhone voice of a gender (personal, Premium, Enhanced first), or nil.
static AVSpeechSynthesisVoice *bestPhoneVoice(NSString *gender) {
    if (!gender.length) return nil;
    AVSpeechSynthesisVoiceGender want = [gender isEqualToString:@"female"] ? AVSpeechSynthesisVoiceGenderFemale : AVSpeechSynthesisVoiceGenderMale;
    for (AVSpeechSynthesisVoice *v in MRGVoicePhoneVoices()) {
        if (![v.language hasPrefix:@"en"]) continue;
        if ([v respondsToSelector:@selector(gender)] && v.gender == want) return v;
    }
    return nil;
}

NSString *MRGVoiceApplyPreset(NSString *pid) {
    NSDictionary *p = nil;
    for (NSDictionary *x in MRGVoicePresets()) if ([x[@"id"] isEqualToString:pid]) p = x;
    if (!p) return nil;
    MRGVoiceSetSpeed([p[@"speed"] doubleValue]);
    MRGVoiceSetPitch([p[@"pitch"] doubleValue]);
    MRGVoiceSetWarmth([p[@"warmth"] doubleValue]);
    MRGVoiceSetBreathiness([p[@"breath"] doubleValue]);
    MRGVoiceSetPause([p[@"pause"] doubleValue]);
    MRGVoiceSetStyleText(p[@"style"]);
    MRGElevenSetStability([p[@"stability"] doubleValue]);
    MRGElevenSetSimilarity([p[@"similarity"] doubleValue]);
    [D() setDouble:[p[@"elStyle"] doubleValue] forKey:@"mirage.dj.elevenStyle"];
    [D() setDouble:p[@"phoneVol"] ? [p[@"phoneVol"] doubleValue] : 1.0 forKey:@"mirage.dj.phoneVolume"];
    // Voice only: a preset never changes the DJ's persona or the music (0.4.2's "Soft & soothing" persona leaked into
    // the sets: "a quiet flow", "a soft pulse").
    NSMutableArray *what = [NSMutableArray array];
    MRGProvider prov = MRGAIProvider();
    NSString *key = prov == MRGProviderOpenAI ? @"openai" : prov == MRGProviderGemini ? @"gemini" : prov == MRGProviderGroq ? @"groq" : prov == MRGProviderXAI ? @"xai" : nil;
    // Groq's voices (Orpheus) need their terms accepted in the Groq console first (HTTP 400 otherwise), so a preset
    // never sets one up; the provider voice stays what the listener picked.
    if (key && prov != MRGProviderGroq && MRGProviderHasTTS(prov)) { MRGVoiceSetProviderVoice(p[key]); [what addObject:[NSString stringWithFormat:@"%@ voice %@", MRGProviderName(prov), p[key]]]; }
    BOOL elevenSet = NO;
    [D() removeObjectForKey:@"mirage.dj.elevenNeedsAdd"];
    NSDictionary *override = [D() dictionaryForKey:[@"mirage.dj.presetVoice." stringByAppendingString:pid]];
    if ([override[@"id"] isKindOfClass:NSString.class]) {
        NSMutableDictionary *m = [p mutableCopy];
        m[@"elevenID"] = override[@"id"];
        if ([override[@"name"] isKindOfClass:NSString.class]) m[@"elevenIDName"] = override[@"name"];
        p = m;
    }
    // The free voice of the preset, with its own loudness (and for the whisper a slower, lower read: Microsoft's free
    // voices have no whisper style, so it is quiet, slow and a touch lower instead).
    if ([p[@"edge"] length]) { MRGEdgeSetVoice(p[@"edge"]); [what addObject:[@"Free voice " stringByAppendingString:[[p[@"edge"] componentsSeparatedByString:@"-"].lastObject stringByReplacingOccurrencesOfString:@"Neural" withString:@""]]]; }
    [D() setDouble:p[@"edgeVol"] ? [p[@"edgeVol"] doubleValue] : 1.0 forKey:@"mirage.dj.edgeVolume"];
    if (p[@"edgeSpeed"]) MRGVoiceSetSpeed([p[@"edgeSpeed"] doubleValue]);
    if (p[@"edgePitch"]) MRGVoiceSetPitch([p[@"edgePitch"] doubleValue]);
    // 0.5.1: every preset speaks with the free voices; only the iPhone voice, if the listener picked it, stays (paid
    // engines failed for Alex: ElevenLabs' free plan refuses library voices, Qwen wants a $1 card check).
    MRGVoiceEngine current = MRGVoiceGetEngine();
    // A preset changes how the voice sounds, not which engine speaks: ElevenLabs (with its key), the provider's voice
    // and the iPhone voice stay when the listener picked them. Before 0.6.5 a preset switched ElevenLabs back to
    // the free voice, so the presets seemed to do nothing with ElevenLabs.
    BOOL keep = [D() boolForKey:@"mirage.dj.engineChosen"] &&
                (current == MRGVoiceEnginePhone || (current == MRGVoiceEngineEleven && MRGKeychainGet(kEleven).length) ||
                 (current == MRGVoiceEngineProvider && MRGProviderHasTTS(MRGAIProvider())));
    if (!keep) MRGVoiceSetEngine(MRGVoiceEngineFree);
    if ([p[@"elevenID"] length] && MRGKeychainGet(kEleven).length) {
        // The voice Alex picked, by its ID: never silently swapped for another. Shared-library voices that aren't in his
        // ElevenLabs voices yet work by ID on paid plans; otherwise the voice page offers "Add to my ElevenLabs".
        NSString *vid = p[@"elevenID"], *vname = p[@"elevenIDName"] ?: vid;
        BOOL mine = NO;
        for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:vid]) mine = YES;
        MRGElevenSetVoice(vid);
        elevenSet = YES;
        [what addObject:[NSString stringWithFormat:@"ElevenLabs %@%@", vname, mine ? @"" : @" (by ID, not in your voices)"]];
        if (!mine && MRGVoiceGetEngine() == MRGVoiceEngineEleven) {
            [D() setObject:@{@"id": vid, @"name": vname} forKey:@"mirage.dj.elevenNeedsAdd"];
            MRGDJLog(@"voice: ElevenLabs %@ (%@) isn't in your ElevenLabs voices; using it by ID. If it fails, add it in ElevenLabs → Voice Library (or Add to my ElevenLabs on the voice page).", vname, vid);
        }
    }
    for (NSString *want in elevenSet ? @[] : p[@"eleven"]) {
        NSDictionary *hit = nil;
        for (NSDictionary *v in MRGElevenVoices()) if ([[v[@"name"] lowercaseString] hasPrefix:want.lowercaseString]) { hit = v; break; }
        if (hit) { MRGElevenSetVoice(hit[@"id"]); [what addObject:[@"ElevenLabs " stringByAppendingString:hit[@"name"]]]; elevenSet = YES; break; }
    }
    AVSpeechSynthesisVoice *phone = nil;
    for (NSString *want in p[@"phone"]) {
        for (AVSpeechSynthesisVoice *v in MRGVoicePhoneVoices())
            if ([v.language hasPrefix:@"en"] && [v.name.lowercaseString hasPrefix:want.lowercaseString]) { phone = v; break; }
        if (phone) break;
    }
    if (!phone) phone = bestPhoneVoice(p[@"gender"]);
    if (phone) { MRGVoiceSetPhoneVoice(phone.identifier); [what addObject:[@"iPhone " stringByAppendingString:phone.name]]; }
    [D() setObject:pid forKey:@"mirage.dj.voicePreset"];
    MRGDJLog(@"voice: preset %@ (%@)", p[@"name"], what.count ? [what componentsJoinedByString:@", "] : @"settings only");
    return what.count ? [what componentsJoinedByString:@" · "] : nil;
}

#pragma mark - phone voices

static BOOL isPersonal(AVSpeechSynthesisVoice *v) {
    if (@available(iOS 17.0, *)) return (v.voiceTraits & AVSpeechSynthesisVoiceTraitIsPersonalVoice) != 0;
    return NO;
}

static NSInteger voiceScore(AVSpeechSynthesisVoice *v) {
    return (isPersonal(v) ? 100 : 0) + (NSInteger)v.quality * 10;
}

NSString *MRGVoiceQualityName(AVSpeechSynthesisVoice *v) {
    if (isPersonal(v)) return @"Personal";
    if (v.quality == AVSpeechSynthesisVoiceQualityPremium) return @"Premium";
    if (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) return @"Enhanced";
    return @"Default";
}

NSArray<AVSpeechSynthesisVoice *> *MRGVoicePhoneVoices(void) {
    NSString *lang = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject ?: @"en";
    NSMutableArray *out = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *v in AVSpeechSynthesisVoice.speechVoices) {
        if (![v.language hasPrefix:@"en"] && ![v.language hasPrefix:lang]) continue;
        if (@available(iOS 17.0, *)) { if (v.voiceTraits & AVSpeechSynthesisVoiceTraitIsNoveltyVoice) continue; }
        [out addObject:v];
    }
    [out sortUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a, AVSpeechSynthesisVoice *b) {
        NSInteger sa = voiceScore(a), sb = voiceScore(b);
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        BOOL la = [a.language isEqualToString:AVSpeechSynthesisVoice.currentLanguageCode], lb = [b.language isEqualToString:AVSpeechSynthesisVoice.currentLanguageCode];
        if (la != lb) return la ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

AVSpeechSynthesisVoice *MRGVoicePhoneVoice(void) {
    NSString *wanted = [D() stringForKey:@"mirage.dj.systemVoice"];
    AVSpeechSynthesisVoice *v = wanted ? [AVSpeechSynthesisVoice voiceWithIdentifier:wanted] : nil;
    return v ?: MRGVoicePhoneVoices().firstObject ?: [AVSpeechSynthesisVoice voiceWithLanguage:AVSpeechSynthesisVoice.currentLanguageCode];
}

void MRGVoiceSetPhoneVoice(NSString *identifier) {
    if (identifier.length) [D() setObject:identifier forKey:@"mirage.dj.systemVoice"];
    else [D() removeObjectForKey:@"mirage.dj.systemVoice"];
}

NSString *MRGVoiceProviderVoice(void) { return [D() stringForKey:@"mirage.dj.providerVoice"]; }
void MRGVoiceSetProviderVoice(NSString *voiceID) {
    if (voiceID.length) [D() setObject:voiceID forKey:@"mirage.dj.providerVoice"]; else [D() removeObjectForKey:@"mirage.dj.providerVoice"];
}

#pragma mark - ElevenLabs

// api.elevenlabs.io: GET /v1/voices lists the account's voices (and checks the key), POST /v1/text-to-speech/{id}
// returns MP3. Header xi-api-key.
static NSMutableURLRequest *elevenRequest(NSString *path, NSString *key, NSDictionary *body) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.elevenlabs.io" stringByAppendingString:path]]];
    r.timeoutInterval = 30;
    [r setValue:key forHTTPHeaderField:@"xi-api-key"];
    if (body) {
        r.HTTPMethod = @"POST";
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [r setValue:@"audio/mpeg" forHTTPHeaderField:@"Accept"];
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    return r;
}

// ElevenLabs' errors are {"detail": {"type", "code", "status", "message"}} (or a string / validation list). The text
// says what it means in plain words, then ElevenLabs' own message, status code and code; the full body is logged.
static NSString *elevenError(NSInteger status, NSData *data, NSError *error) {
    if (error) return [@"ElevenLabs: " stringByAppendingString:error.localizedDescription ?: @"network error"];
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *detail = nil, *code = nil;
    id d = [j isKindOfClass:NSDictionary.class] ? j[@"detail"] : nil;
    if ([d isKindOfClass:NSDictionary.class]) {
        if ([d[@"message"] isKindOfClass:NSString.class]) detail = d[@"message"];
        if ([d[@"status"] isKindOfClass:NSString.class]) code = d[@"status"];
        else if ([d[@"code"] isKindOfClass:NSString.class]) code = d[@"code"];
    } else if ([d isKindOfClass:NSString.class]) detail = d;
    else if ([d isKindOfClass:NSArray.class] && [[d firstObject] isKindOfClass:NSDictionary.class] && [[d firstObject][@"msg"] isKindOfClass:NSString.class]) detail = [d firstObject][@"msg"];
    NSString *body = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    MRGDJLog(@"voice: ElevenLabs HTTP %ld body: %@", (long)status, body.length > 600 ? [body substringToIndex:600] : body);
    NSString *lower = [[NSString stringWithFormat:@"%@ %@", code ?: @"", detail ?: @""] lowercaseString];
    NSString *meaning = nil;
    if (status == 402 || [lower containsString:@"paid_plan"] || [lower containsString:@"free_users"] || [lower containsString:@"payment"])
        meaning = @"library voices need a paid ElevenLabs plan through the API";
    else if (status == 404 || [lower containsString:@"voice_not_found"] || [lower containsString:@"not found"])
        meaning = @"this voice isn't available to your account (add it in ElevenLabs → Voice Library, or it was retired)";
    else if (status == 401) meaning = @"the key was refused (check it, and its Text to Speech permission)";
    else if (status == 429) meaning = @"too many requests or out of credits for now";
    else if ([lower containsString:@"quota"] || [lower containsString:@"credits"]) meaning = @"out of credits";
    return [NSString stringWithFormat:@"ElevenLabs: %@%@ (HTTP %ld%@)", meaning ?: @"request refused", detail ? [@". " stringByAppendingString:detail] : @"",
            (long)status, code ? [@", " stringByAppendingString:code] : @""];
}

BOOL MRGElevenHasKey(void) { return MRGKeychainGet(kEleven).length > 0; }
NSArray<NSDictionary *> *MRGElevenVoices(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *v in [D() arrayForKey:@"mirage.dj.elevenVoices"])
        if ([v isKindOfClass:NSDictionary.class] && [v[@"id"] isKindOfClass:NSString.class] && [v[@"name"] isKindOfClass:NSString.class]) [a addObject:v];
    return a;
}
NSString *MRGElevenVoice(void) { return [D() stringForKey:@"mirage.dj.elevenVoice"] ?: [MRGElevenVoices().firstObject objectForKey:@"id"]; }
void MRGElevenSetVoice(NSString *voiceID) { if (voiceID) [D() setObject:voiceID forKey:@"mirage.dj.elevenVoice"]; }

static void fetchElevenVoices(NSString *key, void (^done)(NSArray *, NSString *)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(@"/v1/voices", key, nil) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSMutableArray *voices = [NSMutableArray array];
        NSString *err = nil;
        if (error || status < 200 || status >= 300) err = elevenError(status, data, error);
        else {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            for (NSDictionary *v in [j isKindOfClass:NSDictionary.class] && [j[@"voices"] isKindOfClass:NSArray.class] ? j[@"voices"] : @[]) {
                if (![v isKindOfClass:NSDictionary.class] || ![v[@"voice_id"] isKindOfClass:NSString.class]) continue;
                [voices addObject:@{@"id": v[@"voice_id"], @"name": [v[@"name"] isKindOfClass:NSString.class] ? v[@"name"] : v[@"voice_id"],
                                    @"category": [v[@"category"] isKindOfClass:NSString.class] ? v[@"category"] : @""}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(err ? nil : voices, err); });
    }] resume];
}

void MRGElevenSetKey(NSString *raw, void (^done)(BOOL, NSString *)) {
    NSString *key = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!key.length) {
        MRGKeychainSet(kEleven, nil);
        [D() removeObjectForKey:@"mirage.dj.elevenVoices"];
        if (MRGVoiceGetEngine() == MRGVoiceEngineEleven) MRGVoiceSetEngine(MRGVoiceEngineFree);
        done(YES, @"ElevenLabs key removed.");
        return;
    }
    fetchElevenVoices(key, ^(NSArray *voices, NSString *error) {
        if (error) { done(NO, error); return; }
        if (!MRGKeychainSet(kEleven, key)) { done(NO, @"Couldn't save the key on this phone."); return; }
        [D() setObject:voices forKey:@"mirage.dj.elevenVoices"];
        done(YES, [NSString stringWithFormat:@"ElevenLabs key saved: %lu voices.", (unsigned long)voices.count]);
    });
}

void MRGElevenRefreshVoices(void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    NSString *key = MRGKeychainGet(kEleven);
    if (!key.length) { done(@[], @"No ElevenLabs key."); return; }
    fetchElevenVoices(key, ^(NSArray *voices, NSString *error) {
        if (voices) [D() setObject:voices forKey:@"mirage.dj.elevenVoices"];
        done(voices ?: MRGElevenVoices(), error);
    });
}

// The preset voice the account doesn't have yet ({id, name, error?}), or nil.
NSDictionary *MRGElevenNeedsAdd(void) {
    NSDictionary *n = [D() dictionaryForKey:@"mirage.dj.elevenNeedsAdd"];
    if (![n[@"id"] isKindOfClass:NSString.class]) return nil;
    for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:n[@"id"]]) return nil;
    return n;
}

// GET /v1/shared-voices (needs a key; filters are refused when logged out): the library's voices for a search.
static void sharedSearch(NSString *query, NSString *extra, void (^done)(NSArray<NSDictionary *> *voices, NSString *error)) {
    NSString *key = MRGKeychainGet(kEleven);
    if (!key.length) { done(nil, @"Add your ElevenLabs key first."); return; }
    NSString *q = [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
    NSString *path = [NSString stringWithFormat:@"/v1/shared-voices?page_size=100&search=%@%@", q, extra ?: @""];
    [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(path, key, nil) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSMutableArray *out = [NSMutableArray array];
        id list = [j isKindOfClass:NSDictionary.class] ? j[@"voices"] : nil;
        for (id v in [list isKindOfClass:NSArray.class] ? list : @[]) if ([v isKindOfClass:NSDictionary.class] && [v[@"voice_id"] isKindOfClass:NSString.class]) [out addObject:v];
        NSString *err = (error || status < 200 || status >= 300) ? elevenError(status, data, error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(err ? nil : out, err); });
    }] resume];
}

// POST /v1/voices/add/{public_user_id}/{voice_id} with {"new_name"}: the voice goes into the account's voices.
static void addShared(NSString *owner, NSString *voiceID, NSString *name, void (^done)(BOOL ok, NSString *message)) {
    NSString *key = MRGKeychainGet(kEleven);
    NSString *addPath = [NSString stringWithFormat:@"/v1/voices/add/%@/%@", owner, voiceID];
    [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(addPath, key, @{@"new_name": name ?: voiceID}) completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
        NSInteger s2 = [r2 isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r2).statusCode : 0;
        BOOL ok = !e2 && s2 >= 200 && s2 < 300;
        NSString *msg = ok ? [NSString stringWithFormat:@"%@ was added to your ElevenLabs voices.", name ?: voiceID] : elevenError(s2, d2, e2);
        MRGDJLog(@"voice: add %@ (%@) → HTTP %ld %@", name, voiceID, (long)s2, ok ? @"added" : msg);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { done(NO, msg); return; }
            [D() removeObjectForKey:@"mirage.dj.elevenNeedsAdd"];
            MRGElevenRefreshVoices(^(NSArray<NSDictionary *> *voices, NSString *err) { done(YES, msg); });
        });
    }] resume];
}

// Adds a shared Voice Library voice to the user's ElevenLabs voices with their own key: finds its public_owner_id with
// a shared-voices search for its name, then adds it. Only on the user's own choice (a preset tap or the Add button).
void MRGElevenAddShared(NSString *voiceID, NSString *name, void (^done)(BOOL ok, NSString *message)) {
    if (!MRGElevenHasKey() || !voiceID.length) { done(NO, @"Add your ElevenLabs key first."); return; }
    sharedSearch(name ?: voiceID, nil, ^(NSArray<NSDictionary *> *voices, NSString *error) {
        if (error) { done(NO, error); return; }
        NSString *owner = nil;
        for (NSDictionary *v in voices) if ([v[@"voice_id"] isEqualToString:voiceID] && [v[@"public_owner_id"] isKindOfClass:NSString.class]) owner = v[@"public_owner_id"];
        if (!owner) {
            NSString *msg = [NSString stringWithFormat:@"%@ (%@) isn't in ElevenLabs' Voice Library (retired or private).", name ?: voiceID, voiceID];
            MRGDJLog(@"voice: add: %@", msg);
            done(NO, msg);
            return;
        }
        addShared(owner, voiceID, name, done);
    });
}

// Before a preset's first line: if its ElevenLabs voice isn't in the account, add it (the tap is the user's choice).
// Nicole (piTKgcLEGmPE4e6mEKli) is one of ElevenLabs' old default voices, which are being retired: when the library
// doesn't have her, the closest current whisper voice from a shared-voices search takes her place for that preset.
void MRGVoicePreparePreset(NSString *pid, void (^done)(NSString *message)) {
    NSDictionary *p = nil;
    for (NSDictionary *x in MRGVoicePresets()) if ([x[@"id"] isEqualToString:pid]) p = x;
    NSDictionary *need = MRGElevenNeedsAdd();
    if (!p || !need || !MRGElevenHasKey() || MRGVoiceGetEngine() != MRGVoiceEngineEleven) { done(nil); return; }
    MRGElevenAddShared(need[@"id"], need[@"name"], ^(BOOL ok, NSString *message) {
        if (ok || ![pid isEqualToString:@"whisper"] || ![message containsString:@"isn't in ElevenLabs' Voice Library"]) { done(message); return; }
        sharedSearch(@"whisper", @"&gender=female&language=en", ^(NSArray<NSDictionary *> *voices, NSString *error) {
            NSDictionary *pick = nil;
            for (NSDictionary *v in voices) {
                NSString *text = [[NSString stringWithFormat:@"%@ %@ %@", v[@"name"] ?: @"", v[@"description"] ?: @"", v[@"descriptive"] ?: @""] lowercaseString];
                if ([v[@"public_owner_id"] isKindOfClass:NSString.class] && ([text containsString:@"whisper"] || [text containsString:@"asmr"])) { pick = v; break; }
            }
            if (!pick) { done([message stringByAppendingFormat:@" No current whisper voice found to replace her%@.", error ? [@" (" stringByAppendingFormat:@"%@)", error] : @""]); return; }
            NSString *name = [pick[@"name"] isKindOfClass:NSString.class] ? pick[@"name"] : @"Whisper";
            MRGDJLog(@"voice: Nicole is retired; Classic Whisper uses %@ (%@) from the Voice Library instead", name, pick[@"voice_id"]);
            [D() setObject:@{@"id": pick[@"voice_id"], @"name": name} forKey:@"mirage.dj.presetVoice.whisper"];
            MRGVoiceApplyPreset(pid);
            addShared(pick[@"public_owner_id"], pick[@"voice_id"], name, ^(BOOL ok2, NSString *m2) {
                done([NSString stringWithFormat:@"Nicole is retired; using %@ instead. %@", name, m2 ?: @""]);
            });
        });
    });
}

// How the active preset is spoken by ElevenLabs. Each preset names a model and, for Eleven v3, an audio tag:
//   v3    eleven_v3 with the preset's tag ([whispers] before every sentence for the whisper, once at the start for the
//         others), v3's own stability steps (0 creative, 0.5 natural, 1 robust) and no <break/> tags (v3 doesn't
//         take them; ellipses instead). Falls back to v2 if the plan or voice refuses v3.
//   v2    eleven_multilingual_v2 with the preset's stability / similarity / style exaggeration / speed.
//   flash eleven_flash_v2_5 first (the fast model the Soft & Close preset was tuned on), then v2.
// Hand-tuned settings (no preset) speak with v2, which follows the style slider. Before 0.6.5 everything went to
// eleven_flash_v2_5 first with style 0 on the whisper, and the preset's style text never reached ElevenLabs.
static NSArray<NSString *> *sentences(NSString *text);
static NSDictionary *activePreset(void) {
    NSString *pid = MRGVoicePresetID();
    for (NSDictionary *x in MRGVoicePresets()) if ([x[@"id"] isEqualToString:pid]) return x;
    return nil;
}

static BOOL sNoV3;   // this key's plan or voice refused eleven_v3 once: skip it for the rest of the session

static NSString *v3Text(NSString *text, NSDictionary *p) {
    NSString *plain = [text stringByReplacingOccurrencesOfString:@"<break[^>]*/>" withString:@"..." options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    NSString *tag = [p[@"elTag"] isKindOfClass:NSString.class] ? p[@"elTag"] : nil;
    if (!tag.length) return plain;
    if (![p[@"elEvery"] boolValue]) return [NSString stringWithFormat:@"%@ %@", tag, plain];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *one in sentences(plain)) [out addObject:[NSString stringWithFormat:@"%@ %@", tag, one]];
    return [out componentsJoinedByString:@" "];
}

static void elevenSpeech(NSString *text, NSString *voice, double speed, void (^done)(NSData *, NSString *)) {
    NSString *key = MRGKeychainGet(kEleven);
    if (!key.length || !voice.length) { done(nil, @"No ElevenLabs key or voice."); return; }
    NSString *path = [NSString stringWithFormat:@"/v1/text-to-speech/%@?output_format=mp3_44100_128", voice];
    NSDictionary *preset = activePreset();
    NSString *kind = [preset[@"elModel"] isKindOfClass:NSString.class] ? preset[@"elModel"] : @"v2";
    double talk = preset[@"elSpeed"] ? MIN(speed, [preset[@"elSpeed"] doubleValue]) : speed;
    NSDictionary *v2Settings = @{@"speed": @(MIN(1.2, MAX(0.7, talk))), @"stability": @(MRGElevenStability()),
                                 @"similarity_boost": @(MRGElevenSimilarity()), @"style": @(elevenStyle()), @"use_speaker_boost": @YES};
    // One attempt: model, text and settings.
    void (^run)(NSString *, NSString *, NSDictionary *, void (^)(NSData *, NSInteger, NSString *)) = ^(NSString *model, NSString *said, NSDictionary *settings, void (^cb)(NSData *, NSInteger, NSString *)) {
        NSDictionary *body = @{@"text": said, @"model_id": model, @"voice_settings": settings};
        MRGDJLog(@"voice: ElevenLabs %@ · stability %.2f · style %.2f · speed %.2f%@", model, [settings[@"stability"] doubleValue], [settings[@"style"] doubleValue],
                 [settings[@"speed"] doubleValue], [model isEqualToString:@"eleven_v3"] && preset[@"elTag"] ? [@" · " stringByAppendingString:preset[@"elTag"]] : @"");
        [[NSURLSession.sharedSession dataTaskWithRequest:elevenRequest(path, key, body) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            NSString *err = (error || status < 200 || status >= 300) ? elevenError(status, data, error) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(err ? nil : data, status, err); });
        }] resume];
    };
    void (^finish)(NSData *, NSInteger, NSString *) = ^(NSData *d, NSInteger st, NSString *e) {
        if (!d && st >= 400 && st < 500) {
            BOOL mine = NO;
            for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:voice]) mine = YES;
            if (!mine) {
                NSString *name = voice;
                for (NSDictionary *p in MRGVoicePresets()) if ([p[@"elevenID"] isEqualToString:voice]) name = p[@"elevenIDName"] ?: voice;
                NSString *msg = [NSString stringWithFormat:@"ElevenLabs refused %@ (HTTP %ld): it isn't in your ElevenLabs voices. Add it in ElevenLabs → Voice Library, or tap Add to my ElevenLabs below.", name, (long)st];
                [D() setObject:@{@"id": voice, @"name": name, @"error": msg} forKey:@"mirage.dj.elevenNeedsAdd"];
                MRGDJLog(@"voice: %@ (%@)", msg, e ?: @"?");
            }
        }
        done(d, e);
    };
    // A model the plan, the voice or the settings don't take answers 400/403/422: the next model in line gets it.
    BOOL (^refused)(NSInteger) = ^BOOL(NSInteger st) { return st == 400 || st == 403 || st == 422; };
    void (^v2)(void) = ^{
        run(@"eleven_multilingual_v2", text, v2Settings, ^(NSData *d, NSInteger st, NSString *e) {
            if (d || !refused(st)) { finish(d, st, e); return; }
            run(@"eleven_flash_v2_5", text, v2Settings, ^(NSData *d2, NSInteger s2, NSString *e2) { finish(d2, s2, e2); });
        });
    };
    if ([kind isEqualToString:@"v3"] && preset && !sNoV3) {
        double stab = [preset[@"v3Stab"] doubleValue];
        NSDictionary *v3Settings = @{@"stability": @(stab < 0.25 ? 0.0 : stab < 0.75 ? 0.5 : 1.0), @"similarity_boost": @(MRGElevenSimilarity()),
                                     @"style": @(elevenStyle()), @"use_speaker_boost": @YES, @"speed": @(MIN(1.2, MAX(0.7, talk)))};
        run(@"eleven_v3", v3Text(text, preset), v3Settings, ^(NSData *d, NSInteger st, NSString *e) {
            if (d || !refused(st)) { finish(d, st, e); return; }
            sNoV3 = YES;
            MRGDJLog(@"voice: eleven_v3 refused (HTTP %ld), using eleven_multilingual_v2 for this session", (long)st);
            v2();
        });
        return;
    }
    if ([kind isEqualToString:@"flash"]) {
        run(@"eleven_flash_v2_5", text, v2Settings, ^(NSData *d, NSInteger st, NSString *e) {
            if (d || !refused(st)) { finish(d, st, e); return; }
            run(@"eleven_multilingual_v2", text, v2Settings, ^(NSData *d2, NSInteger s2, NSString *e2) { finish(d2, s2, e2); });
        });
        return;
    }
    v2();
}

static NSString *engineSummary(void);
NSString *MRGVoiceSummary(void) {
    NSString *pid = MRGVoicePresetID(), *name = nil;
    for (NSDictionary *p in MRGVoicePresets()) if ([p[@"id"] isEqualToString:pid]) name = p[@"name"];
    NSString *e = engineSummary();
    return name && MRGVoiceGetEngine() != MRGVoiceEngineOff ? [NSString stringWithFormat:@"%@ · %@", name, e] : e;
}
static NSString *engineSummary(void) {
    switch (MRGVoiceGetEngine()) {
        case MRGVoiceEngineOff: return @"Off";
        case MRGVoiceEngineProvider: {
            MRGProvider p = MRGAIProvider();
            if (!MRGProviderHasTTS(p)) break;
            return [NSString stringWithFormat:@"%@ · %@", MRGProviderName(p), MRGVoiceProviderVoice() ?: @"default"];
        }
        case MRGVoiceEngineFree: {
            NSString *vid = MRGEdgeVoice();
            for (NSDictionary *v in MRGEdgeVoices()) if ([v[@"id"] isEqualToString:vid]) return [@"Free · " stringByAppendingString:v[@"name"]];
            return [@"Free · " stringByAppendingString:vid];
        }
        case MRGVoiceEngineEleven: {
            if (!MRGElevenHasKey()) break;
            NSString *vid = MRGElevenVoice();
            for (NSDictionary *v in MRGElevenVoices()) if ([v[@"id"] isEqualToString:vid]) return [@"ElevenLabs · " stringByAppendingString:[v[@"name"] componentsSeparatedByString:@" - "].firstObject];
            NSDictionary *need = [D() dictionaryForKey:@"mirage.dj.elevenNeedsAdd"];
            if ([need[@"id"] isEqual:vid] && [need[@"name"] isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"ElevenLabs · %@ (by ID)", need[@"name"]];
            return vid.length ? [NSString stringWithFormat:@"ElevenLabs · %@", vid] : @"ElevenLabs";
        }
        default: break;
    }
    AVSpeechSynthesisVoice *v = MRGVoicePhoneVoice();
    return v ? [NSString stringWithFormat:@"%@ (%@)", v.name, MRGVoiceQualityName(v)] : @"Phone";
}

#pragma mark - speaker

static NSArray<NSString *> *sentences(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationBySentences usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        NSString *t = [sub stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) [out addObject:t];
    }];
    return out.count ? out : @[text];
}

// The sentences joined with `mark` after each (an ellipsis, or an ElevenLabs <break/>).
static NSString *withPauses(NSString *text, NSString *mark) {
    NSArray<NSString *> *s = sentences(text);
    if (s.count < 2) return text;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.count; i++) {
        NSString *x = s[i];
        if (i + 1 == s.count) { [out appendString:x]; break; }
        if ([mark isEqualToString:@"..."] && [x hasSuffix:@"."]) x = [x substringToIndex:x.length - 1];
        [out appendFormat:@"%@%@ ", x, mark];
    }
    return out;
}

@interface MRGVoiceSpeaker () <AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate>
@end

@implementation MRGVoiceSpeaker {
    AVSpeechSynthesizer *_synth;
    AVAudioPlayer *_audio;
    void (^_finished)(void);
    NSUInteger _token;
    NSUInteger _pending;
    AVSpeechUtterance *_lastUtterance;
    NSArray<AVSpeechUtterance *> *_batch;   // the current line's utterances: callbacks for older ones are ignored
    CFTimeInterval _audioStarted;
    BOOL _busyLine;
}

+ (instancetype)shared {
    static MRGVoiceSpeaker *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MRGVoiceSpeaker new]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _synth = [AVSpeechSynthesizer new];
    _synth.delegate = self;
    // The speech goes through its own session, never Spotify's, so playback is not touched.
    _synth.usesApplicationAudioSession = NO;
    // A call or Siri cuts the line off without any end callback: it is over, and the music comes back up.
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if ([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan && self->_busyLine) { MRGDJLog(@"voice: line cut off by an interruption"); [self stop]; }
    }];
    return self;
}

- (BOOL)isSpeaking { return _synth.isSpeaking || _audio.isPlaying; }
// Busy while a line is fetched or said. An AVAudioPlayer stopped by an interruption is not playing and says nothing,
// so a line whose audio stopped without an end is over too.
- (BOOL)isBusy {
    if (!_busyLine) return NO;
    if (_audio && !_audio.isPlaying && _audioStarted && CACurrentMediaTime() - _audioStarted > 0.5) { [self finish]; return NO; }
    return YES;
}

// The last line's result ("✓ ElevenLabs · Arabella spoke" or "✗ ElevenLabs: … (HTTP 402, …)"), for the voice page and
// the DJ sheet.
- (void)report:(NSString *)result failed:(BOOL)failed {
    _lastResult = [result copy];
    [NSNotificationCenter.defaultCenter postNotificationName:MRGVoiceResultNotification object:self userInfo:@{@"result": result ?: @"", @"failed": @(failed)}];
}

- (void)finish {
    _busyLine = NO;
    _audioStarted = 0;
    void (^f)(void) = _finished;
    _finished = nil;
    if (f) f();
}

- (void)stop {
    _token++;
    // A cancelled line's delegate callbacks arrive later; without this they ended the next line early (the caption
    // dropped and the music came back up while the new line was still being fetched).
    _batch = nil;
    _lastUtterance = nil;
    [_synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [_audio stop];
    _audio = nil;
    [self finish];
}

// 0.6.8 root cause of "the free voice fails and the ugly iPhone voice talks": Microsoft's endpoint resets a socket
// now and then right after the upgrade (NSPOSIXErrorDomain 54 in the diagnostics). One immediate retry wasn't enough,
// nothing was fetched ahead, and the first failure went straight to the phone's default voice. Now:
//  - the order is ElevenLabs first when a key is saved (unless turned off), then the free voice, then the AI provider's
//    voice when it has one, and the phone's best Premium / Enhanced voice only when all of them failed;
//  - the free voice retries with backoff and its own timeouts (MRGVoiceNet.m);
//  - lines are fetched ahead (prefetch:) and kept, so a line is often ready before it is said.
static NSCache *sg_lineCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_inflight;   // cache key → waiting completions

BOOL MRGVoicePrefersEleven(void) { id v = [D() objectForKey:@"mirage.dj.preferEleven"]; return [v isKindOfClass:NSNumber.class] ? [v boolValue] : YES; }
void MRGVoiceSetPrefersEleven(BOOL on) { [D() setBool:on forKey:@"mirage.dj.preferEleven"]; }

// The engines to try, in order, for the settings' engine (or one picked for a preview).
static NSArray<NSNumber *> *engineChain(NSInteger engineArg) {
    if (engineArg >= 0) return @[@(engineArg)];   // a preview tries the engine it is a preview of
    MRGVoiceEngine e = MRGVoiceGetEngine();
    NSMutableArray *out = [NSMutableArray array];
    BOOL eleven = MRGElevenHasKey() && (e == MRGVoiceEngineEleven || (MRGVoicePrefersEleven() && e != MRGVoiceEnginePhone));
    if (e == MRGVoiceEngineProvider && MRGProviderHasTTS(MRGAIProvider())) [out addObject:@(MRGVoiceEngineProvider)];
    if (eleven) [out addObject:@(MRGVoiceEngineEleven)];
    if (e != MRGVoiceEnginePhone) [out addObject:@(MRGVoiceEngineFree)];
    if (e != MRGVoiceEngineProvider && e != MRGVoiceEnginePhone && MRGProviderHasTTS(MRGAIProvider()) && [D() boolForKey:@"mirage.dj.providerFallback"]) [out addObject:@(MRGVoiceEngineProvider)];
    return out;
}

static NSString *voiceFor(MRGVoiceEngine e, NSString *voice, BOOL primary) {
    if (primary && voice.length) return voice;
    switch (e) {
        case MRGVoiceEngineEleven: return MRGElevenVoice();
        case MRGVoiceEngineFree: return MRGEdgeVoice();
        case MRGVoiceEngineProvider: return MRGVoiceProviderVoice();
        default: return nil;
    }
}

static NSString *engineLabel(MRGVoiceEngine e, NSString *voice) {
    if (e == MRGVoiceEngineFree) {
        for (NSDictionary *x in MRGEdgeVoices()) if ([x[@"id"] isEqualToString:voice]) return [@"Free · " stringByAppendingString:x[@"name"]];
        return [@"Free · " stringByAppendingString:voice ?: @"voice"];
    }
    if (e == MRGVoiceEngineEleven) return @"ElevenLabs";
    return MRGProviderName(MRGAIProvider());
}

static NSString *cacheKey(MRGVoiceEngine e, NSString *voice, NSString *text) {
    return [NSString stringWithFormat:@"%ld|%@|%.2f|%.2f|%.2f|%@", (long)e, voice ?: @"", MRGVoiceSpeed(), MRGVoicePitch(), MRGVoicePause(), text];
}

// One engine's audio for a line, from the cache or fetched (one fetch per line, however many ask).
static void fetchLine(MRGVoiceEngine e, NSString *voice, NSString *text, void (^done)(NSData *audio, NSString *error)) {
    if (!sg_lineCache) { sg_lineCache = [NSCache new]; sg_lineCache.totalCostLimit = 6 * 1024 * 1024; sg_inflight = [NSMutableDictionary dictionary]; }
    NSString *key = cacheKey(e, voice, text);
    NSData *hit = [sg_lineCache objectForKey:key];
    if (hit) { done(hit, nil); return; }
    NSMutableArray *waiting = sg_inflight[key];
    if (waiting) { [waiting addObject:[done copy]]; return; }
    waiting = [NSMutableArray arrayWithObject:[done copy]];
    sg_inflight[key] = waiting;
    void (^got)(NSData *, NSString *) = ^(NSData *audio, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *all = [sg_inflight[key] copy];
            [sg_inflight removeObjectForKey:key];
            if (audio.length) [sg_lineCache setObject:audio forKey:key cost:audio.length];
            for (void (^d)(NSData *, NSString *) in all) d(audio, error);
        });
    };
    double speed = MRGVoiceSpeed(), pause = MRGVoicePause();
    switch (e) {
        case MRGVoiceEngineEleven: {
            if (!MRGElevenHasKey()) { got(nil, @"there's no ElevenLabs key"); return; }
            NSString *said = pause >= 0.3 ? withPauses(text, [NSString stringWithFormat:@" <break time=\"%.1fs\" />", MIN(1.5, pause)]) : text;
            elevenSpeech(said, voice, speed, got);
            return;
        }
        case MRGVoiceEngineFree: {
            NSString *said = pause >= 0.4 ? withPauses(text, @"...") : text;
            MRGEdgeSpeech(said, voice, speed, MRGVoicePitch(), got);
            return;
        }
        case MRGVoiceEngineProvider: {
            MRGProvider p = MRGAIProvider();
            if (!MRGProviderHasTTS(p)) { got(nil, @"the AI provider has no voice"); return; }
            NSString *said = (p == MRGProviderGroq || p == MRGProviderXAI) && pause >= 0.5 ? withPauses(text, @"...") : text;
            MRGAISpeech(said, voice, speed, MRGVoiceInstructions(), got);
            return;
        }
        default: got(nil, @"no network voice"); return;
    }
}

// The best voice on the phone for a last resort: Personal, then Premium, then Enhanced, in the preset's gender when
// there is one, never a Default-quality voice while a better one is installed.
static AVSpeechSynthesisVoice *bestFallbackVoice(void) {
    NSString *gender = [activePreset()[@"gender"] isKindOfClass:NSString.class] ? activePreset()[@"gender"] : nil;
    NSArray<AVSpeechSynthesisVoice *> *all = MRGVoicePhoneVoices();   // best first
    if (gender.length) {
        AVSpeechSynthesisVoice *g = bestPhoneVoice(gender);
        if (g && voiceScore(g) >= voiceScore(all.firstObject)) return g;
    }
    AVSpeechSynthesisVoice *saved = MRGVoicePhoneVoice();
    if (saved && voiceScore(saved) >= voiceScore(all.firstObject)) return saved;
    return all.firstObject ?: saved;
}

- (void)prefetch:(NSString *)text {
    if (!text.length || MRGVoiceGetEngine() == MRGVoiceEngineOff) return;
    NSArray<NSNumber *> *chain = engineChain(-1);
    if (!chain.count) return;
    MRGVoiceEngine e = (MRGVoiceEngine)chain.firstObject.integerValue;
    fetchLine(e, voiceFor(e, nil, YES), text, ^(NSData *audio, NSString *error) {
        if (!audio && chain.count > 1) {
            MRGVoiceEngine e2 = (MRGVoiceEngine)chain[1].integerValue;
            fetchLine(e2, voiceFor(e2, nil, NO), text, ^(NSData *a2, NSString *e2r) {});
        }
    });
}

- (BOOL)playAudio:(NSData *)audio {
    _audio = [[AVAudioPlayer alloc] initWithData:audio error:nil];
    _audio.delegate = self;
    BOOL playing = _audio && [_audio play];
    if (playing) _audioStarted = CACurrentMediaTime();
    return playing;
}

- (void)speak:(NSString *)text engine:(NSInteger)engineArg voice:(NSString *)voice started:(void (^)(void))started finished:(void (^)(void))finished {
    [self stop];
    NSUInteger token = ++_token;
    _finished = [finished copy];
    _busyLine = YES;
    MRGVoiceEngine picked = engineArg >= 0 ? (MRGVoiceEngine)engineArg : MRGVoiceGetEngine();
    if (picked == MRGVoiceEnginePhone || (engineArg < 0 && picked == MRGVoiceEngineOff)) {
        AVSpeechSynthesisVoice *pv = (voice ? [AVSpeechSynthesisVoice voiceWithIdentifier:voice] : nil) ?: MRGVoicePhoneVoice();
        [self report:[NSString stringWithFormat:@"✓ iPhone · %@ spoke", pv.name ?: @"voice"] failed:NO];
        [self speakOnPhone:text voice:voice started:started];
        return;
    }
    NSArray<NSNumber *> *chain = engineChain(engineArg);
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    __block NSUInteger step = 0;
    __block void (^tryNext)(void);
    __weak MRGVoiceSpeaker *weakSelf = self;
    tryNext = ^{
        MRGVoiceSpeaker *me = weakSelf;
        if (!me || token != me->_token) { tryNext = nil; return; }
        if (step >= chain.count) {
            tryNext = nil;
            NSString *why = errors.count ? [errors componentsJoinedByString:@"; "] : @"no voice answered";
            if (engineArg == MRGVoiceEngineEleven) {
                // A preview of an ElevenLabs voice shows ElevenLabs' own error, never another voice.
                [me report:[@"✗ " stringByAppendingString:why] failed:YES];
                [me finish];
                return;
            }
            AVSpeechSynthesisVoice *best = bestFallbackVoice();
            MRGDJLog(@"voice: %@; the iPhone's %@ voice (%@) as a last resort", why, best.name ?: @"best", best ? MRGVoiceQualityName(best) : @"?");
            [me report:[NSString stringWithFormat:@"✗ %@; the iPhone voice %@ spoke instead", why, best.name ?: @""] failed:YES];
            [me speakOnPhone:text voice:best.identifier started:started];
            return;
        }
        MRGVoiceEngine e = (MRGVoiceEngine)chain[step].integerValue;
        NSString *v = voiceFor(e, voice, step == 0 && engineArg >= 0 ? YES : (step == 0 && voice != nil));
        NSString *what = engineLabel(e, v);
        step++;
        fetchLine(e, v, text, ^(NSData *audio, NSString *error) {
            MRGVoiceSpeaker *s = weakSelf;
            if (!s || token != s->_token) { tryNext = nil; return; }
            if (audio && [s playAudio:audio]) {
                tryNext = nil;
                NSString *label = e == MRGVoiceEngineEleven ? engineSummary() : what;
                if (errors.count) MRGDJLog(@"voice: %@ spoke after %@", what, [errors componentsJoinedByString:@"; "]);
                [s report:errors.count ? [NSString stringWithFormat:@"✓ %@ spoke (%@)", label, [errors componentsJoinedByString:@"; "]] : [NSString stringWithFormat:@"✓ %@ spoke", label] failed:NO];
                if (started) started();
                return;
            }
            [errors addObject:[NSString stringWithFormat:@"%@ failed (%@)", what, error ?: @"unplayable audio"]];
            void (^next)(void) = tryNext;
            if (next) next();
        });
    };
    tryNext();
}

// Sentence by sentence, with the pause setting after each (the last one ends the line).
- (void)speakOnPhone:(NSString *)text voice:(NSString *)identifier started:(void (^)(void))started {
    AVSpeechSynthesisVoice *voice = (identifier ? [AVSpeechSynthesisVoice voiceWithIdentifier:identifier] : nil) ?: MRGVoicePhoneVoice();
    float rate = AVSpeechUtteranceDefaultSpeechRate * (float)MRGVoiceSpeed();
    double pause = MRGVoicePause();
    NSArray *parts = pause >= 0.1 ? sentences(text) : @[text];
    _pending = parts.count;
    _lastUtterance = nil;
    NSMutableArray *batch = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; i++) {
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:parts[i]];
        u.voice = voice;
        u.rate = MIN(AVSpeechUtteranceMaximumSpeechRate, MAX(AVSpeechUtteranceMinimumSpeechRate, rate));
        u.pitchMultiplier = (float)MRGVoicePitch();
        u.volume = (float)num(@"mirage.dj.phoneVolume", 1.0, 0.3, 1.0);
        u.preUtteranceDelay = i == 0 ? 0.05 : 0;
        if (i + 1 < parts.count) u.postUtteranceDelay = pause;
        [batch addObject:u];
        _lastUtterance = u;
    }
    _batch = batch;
    for (AVSpeechUtterance *u in batch) [_synth speakUtterance:u];
    if (started) started();
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    if (!_lastUtterance || u != _lastUtterance) return;   // more sentences to come, or an older line
    [self finish];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { if ([_batch containsObject:u]) [self finish]; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag { if (p == _audio) [self finish]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error { if (p == _audio) [self finish]; }

@end
