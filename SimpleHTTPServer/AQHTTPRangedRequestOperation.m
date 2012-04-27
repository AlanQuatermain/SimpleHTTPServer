//
//  AQHTTPRangedRequestOperation.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-26.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPRangedRequestOperation.h"
#import "AQSocket.h"
#import "AQHTTPConnection.h"
#import "NSDateFormatter+AQHTTPDateFormatter.h"
#import <CommonCrypto/CommonDigest.h>
#import "DDRange.h"

@implementation AQHTTPRangedRequestOperation
{
    AQSocket *_socketRef;
    NSString *_documentRoot;
    CFHTTPMessageRef _request;
    
    NSArray * _ranges;
    NSMutableIndexSet * _orderedRanges;
    BOOL _isSingleRange;
    
    BOOL _responseSent;
}

@synthesize connection;

- (id) initWithRequest: (CFHTTPMessageRef) request socket: (id) theSocket documentRoot: (NSURL *) documentRoot ranges: (NSArray *) ranges
{
    NSParameterAssert([documentRoot isFileURL]);
    
    self = [super init];
    if ( self == nil )
        return ( nil );
    
#if USING_MRR
    _socketRef = [theSocket retain];
#else
    _socketRef = theSocket;
#endif
    
    _documentRoot = [[documentRoot path] copy];
    _ranges = [ranges copy];
    _request = request;
    CFRetain(_request);
    
    _responseSent = NO;
    
    _orderedRanges = [NSMutableIndexSet new];
    for ( NSValue * v in _ranges )
    {
        DDRange r = [v ddrangeValue];
        [_orderedRanges addIndexesInRange: NSRangeFromDDRange(r)];
    }
    
    if ( [_orderedRanges count] == ([_orderedRanges lastIndex]-[_orderedRanges firstIndex])+1 )
    {
        // it's a single range!
        _isSingleRange = YES;
    }
    
    return ( self );
}

- (void) dealloc
{
    if ( _request != NULL )
        CFRelease(_request);
#if USING_MRR
    [_documentRoot release];
    [_socketRef release];
    [_ranges release];
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
    
    // this will enqueue the write and will poll the completion block with updates until it's done
    [_socketRef writeBytes: inputData completion: ^(NSData *unwritten, NSError *error) {
        if ( error != nil )
        {
            if ( [error.domain isEqualToString: NSPOSIXErrorDomain] && (error.code == EPIPE || error.code == ECONNRESET || error.code == ECANCELED) )
                return;     // we kind of expect this, since we're queueing a lot of these guys on a pipe which might go away via ECONNRESET
            
            NSLog(@"Error sending response headers: %@", error);
        }
        else
        {
            NSLog(@"Socket %@: %lu bytes sent", _socketRef, [inputData length]);
        }
    }];
    
    return ( YES );     // we successfully enqueued the write request
}

- (NSString *) contentTypeForFileAtPath: (NSString *) path
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
            contentType = @"image/svg+xml";
        }
        else if ( [extension isEqualToString: @"xhtml"] )
        {
            contentType = @"application/xhtml+xml";
        }
        else if ( [extension isEqualToString: @"html"] )
        {
            contentType = @"text/html";
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
    
    return ( contentType );
}

