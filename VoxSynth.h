// VoxSynth.h — Objective-C обёртка (iOS 6.1+, ARC).
// Потоковое воспроизведение через AudioQueue: речь начинает звучать почти
// сразу, память не растёт под весь текст целиком, есть -stop.
#import <Foundation/Foundation.h>

@interface VoxSynth : NSObject
+ (instancetype)shared;

@property (nonatomic) float speed;                       // 1.0 — обычный темп
@property (nonatomic, readonly, getter=isSpeaking) BOOL speaking;

// Синтез в WAV целиком в памяти — пригодится для сохранения/экспорта файла,
// не использует AudioQueue.
- (NSData *)wavDataForText:(NSString *)text;

// Синтез + потоковое воспроизведение через AudioQueue.
- (void)speak:(NSString *)text;

// Немедленно прерывает текущую речь.
- (void)stop;
@end
