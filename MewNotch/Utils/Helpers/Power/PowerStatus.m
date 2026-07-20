/**
 * @file PowerStatus.m
 *
 * @copyright 2018-2019 Bill Zissimopoulos
 */
/*
 * This file is part of EnergyBar.
 *
 * You can redistribute it and/or modify it under the terms of the GNU
 * General Public License version 3 as published by the Free Software
 * Foundation.
 */

#import "PowerStatus.h"
#import <IOKit/ps/IOPowerSources.h>

static void PowerStatusCallback(void *context)
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName: PowerStatusNotification
     object: (__bridge id _Nullable)(context)
    ];
}

@implementation PowerStatus
{
    CFRunLoopSourceRef _source;
}

+ (PowerStatus *)sharedInstance
{
    static PowerStatus *instance = 0;
    if (0 == instance)
        instance = [[PowerStatus alloc] init];
    return instance;
}

- (id)init
{
    CFRunLoopSourceRef source = IOPSNotificationCreateRunLoopSource(PowerStatusCallback, (__bridge void *)(self));
    if (0 == source)
        return nil;

    self = [super init];
    if (nil == self)
        return nil;

    _source = source;
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _source, kCFRunLoopDefaultMode);

    return self;
}

- (void)dealloc
{
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _source, kCFRunLoopDefaultMode);
}

- (float)getBatteryLevel
{
    CFArrayRef list = IOPSCopyPowerSourcesList(IOPSCopyPowerSourcesInfo());
    
    CFIndex count = CFArrayGetCount(list);
    
    if (count == 0) {
        return NAN;
    }
    
    NSDictionary *battery = nil;

    for(int i = 0; i < count; ++i  ) {
        NSDictionary *source = CFArrayGetValueAtIndex(
           list,
           i
        );
        
        if([source[@"Type"]  isEqual: @"InternalBattery"]) {
            battery = source;
            break;
        }
    }
    
    if(battery == nil) {
        return NAN;
    }
    
    NSNumber *currentCapacity = battery[@"Current Capacity"];
    NSNumber *maxCapacity = battery[@"Max Capacity"];
    
    float percentage =  [currentCapacity floatValue] / [maxCapacity floatValue];

    return percentage;
}

- (NSTimeInterval)remainingTime
{
    NSTimeInterval time = IOPSGetTimeRemainingEstimate();
    if (kIOPSTimeRemainingUnknown == time)
        time = NAN;
    else if (kIOPSTimeRemainingUnlimited == time)
        time = +INFINITY;
    return time;
}

- (NSString *)providingSource
{
    NSString *source = nil;

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (0 != blob)
    {
        source = (__bridge NSString *)IOPSGetProvidingPowerSourceType(blob);

        CFRelease(blob);
    }

    return source;
}

@end

NSString *PowerStatusACPower = @kIOPMACPowerKey;
NSString *PowerStatusBatteryPower = @kIOPMBatteryPowerKey;
NSString *PowerStatusUPSPower = @kIOPMUPSPowerKey;
NSString *PowerStatusSourceState = @kIOPSPowerSourceStateKey;
NSString *PowerStatusCurrentCapacity = @kIOPSCurrentCapacityKey;
NSString *PowerStatusMaxCapacity = @kIOPSMaxCapacityKey;
NSString *PowerStatusIsCharging = @kIOPSIsChargingKey;
NSString *PowerStatusIsCharged = @kIOPSIsChargedKey;

NSString *PowerStatusNotification = @"PowerStatus";
