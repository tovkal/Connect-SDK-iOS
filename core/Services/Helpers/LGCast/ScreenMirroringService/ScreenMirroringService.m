//
//  ScreenMirroringService.m
//  LGCast
//
//  Copyright (c) 2022 LG Electronics. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <LGCast/LGCast-Swift.h>

#import "ScreenMirroringService.h"
#import "ConnectionManager.h"
#import "MobileCapability.h"
#import "MirroringSourceCapability.h"
#import "MirroringSinkCapability.h"

@interface ScreenMirroringService() <ConnectionManagerDelegate, LGCastMirroringApiDelegate>

@property ConnectionManager *connectionManager;
@property BOOL isRunning;

@property MirroringSourceCapability *sourceCapability;
@property MirroringSinkCapability *sinkCapability;

@end

NSString *const kSMKeyMirroring = @"mirroring";
NSString *const kSMKeyResult = @"result";

NSString *const kSMKeyDisplayOrientation = @"displayOrientation";

NSString *const kSMValueOrientationPortrait = @"portrait";
NSString *const kSMValueOrientationLandscape = @"landscape";

@implementation ScreenMirroringService

+ (instancetype)sharedInstance {
    static ScreenMirroringService *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ScreenMirroringService alloc] initPrivate];
    });
    
    return shared;
}

- (instancetype)init {
    return [[self class] sharedInstance];
}

- (instancetype)initPrivate {
    self = [super init];
    
    _isRunning = NO;
    _connectionManager = ConnectionManager.sharedInstance;
    _connectionManager.delegate = self;
    [[LGCastMirroringApi shared] setDelegate:self];
    
    return self;
}

- (void)startMirroring:(ConnectableDevice *)device settings:(nullable NSDictionary<NSString *,id> *)settings {
    [LGLog infoLGCast:@"startMirroring"];
    
    if (self.isRunning == NO) {
        self.isRunning = YES;
        [_connectionManager openConnection:kServiceTypeScreenMirroring device:device];
    } else {
        [self sendStartEvent:NO];
    }
}

- (void)stopMirroring {
    [LGLog infoLGCast:@"stopMirroring"];
    
    if (self.isRunning == YES) {
        self.isRunning = NO;
        [[LGCastMirroringApi shared] stopMirroring];
        [_connectionManager closeConnection];
        [self sendStopEvent:YES];
    } else {
        [self sendStopEvent:NO];
    }
}

- (void)pushSampleBuffer:(CMSampleBufferRef)sampleBuffer with:(RPSampleBufferType)sampleBufferType {
    if (self.isRunning == NO) {
        return;
    }
    
    if (sampleBufferType != RPSampleBufferTypeVideo && sampleBufferType != RPSampleBufferTypeAudioApp) {
        return;
    }
    
    [[LGCastMirroringApi shared] pushSampleBuffer:sampleBuffer with:sampleBufferType];
}

// MARK: ConnectionManagerDelegate

- (void)onPairingRequested {
    [LGLog infoLGCast:@"onPairingRequested"];
}

- (void)onPairingRejected {
    [LGLog infoLGCast:@"onPairingRejected"];
    
    self.isRunning = NO;
    [self sendStartEvent:NO];
}

- (void)onConnectionFailed:(NSString *)message {
    [LGLog errorLGCast:[NSString stringWithFormat:@"onConnectionFailed %@", message]];
    
    self.isRunning = NO;
    [self sendStartEvent:NO];
}

