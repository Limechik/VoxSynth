#import "VoxSynth.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "FormantCore.h"
#import "Phonemes.h"

static const float  kRate           = 22050.0f;
static const int    kNumAQBuffers   = 3;
static const UInt32 kAQBufferFrames = 4096;                 // ~0.19 с на буфер при 22050 Гц
static const UInt32 kAQBufferBytes  = kAQBufferFrames * 2;  // 16 бит моно

static void AQOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);

@interface VoxSynth () {
    AudioQueueRef       _queue;
    AudioQueueBufferRef _buffers[3];
    NSMutableData      *_pending;          // готовый PCM, ещё не отданный AudioQueue
    NSCondition        *_cond;             // защищает _pending и флаги ниже
    BOOL                _finishedProducing;// синтез всего текста завершён
    BOOL                _stopping;         // пользователь вызвал -stop
    dispatch_queue_t    _synthQueue;       // фоновая очередь синтеза речи
}
- (void)configureAudioSession;
- (void)handleInterruption:(NSNotification *)note;
- (void)produceSpeechForText:(NSString *)text speed:(float)speed;
- (NSArray<NSString *> *)splitIntoSentences:(NSString *)text;
- (NSData *)renderPCMForText:(NSString *)text speed:(float)speed;
- (void)fillBuffer:(AudioQueueBufferRef)buffer stopped:(BOOL *)stopped;
@end

@implementation VoxSynth

+ (instancetype)shared {
    static VoxSynth *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VoxSynth new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _speed = 1.0f;
        _cond = [NSCondition new];
        _synthQueue = dispatch_queue_create("com.voxsynth.synth", DISPATCH_QUEUE_SERIAL);
        [self configureAudioSession];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - AVAudioSession

- (void)configureAudioSession {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&err]) {
        NSLog(@"VoxSynth: не удалось задать категорию звуковой сессии: %@", err);
    }
    err = nil;
    if (![session setActive:YES error:&err]) {
        NSLog(@"VoxSynth: не удалось активировать звуковую сессию: %@", err);
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(handleInterruption:)
                                                  name:AVAudioSessionInterruptionNotification
                                                object:session];
}

- (void)handleInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        [self stop];    // звонок/будильник и т.п. — просто прерываем речь
    }
}

#pragma mark - Публичный API

- (BOOL)isSpeaking { return _queue != NULL; }

- (void)speak:(NSString *)text {
    [self stop];   // на всякий случай прерываем предыдущую речь перед новой

    _pending = [NSMutableData data];
    _finishedProducing = NO;
    _stopping = NO;

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate       = kRate;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel   = 16;
    fmt.mChannelsPerFrame = 1;
    fmt.mBytesPerFrame    = 2;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = 2;

    OSStatus status = AudioQueueNewOutput(&fmt, AQOutputCallback,
                                           (__bridge void *)self, NULL, NULL, 0, &_queue);
    if (status != noErr) {
        NSLog(@"VoxSynth: AudioQueueNewOutput вернул ошибку %d", (int)status);
        _queue = NULL;
        return;
    }
    for (int i = 0; i < kNumAQBuffers; i++) {
        AudioQueueAllocateBuffer(_queue, kAQBufferBytes, &_buffers[i]);
    }

    // Синтез идёт в фоне, предложение за предложением — так первый звук
    // появляется быстро даже для длинного текста, и в памяти не нужно
    // держать PCM всей фразы целиком.
    NSString *textCopy = [text copy];
    float speed = _speed;
    dispatch_async(_synthQueue, ^{
        [self produceSpeechForText:textCopy speed:speed];
    });

    // Прогреваем очередь: к этому моменту первое предложение почти наверняка
    // уже готово (синтез в разы быстрее воспроизведения), так что реального
    // ожидания внутри -fillBuffer: обычно не происходит.
    for (int i = 0; i < kNumAQBuffers; i++) {
        BOOL stop = NO;
        [self fillBuffer:_buffers[i] stopped:&stop];
        AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
    }
    AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, 1.0f);
    AudioQueueStart(_queue, NULL);
}

- (void)stop {
    if (!_queue) return;
    [_cond lock];
    _stopping = YES;
    [_cond signal];
    [_cond unlock];

    AudioQueueStop(_queue, true);      // true = остановить немедленно
    AudioQueueDispose(_queue, true);
    _queue = NULL;
    _pending = nil;
}

