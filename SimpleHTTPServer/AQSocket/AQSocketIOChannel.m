//
//  AQSocketIOChannel.m
//  AQSocket
//
//  Created by Jim Dovey on 2012-04-24.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQSocketIOChannel.h"
#import "AQSocketReader+PrivateInternal.h"
#import "AQSocket.h"
#import <sys/ioctl.h>

@implementation _AQDispatchData

- (id) initWithDispatchData: (dispatch_data_t) ddata
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    // First off, ensure we have a contiguous range of bytes to deal with.
    _ddata = dispatch_data_create_map(ddata, &_buf, &_len);
    
    return ( self );
}

#if !DISPATCH_USES_ARC
- (void) dealloc
{
    if ( _ddata != NULL )
        dispatch_release(_ddata);
#if USING_MRR
    [super dealloc];
#endif
}
#endif

- (const void *) bytes
{
    return ( _buf );
}

- (NSUInteger) length
{
    return ( _len );
}

- (dispatch_data_t) _aq_getDispatchData
{
    return ( _ddata );
}

@end

#pragma mark -

@interface AQSocketDispatchIOChannel : AQSocketIOChannel
@end

@interface AQSocketLegacyIOChannel : AQSocketIOChannel
@end

@implementation AQSocketIOChannel

@synthesize readHandler=_readHandler;

+ (id) allocWithZone: (NSZone *) zone
{
    if ( [self class] == [AQSocketIOChannel class] )
    {
        if ( dispatch_io_read != NULL )
            return ( [AQSocketDispatchIOChannel allocWithZone: zone] );
        
        return ( [AQSocketLegacyIOChannel allocWithZone: zone] );
    }
    
    return ( [super allocWithZone: zone] );
}

- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _nativeSocket = nativeSocket;
    _cleanupHandler = [cleanupHandler copy];
    
    // Create a serial queue upon which all notification/completion blocks will run.
    _q = dispatch_queue_create("me.alanquatermain.AQSocketIOChannel", DISPATCH_QUEUE_SERIAL);
    
    // Point this serial queue at the high-priority global queue for speedy handling.
    dispatch_set_target_queue(_q, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    
    return ( self );
}

#if USING_MRR || DISPATCH_USES_ARC == 0
- (void) dealloc
{
#if DISPATCH_USES_ARC == 0
    dispatch_release(_q);
    _q = NULL;
#endif
#if USING_MRR
    // Note that we don't *run* the cleanup handler here-- it's up to subclasses to do that as is appropriate.
    [_cleanupHandler release];
    [_readHandler release];
    [super dealloc];
#endif
}
#endif

- (void) close
{
    [NSException raise: @"SubclassMustImplementException" format: @"Subclass of %@ is expected to implement %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
}

- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData *, NSError *)) completion
{
    [NSException raise: @"SubclassMustImplementException" format: @"Subclass of %@ is expected to implement %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
}

@end

@implementation AQSocketDispatchIOChannel
{
    dispatch_io_t _io;
}

- (void) dealloc
{
    [self close];
#if USING_MRR
    [super dealloc];
#endif
}

- (void) close
{
    if ( _io != NULL )
    {
        // swap out our _io variable so we don't get an invalid access should the cleanup handler called by dispatch_io_close() also call into here
        dispatch_io_t io = _io;
        _io = NULL;
        
        dispatch_io_close(io, DISPATCH_IO_STOP);
#if DISPATCH_USES_ARC == 0
        dispatch_release(io);
#endif
    }
}

- (void) setReadHandler: (void (^)(NSData *, NSError *)) inReadHandler
{
    [super setReadHandler: inReadHandler];
    [self close];
    
    if ( _readHandler == nil )
        return;
    
    _io = dispatch_io_create(DISPATCH_IO_STREAM, _nativeSocket, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int error) {
        if ( error != 0 )
            NSLog(@"Error in dispatch IO channel causing its shutdown: %d", error);
        _cleanupHandler();
    });
    
    // we want to return any time *any* bytes are read...
    // similarly we do NOT want output data to be held back if it's smaller than a certain amount
    dispatch_io_set_low_water(_io, 1);
    
    // install the read callback
    dispatch_io_read(_io, 0, SIZE_MAX, _q, ^(bool done, dispatch_data_t data, int error) {
        NSLog(@"dispatch read for %@: %lu bytes, error %d", self, (data == NULL ? 0ul : dispatch_data_get_size(data)), error);
        if ( _readHandler == nil )
            return;
        
        NSError * nsError = nil;
        if ( error != 0 )
            nsError = [[NSError alloc] initWithDomain: NSPOSIXErrorDomain code: error userInfo: nil];
        
        NSData * nsData = nil;
        if ( data != NULL )
            nsData = [[_AQDispatchData alloc] initWithDispatchData: data];
        
        if ( done || (data != NULL && dispatch_data_get_size(data) != 0) )
            _readHandler(nsData, nsError);
        
#if USING_MRR
        [nsError release];
        [nsData release];
#endif
    });
}

- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData *, NSError *)) completionHandler
{
    // Ensure that the completion handler block is on the heap, not the stack
    void (^completionCopy)(NSData *, NSError *) = [completionHandler copy];
    
    if ( _io == NULL )
    {
        if ( completionCopy == nil )
            return;
        
        dispatch_async(_q, ^{
            NSDictionary * userInfo = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"IO channel is no longer connected", @"IO channel error"), NSLocalizedFailureReasonErrorKey, nil];
            NSError * error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorNetworkConnectionLost userInfo: userInfo];
#if USING_MRR
            [userInfo release];
#endif
            completionCopy(nil, error);
        });
        
        return;
    }
    
    // This copy call ensures we have an immutable data object. If we were
    // passed an immutable NSData, the copy is actually only a retain.
    // We convert it to a CFDataRef in order to get manual reference counting
    // semantics in order to keep the data object alive until the dispatch_data_t
    // in which we're using it is itself released.
    NSData * copiedData = [data copy];
    CFDataRef staticData = CFBridgingRetain(copiedData);
    
    dispatch_data_t ddata = dispatch_data_create(CFDataGetBytePtr(staticData), CFDataGetLength(staticData), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // When the dispatch data object is deallocated, release our CFData ref.
        CFRelease(staticData);
    });
    
#if USING_MRR
    // In manual retain/release mode, the call to [data copy] returns +1, and the CFBridgingRetain() returns +1. The block above
    // releases the reference from CFBridgingRetain(), so we need to perform another release to match the [data copy] call.
    [copiedData release];
#endif
    
    dispatch_io_write(_io, 0, ddata, _q, ^(_Bool done, dispatch_data_t data, int error) {
        if ( completionCopy == nil )
            return;     // no point going further, really
        
        NSError * nsError = nil;
        if ( error != 0 && error != EAGAIN )
            nsError = [NSError errorWithDomain: NSPOSIXErrorDomain code: error userInfo: nil];
        
        if ( done )
        {
            // All the data was written successfully.
            completionCopy(nil, nsError);
            return;
        }
        
        // the handler will be re-enqueued with the remaining data at this point
        
        /*
        // Here we are once again relying upon CFErrorRef's magical 'fill in
        // the POSIX error userInfo' functionality.
        NSError * errObj = [NSError errorWithDomain: NSPOSIXErrorDomain code: error userInfo: nil];
        
        NSData * unwritten = nil;
        if ( data != NULL )
            unwritten = [[_AQDispatchData alloc] initWithDispatchData: data];
        
        completionCopy(unwritten, errObj);
#if USING_MRR
        [unwritten release];
#endif
         */
    });
    
#if DISPATCH_USES_ARC == 0
    //dispatch_release(ddata);
#endif
    
#if USING_MRR
    // This has been captured by the block now, so we can release it.
    [completionCopy release];
#endif
}

@end

#pragma mark -

@implementation AQSocketLegacyIOChannel
{
    dispatch_source_t _readerSource;
}

- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler
{
    self = [super initWithNativeSocket: nativeSocket cleanupHandler: cleanupHandler];
    if ( self == nil )
        return ( nil );
    
    _readerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _nativeSocket, 0, _q);
    // leave it suspended until we get a read handler installed
    
    return ( self );
}

- (void) dealloc
{
    if ( _readerSource != NULL )
    {
        dispatch_source_cancel(_readerSource);
#if DISPATCH_USES_ARC == 0
        dispatch_release(_readerSource);
#endif
        _readerSource = NULL;
    }
#if USING_MRR
    [super dealloc];
#endif
}

- (void) close
{
    if ( _readHandler != NULL )
    {
        // this runs the cleanup handler, if any
        dispatch_source_cancel(_readerSource);
#if DISPATCH_USES_ARC == 0
        dispatch_release(_readerSource);
#endif
        _readerSource = NULL;
    }
}