- (void)onConnectionCompleted:(NSDictionary *)values {
    [LGLog infoLGCast:@"onConnectionCompleted"];
    
    if (values == nil) {
        [LGLog errorLGCast:@"invalid parameter"];
        return;
    }
    
    _sinkCapability = [[MirroringSinkCapability alloc] initWithInfo:values];
    
    LGCastMirroringMediaSettings *mediaSettings = [[LGCastMirroringMediaSettings alloc] init];
    mediaSettings.audio = [[LGCastMirroringAudioSettings alloc] init];
    mediaSettings.video = [[LGCastMirroringVideoSettings alloc] init];

    LGCastMirroringInfo *mirroringInfo = [[LGCastMirroringApi shared] setMediaSettings:mediaSettings];
    _sourceCapability = [[MirroringSourceCapability alloc] init];

    if (mirroringInfo.videoInfo != nil) {
        _sourceCapability.videoCodec = mirroringInfo.videoInfo.codec;
        _sourceCapability.videoWidth = mirroringInfo.videoInfo.width;
        _sourceCapability.videoHeight = mirroringInfo.videoInfo.height;
        _sourceCapability.videoActiveWidth = mirroringInfo.videoInfo.activeWidth;
        _sourceCapability.videoActiveHeight = mirroringInfo.videoInfo.activeHeight;
        _sourceCapability.videoFramerate = mirroringInfo.videoInfo.framerate;
        _sourceCapability.videoClockRate = mirroringInfo.videoInfo.samplingRate;
        _sourceCapability.videoOrientation  = mirroringInfo.videoInfo.isPortraitMode ? kSMValueOrientationPortrait :kSMValueOrientationLandscape;
        _sourceCapability.screenOrientation = mirroringInfo.videoInfo.screenOrientation;
    }

    if (mirroringInfo.audioInfo != nil) {
        _sourceCapability.audioCodec = mirroringInfo.audioInfo.codec;
        _sourceCapability.audioFrequency = mirroringInfo.audioInfo.samplingRate;
        _sourceCapability.audioClockRate = mirroringInfo.audioInfo.samplingRate;
        _sourceCapability.audioChannels = mirroringInfo.audioInfo.channelCnt;
        _sourceCapability.audioStreamMuxConfig = mirroringInfo.audioInfo.streamMuxConfig;
    }
    
    NSArray<LGCastSecurityKey *> *keys = [[LGCastMirroringApi shared] generateMirroringMasterKey:_sinkCapability.publicKey];
    [_sourceCapability setSecurityKeys:keys];
    
    MobileCapability *mobileCapability = [[MobileCapability alloc] init];
    [_connectionManager setSourceDeviceInfo:[_sourceCapability toNSDictionary]
                                 deviceInfo:[mobileCapability toNSDictionary]];
}

- (void)onReceivePlayCommand:(NSDictionary *)values {
    [LGLog infoLGCast:@"onReceivePlayCommand"];
    
    LGCastDeviceSettings *deviceSettings = [[LGCastDeviceSettings alloc] init];
    deviceSettings.host = _sinkCapability.ipAddress;
    deviceSettings.audioPort = _sinkCapability.audioUdpPort;
    deviceSettings.videoPort = _sinkCapability.videoUdpPort;
    BOOL isPortraitMode = [_sinkCapability.displayOrientation caseInsensitiveCompare:kSMValueOrientationPortrait] == NSOrderedSame ? YES : NO;
    deviceSettings.isPortraitMode = isPortraitMode;

    [[LGCastMirroringApi shared] startMirroring:deviceSettings];
}

- (void)onReceiveStopCommand:(NSDictionary *)values {
    [LGLog infoLGCast:@"onReceiveStopCommand"];
}

- (void)onReceiveGetParameter:(NSDictionary *)values {
    [LGLog infoLGCast:@"onReceiveGetParameter"];
}

- (void)onReceiveSetParameter:(NSDictionary *)values {
    [LGLog infoLGCast:@"onReceiveSetParameter"];
        
    NSDictionary* mirroringValues = values[kSMKeyMirroring];
    if (mirroringValues == nil) {
        return;
    }
    
    if (_sinkCapability == nil) {
        [LGLog errorLGCast:@"Unable to handle this event"];
        return;
    }
    
    NSString *displayOrientation = mirroringValues[kSMKeyDisplayOrientation];
    _sinkCapability.displayOrientation = displayOrientation;
    
    BOOL isPortraitMode = [_sinkCapability.displayOrientation caseInsensitiveCompare:kSMValueOrientationPortrait] == NSOrderedSame ? YES : NO;
    LGCastMirroringInfo *castSetting = [[LGCastMirroringApi shared] updateDisplayOrientationWithIsPortraitMode:isPortraitMode];
    
    if (_sourceCapability != nil) {
        _sourceCapability.videoWidth = castSetting.playerInfo.width;
        _sourceCapability.videoHeight = castSetting.playerInfo.height;
        _sourceCapability.videoActiveWidth = castSetting.videoInfo.activeWidth;
        _sourceCapability.videoActiveHeight = castSetting.videoInfo.activeHeight;
        _sourceCapability.videoOrientation = castSetting.videoInfo.isPortraitMode ? @"portrait" : @"landscape";
        
        [self updateCapability:[_sourceCapability toNSDictionaryVideoSize]];
    }
}

