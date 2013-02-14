//
//  AQHTTPResponseOperation.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 2012-04-28.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPResponseOperation.h"
#import "NSDateFormatter+AQHTTPDateFormatter.h"
#import <sys/stat.h>

// for UTTypes API
#if TARGET_OS_IPHONE
# import <MobileCoreServices/MobileCoreServices.h>
#else
# import <CoreServices/CoreServices.h>
#endif

static NSString * const htmlErrorFormat = @"<!DOCTYPE html><html><head><title>%@</title></head><body><p>%@</p></body></html>";
static NSString * const AQHTTPResponseRunLoopMode = @"AQHTTPResponseRunLoopMode";

@implementation AQHTTPResponseOperation

- (id) initWithRequest: (CFHTTPMessageRef) request
                socket: (AQSocket *) aSocket
                ranges: (NSArray *) ranges
         forConnection: (AQHTTPConnection *) connection
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _request = request;
    CFRetain(_request);
    
#if USING_MRR
    _socketRef = [aSocket retain];
    _connection = [connection retain];
#else
    _socketRef = aSocket;
    _connection = connection;
#endif
    
    _ranges = [ranges copy];
    if ( _ranges != nil )
    {
        _orderedRanges = [NSMutableIndexSet new];
        for ( NSValue * v in _ranges )
        {
            DDRange r = [v ddrangeValue];
            [_orderedRanges addIndexesInRange: NSRangeFromDDRange(r)];
        }
        
        // is it a single range?
        if ( [_orderedRanges count] == ([_orderedRanges lastIndex]-[_orderedRanges firstIndex])+1 )
        {
            _isSingleRange = YES;
        }
    }
    
    return ( self );
}

- (void) dealloc
{
    if ( _request != NULL )
        CFRelease(_request);
#if USING_MRR
    [_socketRef release];
    [_connection release];
    [_ranges release];
    [_orderedRanges release];
    [_rangeBoundary release];
    [_contentType release];
    [super dealloc];
#endif
}

- (NSString *) rangeHeaderForRange: (DDRange) range fileSize: (UInt64) fileSize
                       contentType: (NSString *) contentType boundary: (NSString *) boundary
{
    NSMutableString * header = [NSMutableString stringWithString: @"--"];
    [header appendFormat: @"%@\n", boundary];
    [header appendFormat: @"Content-Type: %@\n", contentType];
    [header appendFormat: @"Content-Range: bytes %llu-%llu/%llu\n\n", range.location, DDMaxRange(range)-1, fileSize];
#if USING_MRR
    return ( [[header copy] autorelease] );
#else
    return ( [header copy] );
#endif
}

