//
//  AQHTTPRequestOperation.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPFileResponseOperation.h"
#import "NSDateFormatter+AQHTTPDateFormatter.h"
#if TARGET_OS_IPHONE
# import <MobileCoreServices/MobileCoreServices.h>
#else
# import <CoreServices/CoreServices.h>
#endif
#import <CommonCrypto/CommonDigest.h>

static NSString * htmlErrorFormat = @"<!DOCTYPE html><html><head><title>%@</title></head><body><p>%@</p></body></html>";

@implementation AQHTTPFileResponseOperation

- (NSUInteger) statusCodeForItemAtPath: (NSString *) rootRelativePath
{
    NSString * path = [[[_connection.documentRoot URLByAppendingPathComponent: rootRelativePath] absoluteURL] path];
    NSString * method = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(_request));
    BOOL isDir = NO;
    
    if ( [[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDir] == NO )
    {
        // Resource Not Found
        return ( 404 );
    }
    else if ( isDir || [method caseInsensitiveCompare: @"DELETE"] == NSOrderedSame )
    {
        // Not Permitted
        return ( 403 );
    }
    else if ( _ranges != nil )
    {
        return ( 206 );
    }
    
    return ( 200 );
}

- (UInt64) sizeOfItemAtPath: (NSString *) rootRelativePath
{
    NSString * path = [[[_connection.documentRoot URLByAppendingPathComponent: rootRelativePath] absoluteURL] path];
    
    NSDictionary * attrs = [[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL];
    if ( attrs == nil )
        return ( (UInt64)-1 );
    
    return ( [attrs fileSize] );
}

- (NSString *) etagForItemAtPath: (NSString *) path
{
    path = [[[_connection.documentRoot URLByAppendingPathComponent: path] absoluteURL] path];
    NSDictionary * dict = [[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL];
    if ( dict == nil )
        return ( nil );
    
    NSData * plist = [NSPropertyListSerialization dataWithPropertyList: dict format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
    if ( plist == nil )
        return ( nil );
    
    // SHA-1 hash it
    uint8_t md[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([plist bytes], (CC_LONG)[plist length], md);
    
    // convert to a string
    char str[CC_SHA1_DIGEST_LENGTH*2+1];
    str[CC_SHA1_DIGEST_LENGTH] = '\0';
    for ( int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++ )
    {
        sprintf(&str[i*2], "%02x", md[i]);
    }
    
    return ( [NSString stringWithUTF8String: str] );
}

- (NSInputStream *) inputStreamForItemAtPath: (NSString *) rootRelativePath
{
    return ( [NSInputStream inputStreamWithURL: [_connection.documentRoot URLByAppendingPathComponent: rootRelativePath]] );
}

- (id<AQRandomAccessFile>) randomAccessFileForItemAtPath: (NSString *) rootRelativePath
{
    return ( [NSFileHandle fileHandleForReadingFromURL: [_connection.documentRoot URLByAppendingPathComponent: rootRelativePath] error: NULL] );
}

@end