- (void)onError:(ConnectionError)error message:(NSString *)message {
    [LGLog errorLGCast:[NSString stringWithFormat:@"onError %d %@", error, message]];

    ScreenMirroringError controlError = ScreenMirroringErrorGeneric;
    switch (error) {
        case kConnectionErrorUnknown:
            [LGLog errorLGCast:@"kConnectionErrorUnknown"];
            controlError = ScreenMirroringErrorGeneric;
            break;
        case kConnectionErrorConnectionClosed:
            [LGLog errorLGCast:@"kConnectionErrorConnectionClosed"];
            controlError = ScreenMirroringErrorConnectionClosed;
            break;
        case kConnectionErrorDeviceShutdown:
            [LGLog errorLGCast:@"kConnectionErrorDeviceShutdown"];
            controlError = ScreenMirroringErrorDeviceShutdown;
            break;
        case kConnectionErrorRendererTerminated:
            [LGLog errorLGCast:@"kConnectionErrorRendererTerminated"];
            controlError = ScreenMirroringErrorRendererTerminated;
            break;
        default:
            break;
    }
    
    self.isRunning = NO;
    [[LGCastMirroringApi shared] stopMirroring];
    
    [self sendErrorEvent:controlError];
}

// MARK: LGCastMirroringApiDelegate

- (void)lgcastMirroringDidStartWithResult:(BOOL)result {
    [LGLog infoLGCast:@"lgcastMirroringDidStartWithResult"];
    if (result) {
        [self sendStartEvent:YES];
    }
}

- (void)lgcastMirroringDidStopWithResult:(BOOL)result {
    [LGLog infoLGCast:@"lgcastMirroringDidStopWithResult"];
}

- (void)lgcastMirroringErrorDidOccurWithError:(enum LGCastMirroringError)error {
    [LGLog errorLGCast:[NSString stringWithFormat:@"lgcastMirroringErrorDidOccurWithError %d", (int)error]];
    
    ScreenMirroringError errorType = ScreenMirroringErrorGeneric;
    switch (error) {
        case LGCastMirroringErrorUnknown:
            errorType = ScreenMirroringErrorGeneric;
            break;
        case LGCastMirroringErrorConnectionClosed:
            errorType = ScreenMirroringErrorConnectionClosed;
            break;
        case LGCastMirroringErrorDeviceShutdown:
            errorType = ScreenMirroringErrorDeviceShutdown;
            break;
        case LGCastMirroringErrorRendererTerminated:
            errorType = ScreenMirroringErrorRendererTerminated;
            break;
        default:
            errorType = ScreenMirroringErrorGeneric;
            break;
    }

    self.isRunning = NO;
    [self sendErrorEvent:error];
}

- (void)lgcastMirroringUpdateEventWithEvent:(enum LGCastMirroringEvent)event info:(LGCastMirroringInfo *)info {
    [LGLog infoLGCast:@"lgcastMirroringUpdateEventWithEvent"];
    
    if (event == LGCastMirroringEventUpdateVideoVideoSize) {
        if (_sourceCapability != nil && info != nil && info.videoInfo) {
            _sourceCapability.videoWidth = info.playerInfo.width;
            _sourceCapability.videoHeight = info.playerInfo.height;
            _sourceCapability.videoActiveWidth = info.videoInfo.activeWidth;
            _sourceCapability.videoActiveHeight = info.videoInfo.activeHeight;
            _sourceCapability.videoOrientation = info.videoInfo.isPortraitMode == YES ? @"portrait" : @"landscape";

            [self updateCapability:[_sourceCapability toNSDictionaryVideoSize]];
        }
    }
}

- (void)updateCapability:(NSDictionary*)capability {
    if (!_isRunning) {
        return;
    }
    
    [_connectionManager sendSetParameter:capability ignoreResult:YES];
}

- (void)sendStartEvent:(BOOL)result {
    if(_delegate != nil && [_delegate respondsToSelector:@selector(screenMirroringDidStart:)]){
        [_delegate screenMirroringDidStart:result];
    }
}

- (void)sendStopEvent:(BOOL)result {
    if(_delegate != nil && [_delegate respondsToSelector:@selector(screenMirroringDidStop:)]){
        [_delegate screenMirroringDidStop:result];
    }
}

- (void)sendErrorEvent:(ScreenMirroringError)error {
    if(_delegate != nil && [_delegate respondsToSelector:@selector(screenMirroringErrorDidOccur:)]){
        [_delegate screenMirroringErrorDidOccur:error];
    }
}

@end
