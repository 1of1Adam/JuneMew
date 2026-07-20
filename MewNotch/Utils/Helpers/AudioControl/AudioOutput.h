//
//  AudioOutput.h
//  MewNotch
//
//  Created by Monu Kumar on 11/03/2025.
//

#include <AudioToolbox/AudioServices.h>

@interface AudioOutput: NSObject
+ (AudioOutput*) sharedInstance;
@property (nonatomic, copy) NSString * deviceName;
@property (getter=volume, setter=setVolume:) float volume;
@property (getter=isMute, setter=setMute:) BOOL mute;
@end

extern NSString *AudioOutputVolumeNotification;
extern NSString *AudioOutputDeviceNotification;