- (void) main
{
    // outside the @try block so we can ensure they're released in @finally.
    CFHTTPMessageRef response = NULL;
    NSInputStream * stream = nil;
    id<AQRandomAccessFile> file = nil;
    
    BOOL forceCloseConnection = !_connection.supportsPipelinedRequests;
    
    @try
    {
        NSURL * requestURL = CFBridgingRelease(CFHTTPMessageCopyRequestURL(_request));
        NSString * path = [[requestURL path] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
        NSString * method = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(_request));
        
        if ( [[path pathExtension] isEqualToString: @"ttf"] )
            NSLog(@"Loading TTF font");
        
        NSString * multipartBoundary = nil;
        
        UInt64 fileSize = [self sizeOfItemAtPath: path];
        NSString * sizeStr = nil;
        if ( fileSize != (UInt64)-1 )
        {
            sizeStr = [NSString stringWithFormat: @"%llu", fileSize];
        }
        
        // determine if the item is accessible
        // also build a response early, so we can check for Not Modified status before creating streams etc.
        response = [self newResponseForItemAtPath: path withHTTPStatus: [self statusCodeForItemAtPath: path]];
        if ( response == NULL )
        {
            NSLog(@"Error: no response returned from -newResponseForItemAtPath:withHTTPStatus:!");
            return;     // AAARGH!
        }
        
        // check the status from 
        NSUInteger status = CFHTTPMessageGetResponseStatusCode(response);
        if ( status == 200 || status == 206 )
        {
            // we might want to override this with a 500 error if no
            // input stream or file accessor is forthcoming
            
            // no stream if we're using ranges
            if ( _ranges == nil )
                stream = [self inputStreamForItemAtPath: path];
            
            // no stream available, or it's a ranged request
            if ( stream == nil )
                file = [self randomAccessFileForItemAtPath: path];
            
            // no random-access file available for a ranged request-- fall back to the stream
            if ( file == nil && _ranges != nil )
                stream = [self inputStreamForItemAtPath: path];
            
            if ( stream == nil && file == nil && [method isEqualToString: @"GET"] )
            {
                // no means to read from the file, but OK? erm...
                status = 500;
            }
        }
        
        if ( CFHTTPMessageGetResponseStatusCode(response) == 206 )
        {
            if ( _isSingleRange == NO )
            {
                // setup the multipart content type & boundary
                CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
                multipartBoundary = [NSString stringWithFormat: @"AQHTTPServer-Multipart-Range-%@", CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid))];
                CFRelease(uuid);
                
                NSString * multipartContentType = [NSString stringWithFormat: @"multipart/byteranges; boundary=%@", multipartBoundary];
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (__bridge CFStringRef)multipartContentType);
            }
            else
            {
                // sending back data in a single range, so set the appropriate content-length and content-range headers
                NSString * contentLengthStr = [NSString stringWithFormat: @"%lu", (unsigned long)[_orderedRanges count]];
                NSString * contentRangeStr = [NSString stringWithFormat: @"bytes %lu-%lu/%@", (unsigned long)[_orderedRanges firstIndex], (unsigned long)[_orderedRanges lastIndex], sizeStr];
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (__bridge CFStringRef)contentLengthStr);
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Range"), (__bridge CFStringRef)contentRangeStr);
            }
        }
        else if ( stream != nil || file != nil )
        {
            // if there's valid data to follow, set the content length
            CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (__bridge CFStringRef)sizeStr);
        }
        
        // send the header
        NSData * data = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(response));
        if ( data == nil )
        {
            NSLog(@"Error: response has no serialized data to send!");
            return;
        }
        
#if DEBUGLOG
        NSString * debugStr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
        NSLog(@"Connection %@ sending response for URL %@: %@", _connection, requestURL, debugStr);
#if USING_MRR
        [debugStr release];