- (void) setReadHandler: (void (^)(NSData *, NSError *)) readHandler
{
    // Always suspend the reader source before swapping out an existing handler.
    // This also has the effect of mirroring the dispatch_resume() call after installing the event/cancel handlers.
    if ( _readHandler != nil )
        dispatch_suspend(_readerSource);
    
    [super setReadHandler: readHandler];
    if ( _readHandler == nil )
        return;
    
    if ( _readerSource == NULL )
        return;
    
    dispatch_source_set_cancel_handler(_readerSource, ^{
        if ( _cleanupHandler != nil )
            _cleanupHandler();
    });
    
    dispatch_source_set_event_handler(_readerSource, ^{
        // read as much data as possible
        int flags = fcntl(_nativeSocket, F_GETFL, 0);
        BOOL isNonBlocking = ((flags & O_NONBLOCK) == O_NONBLOCK);
        if ( !isNonBlocking )
        {
            // make it use nonblocking IO so we can receive zero-length data
            flags |= O_NONBLOCK;
            fcntl(_nativeSocket, F_SETFL, flags);
        }
        
        NSMutableData * data = [NSMutableData new];
        NSError * error = nil;
        
#define READ_BUFLEN 1024*8
        uint8_t buf[READ_BUFLEN];
        ssize_t nread = 0;
        while ( (nread = recv(_nativeSocket, buf, READ_BUFLEN, 0)) > 0 )
        {
            [data appendBytes:buf length:nread];
        }
        
        if ( nread < 0 )
        {
            // don't send errors for EAGAIN-- we just finished reading data is all, it's not an error that needs handling further up the chain
            int err = errno;
            if ( err != EAGAIN )
                error = [[NSError alloc] initWithDomain: NSPOSIXErrorDomain code: err userInfo: nil];
        }
        
        _readHandler(data, error);
        
#if USING_MRR
        [data release];
        [error release];
#endif
        
        // reset to blocking mode if appropriate
        if ( !isNonBlocking )
        {
            flags &= ~O_NONBLOCK;
            fcntl(_nativeSocket, F_SETFL, flags);
        }
    });
    
    dispatch_resume(_readerSource);
}

- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData *, NSError *)) completion
{
    // Ensure the completion block is on the heap, not the stack.
    void (^completionCopy)(NSData *, NSError *) = [completion copy];
    
    // Run the write operation in the background. We use our serial queue to avoid spawning 1001 threads blocking on select().
    dispatch_async(_q, ^{
        ssize_t totalSent = 0;
        const uint8_t *p = [data bytes];
        size_t len = [data length];
        
        while (totalSent < [data length])
        {
            ssize_t numSent = send(_nativeSocket, p, len, 0);
            int err = errno;
            if ( numSent < 0 && err != EAGAIN )
            {
                NSError * error = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
                dispatch_async(_q, ^{
                    completionCopy([data subdataWithRange: NSMakeRange(totalSent, len)], error);
                });
                break;
            }
            else
            {
                if ( numSent >= 0 )
                {
                    totalSent += numSent;
                    len -= numSent;
                }
                
                if ( totalSent == [data length] )
                {
                    // all done, no errors
                    dispatch_async(_q, ^{
                        completionCopy(nil, nil);
                    });
                }
                else        // sent partial data-- block until we receive more
                {
                    fd_set wfds, efds;
                    FD_ZERO(&wfds);
                    FD_ZERO(&efds);
                    FD_SET(_nativeSocket, &wfds);
                    FD_SET(_nativeSocket, &efds);
                    
                    if ( select(_nativeSocket+1, NULL, &wfds, &efds, NULL) < 0 )
                    {
                        // an error occurred.
                        NSError * error = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
                        dispatch_async(_q, ^{
                            completionCopy([data subdataWithRange: NSMakeRange(totalSent, len)], error);
                        });
                        
                        break;
                    }
                    
                    if ( FD_ISSET(_nativeSocket, &wfds) )
                        continue;       // room available to write, so let's use it
                    
                    if ( FD_ISSET(_nativeSocket, &efds) )
                    {
                        // an error occurred.
                        int sockerr = 0;
                        socklen_t slen = sizeof(int);
                        getsockopt(_nativeSocket, SOL_SOCKET, SO_ERROR, &sockerr, &slen);
                        
                        NSError * error = [NSError errorWithDomain: NSPOSIXErrorDomain code: sockerr userInfo: nil];
                        dispatch_async(_q, ^{
                            completionCopy([data subdataWithRange: NSMakeRange(totalSent, len)], error);
                        });
                        
                        break;
                    }
                }
            }
        }
    });
    
#if USING_MRR
    // This has been captured by the block now, so we can release it.
    [completionCopy release];
#endif
}

@end
