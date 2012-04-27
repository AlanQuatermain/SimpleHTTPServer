//
//  NSDateFormatter+AQHTTPDateFormatter.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-26.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "NSDateFormatter+AQHTTPDateFormatter.h"

@implementation NSDateFormatter (AQHTTPDateFormatter)

+ (NSDateFormatter *) AQHTTPDateFormatter
{
    static NSDateFormatter * __obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __obj = [NSDateFormatter new];
        [__obj setDateFormat: @"E, dd MMM YYYY HH:mm:ss zzz"];
        [__obj setTimeZone: [NSTimeZone timeZoneForSecondsFromGMT: 0]];
    });
    return ( __obj );
}

@end
