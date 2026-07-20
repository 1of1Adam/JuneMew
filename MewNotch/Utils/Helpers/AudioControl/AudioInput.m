//
//  AudioInput.m
//  MewNotch
//
//  Created by Monu Kumar on 11/03/25.
//


#include "AudioInput.h"
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioServices.h>


NSString *AudioInputVolumeNotification = @"AudioInputVolume";
NSString *AudioInputDeviceNotification = @"AudioInputDevice";

@interface AudioInput ()
- (void)systemObjectPropertyDidChange;
- (void)audioDevicePropertyDidChange;
@end

static OSStatus SystemObjectPropertyListener(
    AudioObjectID device,
    UInt32 count, const AudioObjectPropertyAddress* addresses,
    void *data)
{
    [(__bridge id)data
        performSelectorOnMainThread:@selector(systemObjectPropertyDidChange)
        withObject:nil
        waitUntilDone:NO];
    
    return kAudioHardwareNoError;
}

static OSStatus AudioDeviceMuteListener(
    AudioObjectID device,
    UInt32 count, const AudioObjectPropertyAddress* addresses,
    void *data)
{
    [(__bridge AudioInput *)data
        performSelectorOnMainThread:@selector(audioDevicePropertyDidChange)
        withObject:@"mute"
        waitUntilDone:NO];
    return kAudioHardwareNoError;
}

static OSStatus AudioDeviceVolumeListener(
    AudioObjectID device,
    UInt32 count, const AudioObjectPropertyAddress* addresses,
    void *data)
{
    [(__bridge AudioInput *)data
        performSelectorOnMainThread:@selector(audioDevicePropertyDidChange)
        withObject:@"volume"
        waitUntilDone:NO];
    return kAudioHardwareNoError;
}

@implementation AudioInput
{
    AudioObjectPropertySelector _selector;
    AudioObjectPropertyScope _scope;
    AudioDeviceID _device;
}

+ (AudioInput *)sharedInstance
{
    static AudioInput *instance = 0;
    if (0 == instance)
        instance = [[AudioInput alloc] init];
    return instance;
}

- (id)init
{
    self = [super init];
    if (nil == self)
        return nil;

    _device = kAudioObjectUnknown;
    _selector = kAudioHardwarePropertyDefaultInputDevice;
    _scope = kAudioDevicePropertyScopeInput;

    [self registerSystemObjectListener:YES];
    [self getAudioDevice:YES];

    return self;
}

- (void)dealloc
{
    [self resetAudioDevice];
    [self registerSystemObjectListener:NO];
}