#endif
#endif
        
        if ( [self writeAll: data] == NO )
        {
            // socket closed before we could completely send the header
            return;
        }
        
        if ( [method caseInsensitiveCompare: @"HEAD"] == NSOrderedSame )
        {
            // only sending the headers, so we return now
            _responseComplete = YES;
            return;
        }
        
        if ( stream != nil )
        {
            // ranged request handling is done in the stream delegation method
            if ( _ranges != nil )
            {
                _rangeBoundary = [multipartBoundary copy];
                _contentType = [[self contentTypeForItemAtPath: path] copy];
                _fileSize = fileSize;
                
                // when streaming, we have to send ranges in ascending order, so ensure our list is sorted
                NSArray * sorted = [_ranges sortedArrayUsingComparator: ^NSComparisonResult(id obj1, id obj2) {
                    DDRange r1 = [obj1 ddrangeValue];
                    DDRange r2 = [obj2 ddrangeValue];
                    return ( DDRangeCompare(&r1, &r2) );
                }];
#if USING_MRR
                [_ranges release];
                _ranges = [sorted retain];
#else
                _ranges = sorted;
#endif
                _currentRangeIndex = 0;
                _currentStreamOffset = 0ull;
            }
            
            [stream setDelegate: self];
            [stream scheduleInRunLoop: [NSRunLoop currentRunLoop]
                              forMode: AQHTTPResponseRunLoopMode];
            
            [stream open];
            
            // wait for it to finish sending
            @autoreleasepool {
                while (!_responseComplete)
                {
                    [[NSRunLoop currentRunLoop] runMode: AQHTTPResponseRunLoopMode
                                             beforeDate: [NSDate dateWithTimeIntervalSinceNow:1.0]];
                }
            }
        }
        else if ( file != nil )
        {
            DDRange responseRange = {NSNotFound, 0};
            
            if ( _ranges == nil )
            {
                // reading the entire thing
                responseRange = DDMakeRange(0, file.length);
            }
            else if ( _isSingleRange )
            {
                responseRange = DDMakeRange([_orderedRanges firstIndex], [_orderedRanges count]);
            }
            
            if ( responseRange.location != NSNotFound )
            {
                // single range, one way or another
                NSData * data = [file readDataFromByteRange: responseRange];
                if ( data == nil )
                {
                    NSLog(@"Error reading data!");
                    // ensure the connection is closed, to stop the other end from just timing out
                    forceCloseConnection = YES;
                    return;
                }
                
                [self writeAll: data];
                
                // whether that worked or not, we're done!
                return;
            }
            
            // otherwise, we need to send it out in multiple ranges, in the right order
            NSString * contentType = [self contentTypeForItemAtPath: path];
            for ( NSValue * v in _ranges )
            {
                DDRange r = [v ddrangeValue];
                
                // build the header for this range
                NSString * header = [self rangeHeaderForRange: r fileSize: fileSize contentType: contentType boundary: multipartBoundary];
                
                // send this
                if ( [self writeAll: [header dataUsingEncoding: NSUTF8StringEncoding]] == NO )
                    return;     // socket closed, can't write any more
                
                // now fetch & send the associated data
                if ( [self writeAll: [file readDataFromByteRange: r]] == NO )
                    return;     // socket closed, can't write any more
            }
            
            // now the trailer
            // we ignore the return value since we always return right after enqueueing this write
            [self writeAll: [[NSString stringWithFormat: @"--%@--", multipartBoundary] dataUsingEncoding: NSUTF8StringEncoding]];
            
            // done !
        }
    }
    @catch (NSException * e)
    {
        NSLog(@"AQHTTPResponseOperation: Caught %@ during -main-- %@", [e name], [e reason]);
    }
    @finally
    {
        [stream removeFromRunLoop: [NSRunLoop currentRunLoop] forMode: AQHTTPResponseRunLoopMode];
        [stream setDelegate: nil];
        [stream close];
        
        // NB: stream and file are autoreleased variables
        
        if ( forceCloseConnection )
        {
            [_connection close];
        }
        else
        {
            NSString * connStatus = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(response, CFSTR("Connection")));
            if ( [connStatus caseInsensitiveCompare: @"close"] == NSOrderedSame )
            {
                // a close was requested
                [_connection close];
            }
        }
        
        CFRelease(response);
    }
}

- (void) _inputStream: (NSInputStream *) stream receivedData: (NSData *) data range: (DDRange) receivedRange
{
    if ( [_ranges count] == 0 )
    {
        // just send all data
        if ( [self writeAll: data] == NO )
        {
            // socket failure-- stop streaming
            _responseComplete = YES;
        }
        
        return;
    }
    
    if ( _currentRangeIndex >= [_ranges count] )
    {
        _responseComplete = YES;
        return;
    }
    
    DDRange r = [[_ranges objectAtIndex: _currentRangeIndex] ddrangeValue];
    DDRange intersection = DDIntersectionRange(r, receivedRange);
    if ( intersection.length == 0ull )
        return;         // received data isn't in a range we want to send
    
    // is this the start of a new range block?
    if ( receivedRange.location >= r.location )
    {
        // yes, it's the start -- do we need to send a multipart header?
        if ( _isSingleRange == NO )
        {
            // multipart header goes out
            NSString * header = [self rangeHeaderForRange: r fileSize: _fileSize contentType: _contentType boundary: _rangeBoundary];
            if ( [self writeAll: [header dataUsingEncoding: NSUTF8StringEncoding]] == NO )
            {
                // socket failure-- stop waiting & close the stream
                _responseComplete = YES;
                return;
            }
        }
    }
    
    // determine the subrange of the received data which intersects with the current range
    // reset the intersection range to be relative to the bytes in 'data'
    intersection.location -= receivedRange.location;
    NSData * rangeData = [data subdataWithRange: NSRangeFromDDRange(intersection)];
    
    // write this data
    if ( [self writeAll: rangeData] == NO )
    {
        // socket failure-- stop streaming
        _responseComplete = YES;
        return;
    }
    
    // now, do we need to advance to the next range?
    if ( DDMaxRange(receivedRange) >= DDMaxRange(r) )
    {
        // yep, we fulfilled this range request
        _currentRangeIndex++;
        
        // maybe this was the last range?
        if ( _currentRangeIndex >= [_ranges count] )
        {
            // send the trailing boundary
            // we ignore the return value since we always return right after enqueueing this write
            [self writeAll: [[NSString stringWithFormat: @"--%@--", _rangeBoundary] dataUsingEncoding: NSUTF8StringEncoding]];
            
            // all done!
            _responseComplete = YES;
        }
    }
}

