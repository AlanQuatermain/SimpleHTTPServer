//
//  AQHTTPRequestOperation.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPRequestOperation.h"
#import "NSDateFormatter+AQHTTPDateFormatter.h"
#if TARGET_OS_IPHONE
# import <MobileCoreServices/MobileCoreServices.h>
#else
# import <CoreServices/CoreServices.h>
#endif
#import <CommonCrypto/CommonDigest.h>

static NSString * htmlErrorFormat = @"<!DOCTYPE html><html><head><title>%@</title></head><body><p>%@</p></body></html>";

@implementation AQHTTPRequestOperation
{
    AQSocket *_socketRef;
    NSString *_documentRoot;
    CFHTTPMessageRef _request;
    CFHTTPMessageRef _response;
    
    BOOL _responseSent;
}

@synthesize connection;

- (id) initWithRequest: (CFHTTPMessageRef) request socket: (AQSocket *) theSocket documentRoot: (NSURL *) documentRoot
{
    NSParameterAssert([documentRoot isFileURL]);
    
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _documentRoot = [[documentRoot path] copy];
#if USING_MRR
    _socketRef = [theSocket retain];
#else
    _socketRef = theSocket;
#endif
    _request = request;
    CFRetain(_request);
    
    _responseSent = NO;
    
    return ( self );
}

- (void) dealloc
{
    if ( _request != NULL )
        CFRelease(_request);
    if ( _response != NULL )
        CFRelease(_response);
#if USING_MRR
    [_documentRoot release];
    [_socketRef release];
    [super dealloc];
#endif
}

- (NSString *) etagForItemAtPath: (NSString *) path
{
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

- (BOOL) writeAll: (NSData *) inputData
{
    if ( _socketRef.status != AQSocketConnected )
        return ( NO );     // can't send the data-- return error state
    if ( [inputData length] == 0 )
        return ( YES );     // socket is OK, but we're going to return early to avoid a zero-byte send causing errors.
    
    // Copy this to a variable for the block to reference (so it doesn't keep 'data' alive).
    NSUInteger totalToSend = [inputData length];
    __block BOOL done = NO;
    
    // this will enqueue the write and will call the completion block once it's completed
    [_socketRef writeBytes: inputData completion: ^(NSData *unwritten, NSError *error) {
        if ( error != nil )
        {
            if ( [error.domain isEqualToString: NSPOSIXErrorDomain] && (error.code == EPIPE || error.code == ECONNRESET || error.code == ECANCELED) )
                return;     // we kind of expect this, since we're queueing a lot of these guys on a pipe which might go away via ECONNRESET
            
            NSLog(@"Error sending response headers: %@", error);
        }
        else
        {
            NSLog(@"Socket %@ wrote %lu bytes.", _socketRef, totalToSend);
        }
        
        done = YES;
    }];
    
    // wait for the write to complete
    @autoreleasepool {
        while ( !done )
        {
            [[NSRunLoop currentRunLoop] runMode: @"AQHTTPRequestWritingDataRunLoopMode" beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
        }
    }
    
    return ( YES );     // we successfully enqueued the write request
}

- (void) main
{
    NSInputStream * fileStream = nil;
    @try
    {
        // create the response
        // see if the requested item exists
        NSURL * requestURL = CFBridgingRelease(CFHTTPMessageCopyRequestURL(_request));
        NSString * path = [_documentRoot stringByAppendingPathComponent: [requestURL path]];
        
        NSString * method = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(_request));
        
        NSString * clientEtag = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(_request, CFSTR("If-None-Match")));
        NSString * myEtag = [self etagForItemAtPath: path];
        
        BOOL isDir = NO;
        
        if ( [[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDir] == NO )
        {
            // Resource Not Found
            _response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 404, NULL, kCFHTTPVersion1_1);
            
            NSString * html404 = [NSString stringWithFormat: htmlErrorFormat, @"File not found", @"The requested resource was not found on this server."];
            NSData * data = [html404 dataUsingEncoding: NSUTF8StringEncoding];
            NSString * len = [NSString stringWithFormat: @"%lu", [data length]];
            CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Content-Length"), (__bridge CFStringRef)len);
            CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Content-Type"), CFSTR("text/html; charset=utf-8"));
            CFHTTPMessageSetBody(_response, (__bridge CFDataRef)data);
        }
        else if ( isDir || [method caseInsensitiveCompare: @"DELETE"] == NSOrderedSame )
        {
            // Not Permitted
            _response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 403, NULL, kCFHTTPVersion1_1);
            NSString * html403 = [NSString stringWithFormat: htmlErrorFormat, @"Not Permitted", @"You do not have permission to perform a DELETE operation."];
            NSData * data = [html403 dataUsingEncoding: NSUTF8StringEncoding];
            NSString * len = [NSString stringWithFormat: @"%lu", [data length]];
            CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Content-Length"), (__bridge CFStringRef)len);
            CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Content-Type"), CFSTR("text/html; charset=utf-8"));
            CFHTTPMessageSetBody(_response, (__bridge CFDataRef)data);
        }
        else
        {
            if ( [clientEtag length] != 0 && [clientEtag length] == [myEtag length] )
            {
                // see if we should return a Not Modified status
                if ( [clientEtag isEqualToString: myEtag] )
                {
                    _response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 304, NULL, kCFHTTPVersion1_1);
                }
            }
            
            if ( _response == NULL )
            {
                // OK
                _response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
                if ( [method caseInsensitiveCompare: @"HEAD"] != NSOrderedSame )
                    fileStream = [[NSInputStream alloc] initWithFileAtPath: path];
            }
        }
        
        // we don't support keepalive
        CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Connection"), CFSTR("close"));
        CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Server"), CFSTR("AQHTTPServer/1.0"));
        
        // HTTP 1.1 requires that we return a valid date marker
        NSString * date = [[NSDateFormatter AQHTTPDateFormatter] stringFromDate: [NSDate date]];
        CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Date"), (__bridge CFStringRef)date);
        
        if ( fileStream != nil )
        {
            NSNumber * len = [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL] objectForKey: NSFileSize];
            CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Content-Length"), (__bridge CFStringRef)[len stringValue]);
            
            if ( myEtag != nil )
                CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Etag"), (__bridge CFStringRef)myEtag);
        }
        if ( fileStream != nil || [method caseInsensitiveCompare: @"HEAD"] == NSOrderedSame )
        {
            // determine the type
            CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[path pathExtension], NULL);
            NSString * contentType = nil;
            
            if ( uti != NULL )
            {
                contentType = CFBridgingRelease(UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType));
                //TODO : figure out the text encoding, if this is a text file, and include that using "; charset=[encoding]"
                
                CFRelease(uti);
            }
            
            if ( contentType == nil )
            {
                NSString * extension = [path pathExtension];
                if ( [extension isEqualToString: @"svg"] )
                {
                    contentType = @"image/svg+xml; charset=utf-8";
                }
                else if ( [extension isEqualToString: @"xhtml"] )
                {
                    contentType = @"application/xhtml+xml; charset=utf-8";
                }
                else if ( [extension isEqualToString: @"html"] )
                {
                    contentType = @"text/html; charset=utf-8";
                }
                else if ( [extension isEqualToString: @"js"] )
                {
                    contentType = @"application/javascript";
                }
                else if ( [extension isEqualToString: @"css"] )
                {
                    contentType = @"text/css";
                }
            }
            
            CFHTTPMessageSetHeaderFieldValue(_response, CFSTR("Content-Type"), (__bridge CFStringRef)contentType);
        }
        
        // TODO: handle ranged GET requests
        
        // send the response header
        NSData * responseData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(_response));
        if ( [self writeAll: responseData] == NO )
            return;     // socket closed
        
        NSString * msgStr = [[NSString alloc] initWithData: responseData encoding: NSUTF8StringEncoding];
        NSLog(@"Sent response header:\n%@", msgStr);