#pragma mark - Синтез (фоновая очередь)

// Режет текст на предложения по . ! ? — каждое озвучивается и добавляется в
// общий буфер отдельно: воспроизведение стартует раньше и не ждёт весь текст.
- (void)produceSpeechForText:(NSString *)text speed:(float)speed {
    for (NSString *sentence in [self splitIntoSentences:text]) {
        [_cond lock];
        BOOL stopping = _stopping;
        [_cond unlock];
        if (stopping) break;

        NSData *pcm = [self renderPCMForText:sentence speed:speed];
        if (pcm.length == 0) continue;

        [_cond lock];
        [_pending appendData:pcm];
        [_cond signal];
        [_cond unlock];
    }
    [_cond lock];
    _finishedProducing = YES;
    [_cond signal];
    [_cond unlock];
}

- (NSArray<NSString *> *)splitIntoSentences:(NSString *)text {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        [cur appendFormat:@"%C", ch];
        if (ch == '.' || ch == '!' || ch == '?') {
            [out addObject:[cur copy]];
            [cur setString:@""];
        }
    }
    if (cur.length > 0) [out addObject:[cur copy]];
    return out;
}

// Синтезирует фрагмент текста в "сырой" 16-бит PCM без WAV-заголовка —
// именно такие байты AudioQueue проигрывает буферами.
- (NSData *)renderPCMForText:(NSString *)text speed:(float)speed {
    NSData *u32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *cps = (const uint32_t *)u32.bytes;
    size_t nc = u32.length / 4;
    if (nc == 0) return [NSData data];

    size_t segCap = 8 * nc + 16;
    FCSegment *segs = calloc(segCap, sizeof(FCSegment));
    size_t ns = PHTextToSegments(cps, nc, segs, segCap, speed > 0 ? speed : 1.0f);

    size_t cap = FCTotalSamples(segs, ns, kRate) + 100;
    int16_t *pcm = calloc(cap, sizeof(int16_t));
    size_t samples = FCRender(segs, ns, pcm, cap, kRate);

    NSData *data = [NSData dataWithBytes:pcm length:samples * sizeof(int16_t)];
    free(segs);
    free(pcm);
    return data;
}

#pragma mark - Заполнение буфера AudioQueue

// Забирает готовые байты из _pending в буфер AudioQueue. Если синтез
// временно не успевает — остаток буфера заполняется тишиной, чтобы очередь
// не остановилась с ошибкой нехватки данных. *stopped становится YES, когда
// в этом буфере не оказалось вообще никакого звука И весь текст уже
// синтезирован — это значит, что реальная речь уже вся отыграна раньше и
// пора остановить очередь.
//
// ВАЖНО (упрощение): эта функция может ненадолго заблокировать поток,
// который её вызвал — включая внутренний поток AudioQueue, если данных пока
// нет. Поскольку синтез на порядки быстрее воспроизведения, на практике
// ожидание почти всегда мгновенное; но это не "честный" lock-free аудио-
// поток, как в профессиональных движках. Для этого проекта — осознанный
// компромисс ради простоты и надёжности.
- (void)fillBuffer:(AudioQueueBufferRef)buffer stopped:(BOOL *)stopped {
    UInt32 want = buffer->mAudioDataBytesCapacity;
    UInt8 *dst = (UInt8 *)buffer->mAudioData;

    [_cond lock];
    while (_pending.length == 0 && !_finishedProducing && !_stopping) {
        [_cond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    UInt32 avail = (UInt32)MIN((NSUInteger)want, _pending.length);
    if (avail > 0) {
        memcpy(dst, _pending.bytes, avail);
        [_pending replaceBytesInRange:NSMakeRange(0, avail) withBytes:NULL length:0];
    }
    BOOL noMoreEver = (avail == 0) && (_finishedProducing || _stopping);
    [_cond unlock];

    if (avail < want) memset(dst + avail, 0, want - avail);   // тишина-заполнитель
    buffer->mAudioDataByteSize = want;
    if (stopped) *stopped = noMoreEver;
}

@end

static void AQOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    VoxSynth *me = (__bridge VoxSynth *)inUserData;
    BOOL stopped = NO;
    [me fillBuffer:inBuffer stopped:&stopped];
    if (stopped) {
        AudioQueueStop(inAQ, false);   // доиграть уже поставленные буферы и остановиться
        return;                        // этот буфер обратно не ставим — в нём пусто
    }
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}