- (void) main
{
    NSFileHandle * fileHandle = nil;
    @try
    {
        CFHTTPMessageRef response = NULL;
        NSString * multipartBoundary = nil;
        
        // see if the requested item exists
        NSURL * requestURL = CFBridgingRelease(CFHTTPMessageCopyRequestURL(_request));
        NSString * path = [_documentRoot stringByAppendingPathComponent: [requestURL path]];
        
        NSString * contentType = [self contentTypeForFileAtPath: path];
        if ( contentType == nil )
            contentType = @"application/octet-stream";
        
        NSString * method = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(_request));
        
        NSString * clientEtag = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(_request, CFSTR("If-None-Match")));
        NSString * myEtag = [self etagForItemAtPath: path];
        
        unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL] fileSize];
        
        BOOL isDir = NO;
        
        if ( [[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDir] == NO )
        {
            // Resource Not Found
            response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 404, NULL, kCFHTTPVersion1_1);
        }
        else if ( isDir || [method caseInsensitiveCompare: @"DELETE"] == NSOrderedSame )
        {
            // Not Permitted
            response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 403, NULL, kCFHTTPVersion1_1);
        }
        else if ( [_ranges count] == 0 || fileSize < [_orderedRanges lastIndex] )
        {
            // Requested Range Not Satisfiable
            response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 416, NULL, kCFHTTPVersion1_1);
        }
        else
        {
            if ( [clientEtag length] != 0 && [clientEtag length] == [myEtag length] )
            {
                // see if we should return a Not Modified status
                if ( [clientEtag isEqualToString: myEtag] )
                {
                    // Not Modified
                    response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 304, NULL, kCFHTTPVersion1_1);
                    CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (__bridge CFStringRef)contentType);
                }
            }
            
            NSString * sizeStr = [NSString stringWithFormat: @"%llu", fileSize];
            
            if ( response == NULL )
            {
                // Partial Content
                response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, NULL, kCFHTTPVersion1_1);
                if ( [method caseInsensitiveCompare: @"HEAD"] != NSOrderedSame )
                {
                    fileHandle = [NSFileHandle fileHandleForReadingAtPath: path];
                    if ( _isSingleRange == NO )
                    {
                        CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
                        multipartBoundary = [NSString stringWithFormat: @"AQHTTPServer-Multipart-Range-%@", CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid))];
                        CFRelease(uuid);
                        
                        NSString * multipartContentType = [NSString stringWithFormat: @"multipart/byteranges; boundary=%@", multipartBoundary];
                        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (__bridge CFStringRef)multipartContentType);
                    }
                    else
                    {
                        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (__bridge CFStringRef)contentType);
                        
                        // sending back data in a single range, so set the appropriate content-length and content-range headers
                        NSString * contentLengthStr = [NSString stringWithFormat: @"%lu", [_orderedRanges count]];
                        NSString * contentRangeStr = [NSString stringWithFormat: @"bytes %lu-%lu/%@", [_orderedRanges firstIndex], [_orderedRanges lastIndex], sizeStr];
                        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (__bridge CFStringRef)contentLengthStr);
                        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Range"), (__bridge CFStringRef)contentRangeStr);
                    }
                }
                else
                {
                    // send the regular content type
                    CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (__bridge CFStringRef)contentType);
                    // send the full content length
                    CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (__bridge CFStringRef)sizeStr);
                }
            }
        }
        
        // we don't support keepalive
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Connection"), CFSTR("close"));
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Server"), CFSTR("AQHTTPServer/1.0"));
        
        // HTTP 1.1 requires that we return a valid date marker
        NSString * date = [[NSDateFormatter AQHTTPDateFormatter] stringFromDate: [NSDate date]];
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Date"), (__bridge CFStringRef)date);
        
        // send the header first
        NSData * responseData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(response));
        if ( [self writeAll: responseData] == NO )
            return;     // socket closed
        
        NSString * msgStr = [[NSString alloc] initWithData: responseData encoding: NSUTF8StringEncoding];
        NSLog(@"Sent response header:\n%@", msgStr);
#if USING_MRR
        [msgStr release];
#endif
        
        if ( fileHandle == nil )
            return;     // no data following
        
        // bokay, let's do this thing
        if ( _isSingleRange )
        {
            // simple case, it just goes straight through
            DDRange r = DDMakeRange([_orderedRanges firstIndex], [_orderedRanges count]);
            [fileHandle seekToFileOffset: r.location];
            
            // we always return after this call, so we can ignore the result
            [self writeAll: [fileHandle readDataOfLength: r.length]];
            
            // done !
            return;
        }
        
        // otherwise, we need to send it out in multiple ranges, in the right order
        for ( NSValue * v in _ranges )
        {
            DDRange r = [v ddrangeValue];
            
            // build the header for this range
            NSMutableString * header = [NSMutableString stringWithString: @"--"];
            [header appendFormat: @"%@\n", multipartBoundary];
            [header appendFormat: @"Content-Type: %@\n", contentType];
            [header appendFormat: @"Content-Range: bytes %llu-%llu/%llu\n\n", r.location, DDMaxRange(r)-1, fileSize];
            
            // send this
            if ( [self writeAll: [header dataUsingEncoding: NSUTF8StringEncoding]] == NO )
                return;     // socket closed, can't write any more
            
            // now fetch & send the associated data
            [fileHandle seekToFileOffset: r.location];
            if ( [self writeAll: [fileHandle readDataOfLength: r.length]] == NO )
                return;     // socket closed, can't write any more
        }
        
        // now the trailer
        // we ignore the return value since we always return right after enqueueing this write
        [self writeAll: [[NSString stringWithFormat: @"--%@--", multipartBoundary] dataUsingEncoding: NSUTF8StringEncoding]];
        
        // done !
    }
    @catch (NSException * e)
    {
        // catch any exceptions-- specifically 'socket not connected', which could happen if the client closes the connection on us
        NSLog(@"Caught %@ while sending data: %@", [e name], [e reason]);
    }
    @finally
    {
        [fileHandle closeFile];
        // NB: though it might seem logical to close the connection at this point, our writes have only been *enqueued* so they might not have
        // actually taken place yet. Closing the connection now would prevent them from going through, so we leave it around until the socket
        // is closed by the other end.
    }
}

@end