- (NSString *)deviceName
{
    AudioObjectPropertyAddress address =
    {
        .mSelector = kAudioObjectPropertyName,
        .mScope = _scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    
    __block NSString * name = @"";
    
    [self _retry:^OSStatus(AudioDeviceID audiodev)
    {
        UInt32 size = sizeof name;
        return AudioObjectGetPropertyData(audiodev, &address, 0, 0, &size, &name);
    }];

    return name;
}

- (float)volume
{
    AudioObjectPropertyAddress address =
    {
        .mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        .mScope = _scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    __block Float32 volume = NAN;
    OSStatus status;

    status = [self _retry:^OSStatus(AudioDeviceID audiodev)
    {
        UInt32 size = sizeof volume;
        return AudioObjectGetPropertyData(audiodev, &address, 0, 0, &size, &volume);
    }];
    if (kAudioHardwareNoError != status)
    {
        return NAN;
    }

    return volume;
}

- (void)setVolume:(float)value
{
    AudioObjectPropertyAddress address =
    {
        .mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        .mScope = _scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    Float32 volume = value;
    OSStatus status;

    status = [self _retry:^OSStatus(AudioDeviceID audiodev)
    {
        return AudioObjectSetPropertyData(audiodev, &address, 0, 0, sizeof volume, &volume);
    }];
}

- (BOOL)isMute
{
    AudioObjectPropertyAddress address =
    {
        .mSelector = kAudioDevicePropertyMute,
        .mScope = _scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    __block UInt32 mute = 0;
    OSStatus status;

    status = [self _retry:^OSStatus(AudioDeviceID audiodev)
    {
        UInt32 size = sizeof mute;
        return AudioObjectGetPropertyData(audiodev, &address, 0, 0, &size, &mute);
    }];
    if (kAudioHardwareNoError != status)
    {
        return FALSE;
    }

    return !!mute;
}

- (void)setMute:(BOOL)value
{
    AudioObjectPropertyAddress address =
    {
        .mSelector = kAudioDevicePropertyMute,
        .mScope = _scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 mute = !!value;
    OSStatus status;

    status = [self _retry:^OSStatus(AudioDeviceID audiodev)
    {
        return AudioObjectSetPropertyData(audiodev, &address, 0, 0, sizeof mute, &mute);
    }];
}

- (OSStatus)_retry:(OSStatus (^)(AudioDeviceID audiodev))block
{
    OSStatus status = kAudioHardwareNoError;

    for (NSUInteger i = 0; 2 > i; i++)
    {
        status = block([self getAudioDevice:0 != i]);
        if (kAudioHardwareBadObjectError != status)
            break;
    }

    return status;
}

- (AudioDeviceID)getAudioDevice:(BOOL)init
{
    if (kAudioObjectUnknown == _device || init)
    {
        AudioObjectPropertyAddress address =
        {
            .mSelector = _selector,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        AudioDeviceID device = kAudioObjectUnknown;
        UInt32 size = sizeof device;
        OSStatus status;

        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, 0, &size, &device);
        if (kAudioHardwareNoError == status)
        {
            _device = device;

            AudioObjectPropertyAddress muteAddress =
            {
                .mSelector = kAudioDevicePropertyMute,
                .mScope = _scope,
                .mElement = kAudioObjectPropertyElementMain,
            };

            status = AudioObjectAddPropertyListener(device, &muteAddress, AudioDeviceMuteListener, (__bridge void * _Nullable)(self));
            if (status != kAudioHardwareNoError) {
                NSLog(@"Failed to add mute listener: %d", (int)status);
            }

            AudioObjectPropertyAddress volumeAddress =
            {
                .mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                .mScope = _scope,
                .mElement = kAudioObjectPropertyElementMain,
            };

            status = AudioObjectAddPropertyListener(device, &volumeAddress, AudioDeviceVolumeListener, (__bridge void * _Nullable)(self));
            if (status != kAudioHardwareNoError) {
                NSLog(@"Failed to add volume listener: %d", (int)status);
            }
        }
    }

    return _device;
}

- (void)resetAudioDevice
{
    if (kAudioObjectUnknown != _device)
    {
        AudioObjectPropertyAddress muteAddress =
        {
            .mSelector = kAudioDevicePropertyMute,
            .mScope = _scope,
            .mElement = kAudioObjectPropertyElementMain,
        };
        OSStatus status;

        status = AudioObjectRemovePropertyListener(_device, &muteAddress, AudioDeviceMuteListener, (__bridge void * _Nullable)(self));

        AudioObjectPropertyAddress volumeAddress =
        {
            .mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            .mScope = _scope,
            .mElement = kAudioObjectPropertyElementMain,
        };
        
        status = AudioObjectRemovePropertyListener(_device, &volumeAddress, AudioDeviceVolumeListener, (__bridge void * _Nullable)(self));
    }
}

- (void)registerSystemObjectListener:(BOOL)add
{
    AudioObjectPropertyAddress address =
    {
        .mSelector = _selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    OSStatus status;

    if (add) {
        status = AudioObjectAddPropertyListener(
            kAudioObjectSystemObject,
            &address,
            SystemObjectPropertyListener,
            (__bridge void *)(self)
        );
    } else {
        status = AudioObjectRemovePropertyListener(
           kAudioObjectSystemObject,
           &address,
           SystemObjectPropertyListener,
           (__bridge void *)(self)
       );
    }
}

- (void)systemObjectPropertyDidChange
{
    [self resetAudioDevice];
    [self getAudioDevice:YES];
    
    [[NSNotificationCenter defaultCenter]
     postNotificationName:AudioInputDeviceNotification
     object:self
     userInfo: nil
    ];
}

- (void)audioDevicePropertyDidChange
{
    [[NSNotificationCenter defaultCenter]
     postNotificationName:AudioInputVolumeNotification
     object:self
     userInfo:nil
    ];
}
@end