#pragma mark - NSStreamDelegate Protocol

- (void) stream: (NSInputStream *) aStream handleEvent: (NSStreamEvent) eventCode
{
    switch ( eventCode )
    {
        case NSStreamEventErrorOccurred:
            NSLog(@"Error from file stream: %@", [aStream streamError]);
            // fall-through
        case NSStreamEventEndEncountered:
            _responseComplete = YES;
            break;
            
        case NSStreamEventHasBytesAvailable:
        {
            if ( _responseComplete )
                break;
            
#define SBUFLEN 1024*8
            uint8_t buf[SBUFLEN];
            NSInteger len = [aStream read: buf maxLength: SBUFLEN];
            if ( len > 0 )
            {
                NSData * data = [NSData dataWithBytesNoCopy: buf length: len freeWhenDone: NO];
                DDRange range = DDMakeRange(_currentStreamOffset, len);
                [self _inputStream: aStream receivedData: data range: range];
                
                // increment our counter of bytes passed
                _currentStreamOffset += len;
            }
            break;
        }
            
        default:
            break;
    }
}

@end

#pragma mark -

@implementation AQHTTPResponseOperation (SubclassUsableMethods)

- (BOOL) writeAll: (NSData *) inputData
{
    if ( _socketRef.status != AQSocketConnected )
        return ( NO );     // can't send the data-- return error state
    if ( [inputData length] == 0 )
        return ( YES );     // socket is OK, but we're going to return early to avoid a zero-byte send causing errors.
    
    __block BOOL done = NO;
    __block BOOL errorOccurred = NO;
    
#if DEBUGLOG
    NSUInteger totalToSend = [inputData length];
    NSLog(@"Sending %lu bytes for request URL %@", (unsigned long)totalToSend, CFBridgingRelease(CFHTTPMessageCopyRequestURL(_request)));
#endif
    
    // this will enqueue the write and will call the completion block once it's completed
    [_socketRef writeBytes: inputData completion: ^(NSData *unwritten, NSError *error) {
        if ( error != nil )
        {
            if ( [error.domain isEqualToString: NSPOSIXErrorDomain] && (error.code == EPIPE || error.code == ECONNRESET || error.code == ECANCELED) )
            {
                done = YES;
                errorOccurred = YES;
                return;     // we kind of expect this, since we're queueing a lot of these guys on a pipe which might go away via ECONNRESET
            }
#if DEBUGLOG
            NSLog(@"Error sending response headers for request URL %@: %@", CFBridgingRelease(CFHTTPMessageCopyRequestURL(_request)), error);
#endif
        }
#if DEBUGLOG
        else
        {
            NSLog(@"Socket %@ wrote %u bytes for request URL %@.", _socketRef, totalToSend, CFBridgingRelease(CFHTTPMessageCopyRequestURL(_request)));
        }
#endif
        done = YES;
    }];
    
    // wait for the write to complete
    @autoreleasepool {
        while ( !done )
        {
            [[NSRunLoop currentRunLoop] runMode: @"AQHTTPRequestWritingDataRunLoopMode" beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
        }
    }
    
    if ( errorOccurred )
        return ( NO );      // socket shut down
    
    return ( YES );     // we successfully enqueued the write request
}

- (NSString *) contentTypeForItemAtPath: (NSString *) path
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
        else
        {
            contentType = @"application/octet-stream";
        }
    }
    
    return ( contentType );
}

