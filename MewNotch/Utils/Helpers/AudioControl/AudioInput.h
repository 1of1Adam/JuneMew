//
//  AudioInput.h
//  MewNotch
//
//  Created by Monu Kumar on 11/03/25.
//

#include <AudioToolbox/AudioServices.h>

@interface AudioInput: NSObject
+ (AudioInput*) sharedInstance;
@property (nonatomic, copy) NSString * deviceName;
@property (getter=volume, setter=setVolume:) float volume;
@property (getter=isMute, setter=setMute:) BOOL mute;
@end

extern NSString *AudioInputVolumeNotification;
extern NSString *AudioInputDeviceNotification;