#if USING_MRR
        [msgStr release];
#endif
        
        // send the file data, if any
        if ( fileStream != nil )
        {
            [fileStream setDelegate: self];
            [fileStream scheduleInRunLoop: [NSRunLoop currentRunLoop] forMode: NSDefaultRunLoopMode];
            [fileStream open];
            
            while ( !_responseSent )
            {
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate distantFuture]];
                }
            }
        }
    }
    @catch (NSException * e)
    {
        // catch any exceptions-- specifically 'socket not connected', which could happen if the client closes the connection on us
        NSLog(@"Caught %@ while sending data: %@", [e name], [e reason]);
    }
    @finally
    {
        [fileStream setDelegate: nil];
        [fileStream close];
#if USING_MRR
        [fileStream release];
#endif
        // NB: though it might seem logical to close the connection at this point, our writes have only been *enqueued* so they might not have
        // actually taken place yet. Closing the connection now would prevent them from going through, so we leave it around until the socket
        // is closed by the other end.
    }
}

- (void) stream: (NSInputStream *) aStream handleEvent: (NSStreamEvent) eventCode
{
    switch ( eventCode )
    {
        case NSStreamEventErrorOccurred:
            NSLog(@"Error from file stream: %@", [aStream streamError]);
            // fall-through
        case NSStreamEventEndEncountered:
            _responseSent = YES;
            break;
            
        case NSStreamEventHasBytesAvailable:
        {
#define SBUFLEN 1024*8
            uint8_t buf[SBUFLEN];
            NSInteger len = [aStream read: buf maxLength: SBUFLEN];
            if ( len > 0 )
            {
                NSData * data = [NSData dataWithBytesNoCopy: buf length: len freeWhenDone: NO];
                if ( [self writeAll: data] == NO )
                {
                    // socket closed-- signal completion
                    _responseSent = YES;
                }
            }
            break;
        }
            
        default:
            break;
    }
}

@end