- (CFHTTPMessageRef) newResponseForItemAtPath: (NSString *) path
                               withHTTPStatus: (NSUInteger) status
{
    CFHTTPMessageRef response = NULL;
    
    NSData * htmlBodyData = nil;
    NSString * contentType = [self contentTypeForItemAtPath: path];
    NSString * myEtag = [self etagForItemAtPath: path];
    
    if ( status >= 400 )
    {
        NSString * title = [NSHTTPURLResponse localizedStringForStatusCode: status];
        NSString * content = NSLocalizedString(@"The operation could not be completed.", @"Generic HTTP HTML error message");
        switch ( status )
        {
            case 403:
                content = NSLocalizedString(@"You do not have permission to access the requested resource.", @"HTTP 403 HTML error message");
                break;
            case 404:
                content = NSLocalizedString(@"The requested resource could not be found.", @"HTTP 404 HTML error message");
                break;
            default:
                break;
        }
        
        htmlBodyData = [[NSString stringWithFormat: htmlErrorFormat, title, content] dataUsingEncoding: NSUTF8StringEncoding];
    }
    
    if ( status >= 400 )
    {
        response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, status, NULL, kCFHTTPVersion1_1);
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (__bridge CFStringRef)[NSString stringWithFormat:@"%u", (unsigned)[htmlBodyData length]]);
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), CFSTR("text/html; charset=utf-8"));
        CFHTTPMessageSetBody(response, (__bridge CFDataRef)htmlBodyData);
    }
    else if ( status == 200 && [myEtag length] != 0 )
    {
        // check for a matching Etag in the request
        NSString * clientEtag = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(_request, CFSTR("If-None-Match")));
        if ( [clientEtag isEqualToString: myEtag] )
        {
            // 304 Not Modified
            response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 304, NULL, kCFHTTPVersion1_1);
        }
    }
    
    if ( response == NULL && _ranges != nil && _isSingleRange == NO )
    {
        // overridden status: 206 Partial Content
        // the content-type will be set in the -main method
        response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, NULL, kCFHTTPVersion1_1);
    }
    
    if ( response == NULL )
    {
        // generic response
        response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, status, NULL, kCFHTTPVersion1_1);
    }
    
    CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Server"), CFSTR("AQHTTPServer/1.0"));
    
    // HTTP 1.1 requires that we return a valid date marker
    NSString * date = [[NSDateFormatter AQHTTPDateFormatter] stringFromDate: [NSDate date]];
    CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Date"), (__bridge CFStringRef)date);
    
    if ( htmlBodyData == nil )
    {
        if ( contentType == nil )
            contentType = @"application/octet-stream";  // 'bytes'
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (__bridge CFStringRef)contentType);
    }
    
    if ( myEtag != nil )
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Etag"), (__bridge CFStringRef)myEtag);
    
    // if keepalive isn't supported, we'll insist upon a close
    if ( _connection.supportsPipelinedRequests == NO )
    {
        CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Connection"), CFSTR("close"));
    }
    else
    {
        // otherwise we'll return the input value, if any
        CFStringRef str = CFHTTPMessageCopyHeaderFieldValue(_request, CFSTR("Connection"));
        if ( str != NULL )
        {
            CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Connection"), str);
            CFRelease(str);
        }
    }
    
    // the method name begins with 'new' so we're expected to return +1 reference
    return ( response );
}

@end

@implementation AQHTTPResponseOperation (SubclassOverriddenMethods)

- (NSUInteger) statusCodeForItemAtPath: (NSString *) rootRelativePath
{
    return ( 200 );
}

- (UInt64) sizeOfItemAtPath: (NSString *) rootRelativePath
{
    return ( (UInt64)-1 );
}

- (NSString *) etagForItemAtPath: (NSString *) rootRelativePath
{
    return ( nil );
}

- (NSInputStream *) inputStreamForItemAtPath: (NSString *) rootRelativePath
{
    return ( nil );
}

- (id<AQRandomAccessFile>) randomAccessFileForItemAtPath: (NSString *) rootRelativePath
{
    return ( nil );
}

@end

@implementation NSFileHandle (AQRandomAccessFileIsSupported)

- (UInt64) length
{
    int fd = [self fileDescriptor];
    if ( fd == -1 )
    {
        [NSException raise: NSInternalInconsistencyException format: @"File handle %@ does not support obtaining its length!", self];
    }
    
    struct stat statBuf;
    if ( fstat(fd, &statBuf) == -1 )
    {
        [NSException raise: NSInternalInconsistencyException format: @"File handle %@ does not support obtaining its length!", self];
    }
    
    return ( statBuf.st_size );
}

- (NSData *) readDataFromByteRange: (DDRange) range
{
    // Q: are there multithreading issues between these two calls?
    [self seekToFileOffset: range.location];
    return ( [self readDataOfLength: range.length] );
}

@end
