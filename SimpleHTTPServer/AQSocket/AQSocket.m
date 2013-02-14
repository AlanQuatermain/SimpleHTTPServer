//
//  AQSocket.m
//  AQSocket
//
//  Created by Jim Dovey on 11-12-16.
//  Copyright (c) 2011 Jim Dovey. All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//  
//  Redistributions of source code must retain the above copyright notice,
//  this list of conditions and the following disclaimer.
//  
//  Redistributions in binary form must reproduce the above copyright
//  notice, this list of conditions and the following disclaimer in the
//  documentation and/or other materials provided with the distribution.
//  
//  Neither the name of the project's author nor the names of its
//  contributors may be used to endorse or promote products derived from
//  this software without specific prior written permission.
//  
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
//  HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
//  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
//  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "AQSocket.h"
#import "AQSocketReader.h"
#import "AQSocketReader+PrivateInternal.h"
#import "AQSocketIOChannel.h"
#import <libkern/OSAtomic.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <syslog.h>

// See -connectToAddress:port:error: for discussion.
#if TARGET_OS_IPHONE
# import <UIKit/UIApplication.h>
#else
# import <dlfcn.h>
#endif

static NSString * __EventTrackingRunLoopMode()
{
    static NSString * __str = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if TARGET_OS_IPHONE
        __str = UITrackingRunLoopMode;
#else
        void * addr = dlsym(RTLD_DEFAULT, "NSEventTrackingRunLoopMode");
        if ( addr != NULL )
        {
            __str = (__bridge NSString*)addr;
        }
#endif
    });
    
    return ( __str );
}

#define LISTEN_WITH_CFSOCKET 0

@interface AQSocket (CFSocketConnectionCallback)
- (void) connectedSuccessfully;
- (void) connectionFailedWithError: (SInt32) err;
@end

@interface AQSocket (CFSocketAcceptCallback)
- (void) acceptNewConnection: (CFSocketNativeHandle) clientSock;
@end

static void _CFSocketConnectionCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    @autoreleasepool
    {
#if DEBUGLOG
        NSLog(@"CFSocketConnectionCallBack(%lu, %@)", type, info);
#endif
        if ( type != kCFSocketConnectCallBack )
            return;
        
        AQSocket * aqsock = (__bridge AQSocket *)info;
        if ( data == NULL )
            [aqsock connectedSuccessfully];
        else
            [aqsock connectionFailedWithError: *((SInt32 *)data)];
    }
}

static void _CFSocketAcceptCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    @autoreleasepool
    {
#if DEBUGLOG
        NSLog(@"CFSocketAcceptCallBack(%lu, %@)", type, info);
#endif
        if ( type != kCFSocketAcceptCallBack )
            return;
        
        AQSocket * aqsock = (__bridge AQSocket *)info;
        [aqsock acceptNewConnection: *((CFSocketNativeHandle *)data)];
    }
}

static BOOL _SocketAddressFromString(NSString * addrStr, BOOL isNumeric, UInt16 port, struct sockaddr_storage * outAddr, NSError * __autoreleasing* outError)
{
    // Flags for getaddrinfo():
    //
    // `AI_ADDRCONFIG`: Only return IPv4 or IPv6 if the local host has configured
    // interfaces for those types.
    //
    // `AI_V4MAPPED`: If no IPv6 addresses found, return an IPv4-mapped IPv6
    // address for any IPv4 addresses found.
    int flags = AI_ADDRCONFIG|AI_V4MAPPED;
    
    // If providing a numeric IPv4 or IPv6 string, tell getaddrinfo() not to
    // do DNS name lookup.
    if ( isNumeric )
        flags |= AI_NUMERICHOST;
    
    // We're assuming TCP at this point
    struct addrinfo hints = {
        .ai_flags = flags,
        .ai_family = AF_INET6,       // using AF_INET6 with 4to6 support
        .ai_socktype = SOCK_STREAM,
        .ai_protocol = IPPROTO_TCP
    };
    
    struct addrinfo *pLookup = NULL;
    
    // Hrm-- this is synchronous, which is required since we can't init asynchronously
    int err = getaddrinfo([addrStr UTF8String], NULL, &hints, &pLookup);
    if ( err != 0 )
    {
#if DEBUGLOG
        NSLog(@"Error from getaddrinfo() for address %@: %s", addrStr, gai_strerror(err));
#endif
        if ( outError != NULL )
        {
            NSDictionary * userInfo = [[NSDictionary alloc] initWithObjectsAndKeys: [NSString stringWithUTF8String: gai_strerror(err)], NSLocalizedDescriptionKey, nil];
            *outError = [NSError errorWithDomain: @"GetAddrInfoErrorDomain" code: err userInfo: userInfo];
#if USING_MRR
            [userInfo release];
#endif
        }
        
        return ( NO );
    }
    
    // Copy the returned address to the output parameter
    memcpy(outAddr, pLookup->ai_addr, pLookup->ai_addr->sa_len);
    
    switch ( outAddr->ss_family )
    {
        case AF_INET:
        {
            struct sockaddr_in *p = (struct sockaddr_in *)outAddr;
            p->sin_port = htons(port);  // remember to put in network byte-order!
            break;
        }
        case AF_INET6:
        {
            struct sockaddr_in6 *p = (struct sockaddr_in6 *)outAddr;
            p->sin6_port = htons(port); // network byte order again
            break;
        }
        default:
            return ( NO );
    }
    
    // Have to release the returned address information here
    freeaddrinfo(pLookup);
    return ( 0 );
}

#pragma mark -

@interface AQSocketCFHandlerThread : NSThread
{
    CFRunLoopRef _threadRunLoop;
}
@property (nonatomic, readonly) CFRunLoopRef runLoop;
@end

static AQSocketCFHandlerThread *__socketCFHandlerThread = nil;

@implementation AQSocketCFHandlerThread

@synthesize runLoop=_threadRunLoop;

static void _AQSocketCFRunLoopTimerHandler(CFRunLoopTimerRef timer, void *info)
{
    // does nothing
}

- (void) main
{
    _threadRunLoop = CFRunLoopGetCurrent();
    
    // keep it alive for at least a few seconds by attaching a timer
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent()+10.0, 0.0, 0, 0, _AQSocketCFRunLoopTimerHandler, NULL);
    CFRunLoopAddTimer(_threadRunLoop, timer, kCFRunLoopDefaultMode);
    CFRelease(timer);
    
    @autoreleasepool {
        CFRunLoopRun();
    }
    
    // nilify the global variable when we exit
    OSAtomicCompareAndSwapPtrBarrier((__bridge void*)self, nil, (void *)&__socketCFHandlerThread);
}

@end

static CFRunLoopRef AQSocketCFHandlerRunLoop(void)
{
    if ( __socketCFHandlerThread == nil )
    {
        __socketCFHandlerThread = [[AQSocketCFHandlerThread alloc] init];
        [__socketCFHandlerThread setName: @"AQSocketCFHandlerThread"];
        [__socketCFHandlerThread start];
        
        @autoreleasepool
        {
            while ( __socketCFHandlerThread.runLoop == NULL )
            {
                [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
            }
        }
    }
    
    return ( __socketCFHandlerThread.runLoop );
}

#pragma mark -

@implementation AQSocket
{
    int                     _socketType;
    int                     _socketProtocol;
    AQSocketStatus          _status;
    CFSocketRef             _socketRef;
    dispatch_source_t       _listenSource;
    CFSocketNativeHandle    _rawSocket;
    CFRunLoopSourceRef      _socketRunloopSource;
    dispatch_semaphore_t    _sync;
    AQSocketIOChannel *     _socketIO;
    AQSocketReader *        _socketReader;
}

@synthesize eventHandler, status=_status;

- (id) initWithSocketType: (int) type
{
    NSParameterAssert(type == SOCK_STREAM || type == SOCK_DGRAM);
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _socketType = type;
    _socketProtocol = (type == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP);
    
    _status = AQSocketUnconnected;
    
    // gets created with zero resources available. Will be signalled when socket becomes available for use.
    _sync = dispatch_semaphore_create(0);
    
    return ( self );
}

- (id) init
{
    return ( [self initWithSocketType: SOCK_STREAM] );
}

- (id) initWithConnectedSocket: (CFSocketNativeHandle) nativeSocket
{
    int socktype = SOCK_STREAM;
    socklen_t len = 0;
    
    getsockopt(nativeSocket, SOL_SOCKET, SO_TYPE, &socktype, &len);
    self = [self initWithSocketType: socktype];
    if ( self == nil )
        return ( nil );
    
    // don't send SIGPIPE
    int nosigpipe = 1;
	setsockopt(nativeSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    
    //CFSocketContext ctx = { 0, (__bridge void *)self, NULL, NULL, CFCopyDescription };
    //_socketRef = CFSocketCreateWithNative(kCFAllocatorDefault, nativeSocket, 0, NULL, &ctx);
    _rawSocket = nativeSocket;
    [self connectedSuccessfully];       // setup the io channel for data notifications etc.
    
    return ( self );
}

- (void) dealloc
{
    // disconnected == unusable, where unconnected == ready to connect.
    _status = AQSocketDisconnected;
    
    if ( _socketRef != NULL )
    {
        // Not got around to initializing the dispatch IO channel yet,
        // so we will have to release the socket ref manually.
        CFRelease(_socketRef);
    }
    if ( _socketRunloopSource != NULL )
    {
        // Ensure the source is no longer scheduled in any run loops.
        CFRunLoopRemoveSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, kCFRunLoopDefaultMode);
        NSString * eventMode = __EventTrackingRunLoopMode();
        if ( eventMode != nil )
        {
            CFRunLoopRemoveSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, (__bridge CFStringRef)eventMode);
            
            // Now we can safely release our reference to it.
            CFRelease(_socketRunloopSource);
        }
    }
    
    if ( _listenSource != NULL )
        dispatch_source_cancel(_listenSource);
    
#if USING_MRR || DISPATCH_USES_ARC == 0
    if ( _sync != NULL )
    {
        dispatch_release(_sync);
        _sync = NULL;
    }
    if ( _listenSource != NULL )
    {
        dispatch_release(_listenSource);
        _listenSource = NULL;
    }
#endif
#if USING_MRR
    [_socketReader release];
    [super dealloc];
#endif
}

- (BOOL) listenOnAddress: (struct sockaddr *) saddr
                   error: (NSError **) error
{
#if LISTEN_WITH_CFSOCKET
    // Create the socket with the appropriate socket family from the address
    // structure.
    CFSocketContext ctx = {
        .version = 0,
        .info = (__bridge void *)self,  // just a plain bridge cast
        .retain = CFRetain,
        .release = CFRelease,
        .copyDescription = CFCopyDescription
    };
    
    _socketRef = CFSocketCreate(kCFAllocatorDefault, saddr->sa_family, _socketType, _socketProtocol, kCFSocketAcceptCallBack, _CFSocketAcceptCallBack, &ctx);
    if ( _socketRef == NULL )
    {
        // We failed to create the socket, so build an error (if appropriate)
        // and return `NO`.
        if ( error != NULL )
        {
            // This error code is -1004.
            *error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorCannotConnectToHost userInfo: nil];
        }
        
        return ( NO );
    }
    
    // get the native socket
    _rawSocket = CFSocketGetNative(_socketRef);
    
    // enable the appropriate callbacks
    CFSocketSetSocketFlags(_socketRef, kCFSocketAutomaticallyReenableAcceptCallBack);
    CFSocketEnableCallBacks(_socketRef, kCFSocketAcceptCallBack);
    
    // Create a runloop source for the socket reference and bind it to a
    // runloop that's guaranteed to be running some time in the future: the main
    // one.
    _socketRunloopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socketRef, 0);
    CFRunLoopAddSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, kCFRunLoopCommonModes);
    
    // We also want to ensure that the connection callback fires during
    // input event tracking. There are different constants for this on iOS and
    // OS X, so I've used a compiler switch for that.
    NSString * eventMode = __EventTrackingRunLoopMode();
    if ( eventMode != nil )
    {
        CFRunLoopAddSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, (__bridge CFStringRef)eventMode);
    }
    
    NSData * sockData = [[NSData alloc] initWithBytesNoCopy: saddr length: saddr->sa_len freeWhenDone: NO];
    CFSocketError sockErr = CFSocketSetAddress(_socketRef, (__bridge CFDataRef)sockData);
#if USING_MRR
    [sockData release];
#endif
    if ( sockErr != kCFSocketSuccess )
        return ( NO );
#else
    _rawSocket = socket(saddr->sa_family, _socketType, _socketProtocol);
    if ( _rawSocket < 0 )
    {
        NSError * err = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
        NSLog(@"Failed to create listening socket: %@", err);
        if ( error != NULL )
            *error = err;
        return ( NO );
    }
    
    int val = 1;
    if ( setsockopt(_rawSocket, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val)) < 0 )
    {
#if DEBUGLOG
        NSLog(@"Failed to set SO_REUSEADDR on listening socket: %d (%s)", errno, strerror(errno));
#endif
    }
    if ( setsockopt(_rawSocket, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val)) < 0 )
    {
#if DEBUGLOG
        NSLog(@"Failed to set SO_NOSIGPIPE on listening socket: %d (%s)", errno, strerror(errno));
#endif
    }
    if ( bind(_rawSocket, saddr, saddr->sa_len) < 0 )
    {
        NSError * err = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
        NSLog(@"Error binding listening socket: %@", err);
        if ( error != NULL )
            *error = err;
        close(_rawSocket);
        _rawSocket = -1;
        return ( NO );
    }
    
    listen(_rawSocket, 16);
    _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _rawSocket, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    dispatch_debug(_listenSource, "listen source creation");
    
    AQSocket * __maybe_weak weakSelf = self;
    dispatch_source_set_event_handler(_listenSource, ^{
        AQSocket * strongSelf = weakSelf;
        int lfd = (int)dispatch_source_get_handle(_listenSource);
        int clientSock = accept(lfd, NULL, NULL);
        if ( clientSock < 0 )
        {
            NSError * err = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
            NSLog(@"%@ failed to accept new connection: %@", strongSelf, err);
            return;
        }
        
        [strongSelf acceptNewConnection: clientSock];
    });
    
    dispatch_resume(_listenSource);
    dispatch_debug(_listenSource, "listen source resumption");
#endif
    
    // Find out what port we were assigned.
    struct sockaddr_storage myAddr = {0};
    socklen_t slen = sizeof(struct sockaddr_storage);
    getsockname(_rawSocket, (struct sockaddr *)&myAddr, &slen);
    
    char addrStr[INET6_ADDRSTRLEN];
    struct sockaddr_in *pIn4 = (struct sockaddr_in *)&myAddr;
    struct sockaddr_in6 *pIn6 = (struct sockaddr_in6 *)&myAddr;
    inet_ntop(myAddr.ss_family, (myAddr.ss_family == AF_INET ? (void *)&pIn4->sin_addr : (void *)&pIn6->sin6_addr), addrStr, INET6_ADDRSTRLEN);
    
#if DEBUGLOG
    NSLog(@"Listening on %s:%hu", addrStr, (in_port_t)(myAddr.ss_family == AF_INET ? ntohs(pIn4->sin_port) : ntohs(pIn6->sin6_port)));
#endif
    
    // Record the change in status.
    _status = AQSocketListening;
    
    return ( YES );
}

- (BOOL) listenForConnections: (BOOL) useLoopback
                      useIPv6: (BOOL) useIPv6
                        error: (NSError **) error
{
    if ( _status != AQSocketUnconnected )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"Socket is already in use.", @"Socket connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: _status userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
    }
    
    // This is only initialized once we have successfully set up the connection.
    if ( _socketIO != nil )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"Already connected.", @"Connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: AQSocketConnected userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
        
        return ( NO );
    }
    
    // Create a local address to which we'll bind.
    struct sockaddr_storage saddr = {0};
    if ( useIPv6 )
    {
        saddr.ss_len = sizeof(struct sockaddr_in6);
        saddr.ss_family = AF_INET6;
        
        struct sockaddr_in6 *pIn = (struct sockaddr_in6 *)&saddr;
        pIn->sin6_port = 0;
        pIn->sin6_addr = (useLoopback? in6addr_loopback : in6addr_any);
    }
    else
    {
        saddr.ss_len = sizeof(struct sockaddr_in);
        saddr.ss_family = AF_INET;
        
        struct sockaddr_in *pIn = (struct sockaddr_in *)&saddr;
        pIn->sin_port = 0;
        pIn->sin_addr.s_addr = htonl((useLoopback ? INADDR_LOOPBACK : INADDR_ANY));
    }
    
    return ( [self listenOnAddress: (struct sockaddr *)&saddr error: error] );
}

- (BOOL) connectToAddress: (struct sockaddr *) saddr
                    error: (NSError **) error
{
    if ( _status != AQSocketUnconnected )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"Socket is already in use.", @"Socket connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: _status userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
    }
    
    // We're only initializing this member once we successfully connect
    if ( _socketIO != nil )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"Already connected.", @"Connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: 1 userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
        
        return ( NO );
    }
    
    // We require that an event handler be set, so we can notify
    // connection success
    if ( self.eventHandler == nil )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"No event handler provided.", @"Connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: 2 userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
        
        return ( NO );
    }
    
    // Create the socket with the appropriate socket family from the address
    // structure.
    CFSocketContext ctx = {
        .version = 0,
        .info = (__bridge void *)self,  // just a plain bridge cast
        .retain = CFRetain,
        .release = CFRelease,
        .copyDescription = CFCopyDescription
    };
    
    _socketRef = CFSocketCreate(kCFAllocatorDefault, saddr->sa_family, _socketType, _socketProtocol, kCFSocketConnectCallBack, _CFSocketConnectionCallBack, &ctx);
    if ( _socketRef == NULL )
    {
        // We failed to create the socket, so build an error (if appropriate)
        // and return `NO`.
        if ( error != NULL )
        {
            // This error code is -1004.
            *error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorCannotConnectToHost userInfo: nil];
        }
        
        return ( NO );
    }
    
    // get the native socket
    _rawSocket = CFSocketGetNative(_socketRef);
    
    // Create a runloop source for the socket reference and bind it to a
    // runloop that's guaranteed to be running some time in the future: the main
    // one.
    _socketRunloopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socketRef, 0);
    CFRunLoopAddSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, kCFRunLoopDefaultMode);
    
    // We also want to ensure that the connection callback fires during
    // input event tracking. There are different constants for this on iOS and
    // OS X, so I've used a compiler switch for that.
    NSString * eventMode = __EventTrackingRunLoopMode();
    if ( eventMode != nil )
    {
        CFRunLoopAddSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, (__bridge CFStringRef)eventMode);
    }
    // Start the connection process.
    // Let's fire off the connection attempt and wait for the socket to become
    // readable, which means the connection succeeded. The timeout value of
    // -1 means 'do it in the background', meaning our C callback will be invoked
    // when the connection attempt succeeds or fails.
    // Note that in this instance I'm using a plain __bridge cast for `data`, so
    // that no retain/release operations or change of ownership is implied.
    NSData * data = [[NSData alloc] initWithBytesNoCopy: saddr
                                                 length: saddr->sa_len
                                           freeWhenDone: NO];
    CFSocketError err = CFSocketConnectToAddress(_socketRef, (__bridge CFDataRef)data, -1);
#if USING_MRR
    [data release];
#endif
    
    if ( err != kCFSocketSuccess )
    {
#if DEBUGLOG
        NSLog(@"Error connecting socket: %ld", err);
#endif
        
        if ( error != NULL )
        {
            if ( err == kCFSocketError )
            {
                // Try to get hold of the underlying error from the raw socket.
                int sockerr = 0;
                socklen_t len = sizeof(sockerr);
                if ( getsockopt(_rawSocket, SOL_SOCKET, SO_ERROR, &sockerr, &len) == -1 )
                {
                    // Yes, this is cheating.
                    sockerr = errno;
                }
                
                // The CoreFoundation CFErrorRef (toll-free-bridged with NSError)
                // actually fills in the userInfo for POSIX errors from a
                // localized table. Neat, huh?
                *error = [NSError errorWithDomain: NSPOSIXErrorDomain code: sockerr userInfo: nil];
            }
            else
            {
                // By definition, it's a timeout.
                // I'm not returning a userInfo here: code is -1001
                *error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorTimedOut userInfo: nil];
            }
        }
        
        return ( NO );
    }
    
    // Update our connection status.
    _status = AQSocketConnecting;
    
    // The asynchronous connection attempt has begun.
    return ( YES );
}

- (BOOL) connectToHost: (NSString *) hostname
                  port: (UInt16) port
                 error: (NSError **) error
{
    NSParameterAssert([hostname length] != 0);
    struct sockaddr_storage addrStore = {0};
    
    // Convert the hostname into a socket address. This method installs the
    // port number into any returned socket address, and generates an NSError
    // for us should something go wrong.
    if ( _SocketAddressFromString(hostname, NO, port, &addrStore, error) == NO )
        return ( NO );
    
    return ( [self connectToAddress: (struct sockaddr *)&addrStore
                              error: error] );
}

- (BOOL) connectToIPAddress: (NSString *) address
                       port: (UInt16) port
                      error: (NSError **) error
{
    NSParameterAssert([address length] != 0);
    struct sockaddr_storage addrStore = {0};
    
    // Convert the hostname into a socket address. This method installs the
    // port number into any returned socket address, and generates an NSError
    // for us should something go wrong.
    if ( _SocketAddressFromString(address, YES, port, &addrStore, error) == NO )
        return ( NO );
    
    return ( [self connectToAddress: (struct sockaddr *)&addrStore
                              error: error] );
}

- (void) close
{
    if ( _socketIO == nil )
        return;
    
    // wait for any write-schedules to complete, and claim the resource.
    dispatch_semaphore_wait(_sync, DISPATCH_TIME_FOREVER);
    
    [_socketIO close];
#if USING_MRR
    [_socketIO release];
#endif
    _socketIO = nil;
    
    if ( _socketRef != NULL )
    {
        CFRelease(_socketRef);
        _socketRef = NULL;
    }
    
    if ( _listenSource != NULL )
    {
        dispatch_source_cancel(_listenSource);
#if USING_MRR || DISPATCH_USES_ARC == 0
        dispatch_release(_listenSource);
#endif
        _listenSource = NULL;
    }
    
    if ( _rawSocket != -1 )
        close(_rawSocket);
    
    // We set 'disconnected' state if we close because of a connection reset or broken pipe, etc.
    // If that isn't set, then this is considered a voluntary disconnect, so we mark the socket
    // as being reusable.
    if ( _status != AQSocketDisconnected )
        _status = AQSocketUnconnected;
    
    // NB: we do NOT release the socket resource because it's gone now; it'll be released (if recreated) later.
}

- (struct sockaddr_storage) socketAddress
{
    struct sockaddr_storage saddr = {0};
    socklen_t slen = sizeof(saddr);
    if ( _rawSocket != -1 )
        getsockname(_rawSocket, (struct sockaddr *)&saddr, &slen);
    return ( saddr );
}

- (struct sockaddr_storage) peerSocketAddress
{
    struct sockaddr_storage saddr = {0};
    socklen_t slen = sizeof(saddr);
    if ( _rawSocket != -1 )
        getpeername(_rawSocket, (struct sockaddr *)&saddr, &slen);
    return ( saddr );
}

- (uint16_t) port
{
    if ( _rawSocket == -1 )
        return ( 0 );
    
    struct sockaddr_storage saddr = self.socketAddress;
    
    struct sockaddr_in *pIn4 = (struct sockaddr_in *)&saddr;
    struct sockaddr_in6 *pIn6 = (struct sockaddr_in6 *)&saddr;
    
    uint16_t port = 0;
    if ( saddr.ss_family == AF_INET )
        port = ntohs(pIn4->sin_port);
    else if ( saddr.ss_family == AF_INET6 )
        port = ntohs(pIn6->sin6_port);
    
    return ( port );
}

- (void) writeBytes: (NSData *) bytes
         completion: (void (^)(NSData *, NSError *)) completionHandler
{
    NSParameterAssert([bytes length] != 0);
    if ( _status != AQSocketConnected )
        return;
    
    // claim the socket resource
    if ( dispatch_semaphore_wait(_sync, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0 )
        return;     // timed out, which means we've got no socket any more
    
    if ( _socketIO == nil )
    {
        [NSException raise: NSInternalInconsistencyException format: @"-[%@ %@]: socket is not connected.", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    }
    
    // Pass the write along to our IO channel, along with the completion/unsent handler.
    [_socketIO writeData: bytes withCompletion: completionHandler];
    
    // reopen the resource for others
    dispatch_semaphore_signal(_sync);
}

- (void) setEventHandler: (AQSocketEventHandler) anEventHandler
{
#if USING_MRR
    anEventHandler = [anEventHandler copy];
    AQSocketEventHandler oldHandler = eventHandler;
#endif
    eventHandler = anEventHandler;
#if USING_MRR
    [oldHandler release];
#endif
    
    if ( anEventHandler != nil && [_socketReader length] > 0 )
    {
#if USING_MRR
        [_socketReader retain];
#endif
        anEventHandler(AQSocketEventDataAvailable, _socketReader);
#if USING_MRR
        [_socketReader release];
#endif
    }
}

- (NSString *) description
{
    static NSArray * __statusStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __statusStrings = [[NSArray alloc] initWithObjects: @"AQSocketUnconnected", @"AQSocketConnecting", @"AQSocketListening", @"AQSocketConnected", @"AQSocketDisconnected", nil];
    });
    
    if ( _socketRef == NULL )
    {
        return ( [NSString stringWithFormat: @"%@: status=%@", [super description], [__statusStrings objectAtIndex: _status]] );
    }
    
    struct sockaddr_storage sockname = {0};
    struct sockaddr_storage peername = {0};
    socklen_t socknamelen = sockname.ss_len = sizeof(struct sockaddr_storage);
    socklen_t peernamelen = peername.ss_len = sizeof(struct sockaddr_storage);
    
    BOOL gotMine = (getsockname(_rawSocket, (struct sockaddr *)&sockname, &socknamelen) == 0);
    BOOL gotPeer = (getpeername(_rawSocket, (struct sockaddr *)&peername, &peernamelen) == 0);
    
    char socknamestr[INET6_ADDRSTRLEN];
    char peernamestr[INET6_ADDRSTRLEN];
    
    if ( gotMine )
    {
        if ( sockname.ss_family == AF_INET )
        {
            struct sockaddr_in *pIn = (struct sockaddr_in *)&sockname;
            inet_ntop(sockname.ss_family, &pIn->sin_addr, socknamestr, INET6_ADDRSTRLEN);
        }
        else
        {
            struct sockaddr_in6 *pIn = (struct sockaddr_in6 *)&sockname;
            inet_ntop(sockname.ss_family, &pIn->sin6_addr, socknamestr, INET6_ADDRSTRLEN);
        }
    }
    else
    {
        socknamestr[0] = '\0';
    }
    
    if ( gotPeer )
    {
        if ( peername.ss_family == AF_INET )
        {
            struct sockaddr_in *pIn = (struct sockaddr_in *)&peername;
            inet_ntop(peername.ss_family, &pIn->sin_addr, peernamestr, INET6_ADDRSTRLEN);
        }
        else
        {
            struct sockaddr_in6 *pIn = (struct sockaddr_in6 *)&peername;
            inet_ntop(peername.ss_family, &pIn->sin6_addr, peernamestr, INET6_ADDRSTRLEN);
        }
    }
    else
    {
        peernamestr[0] = '\0';
    }
    
    socknamestr[INET6_ADDRSTRLEN-1] = '\0';
    peernamestr[INET6_ADDRSTRLEN-1] = '\0';
    
    uint16_t sockport = 0, peerport = 0;
    if ( sockname.ss_family == AF_INET )
    {
        struct sockaddr_in *p = (struct sockaddr_in *)&sockname;
        sockport = ntohs(p->sin_port);
    }
    else if ( sockname.ss_family == AF_INET6 )
    {
        struct sockaddr_in6 *p = (struct sockaddr_in6 *)&sockname;
        sockport = ntohs(p->sin6_port);
    }
    if ( peername.ss_family == AF_INET )
    {
        struct sockaddr_in *p = (struct sockaddr_in *)&peername;
        peerport = ntohs(p->sin_port);
    }
    else if ( peername.ss_family == AF_INET6 )
    {
        struct sockaddr_in6 *p = (struct sockaddr_in6 *)&peername;
        peerport = ntohs(p->sin6_port);
    }
    
    NSString * myAddr = (gotMine ? [NSString stringWithFormat: @"%s:%hu", socknamestr, sockport] : @"<unknown>");
    NSString * peerAddr = (gotMine ? [NSString stringWithFormat: @"%s:%hu", peernamestr, peerport] : @"<unknown>");
    
    return ( [NSString stringWithFormat: @"%@: {status=%@, addr=%@, peer=%@}", [super description], [__statusStrings objectAtIndex: _status], myAddr, peerAddr] );
}

@end

@implementation AQSocket (CFSocketConnectionCallback)

- (void) connectedSuccessfully
{
    // Now that we're connected, we must set up a couple of things:
    //
    // 1. The dispatch IO channel through which we will handle reads and writes.
    // 2. The AQSocketReader object which will serve as our read buffer.
    // 3. The dispatch source which will notify us of incoming data.
    
    // Before all that though, we'll remove the CFSocketRef from the runloop.
    if ( _socketRunloopSource != NULL )
    {
        CFRunLoopRemoveSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, kCFRunLoopDefaultMode);
        NSString * eventMode = __EventTrackingRunLoopMode();
        if ( eventMode != nil )
        {
            CFRunLoopRemoveSource(AQSocketCFHandlerRunLoop(), _socketRunloopSource, (__bridge CFStringRef)eventMode);
        }
        
        // All done with this one now.
        CFRelease(_socketRunloopSource);
        _socketRunloopSource = NULL;
    }
    
    // Note that we are now connected.
    _status = AQSocketConnected;
    
    // First, the IO channel. We will have its cleanup handler release the
    // CFSocketRef for us; in other words, the IO channel now owns the
    // CFSocketRef.
    _socketIO = [[AQSocketIOChannel alloc] initWithNativeSocket: _rawSocket cleanupHandler: ^{
        // all done with the socket reference, make it noticeably go away.
        if ( _socketRef != NULL )
        {
            CFRelease(_socketRef);
            _socketRef = NULL;
        }
    }];
    
    // Next the socket reader object. This will keep track of all the data blobs
    // returned via dispatch_io_read(), providing peek support to the upper
    // protocol layers.
    // Note that we initialize it as a stack variable initially, which we use in the block
    // below to avoid a retain-cycle.
    AQSocketReader * aSocketReader = [AQSocketReader new];
#if USING_MRR
    _socketReader = [aSocketReader retain];
#else
    _socketReader = aSocketReader;
#endif
    
    __block_weak AQSocket *weakSelf = self;
    
    // Now we install a callback to tell us when new data arrives.
    _socketIO.readHandler = ^(NSData * data, NSError * error){
        AQSocket *strongSelf = weakSelf;
        
#if DEBUGLOG
        NSLog(@"Incoming data on %@: %lu bytes", strongSelf, (unsigned long)[data length]);
#endif
        if ( data != nil )
        {
            if ( [data length] != 0 )
            {
                [aSocketReader appendData: data];   // if using a dispatch data wrapper, this method will notice and do the right thing automatically
                if ( strongSelf.eventHandler != nil )
                    strongSelf.eventHandler(AQSocketEventDataAvailable, aSocketReader);
            }
            else
            {
                // socket closed
                strongSelf->_status = AQSocketDisconnected;
#if DEBUGLOG
                NSLog(@"Socket %@: zero-length data received, closing now", strongSelf);
#endif
                if ( strongSelf.eventHandler != nil )
                    strongSelf.eventHandler(AQSocketEventDisconnected, nil);
                [strongSelf close];
            }
        }
        else if ( error != nil )
        {
#if DEBUGLOG
            NSLog(@"Error on %@; %@", strongSelf, error);
#endif
            if ( strongSelf.eventHandler != nil )
                strongSelf.eventHandler(AQSocketErrorEncountered, error);
        }
        else if ( data == nil )
        {
            strongSelf->_status = AQSocketDisconnected;
#if DEBUGLOG
            NSLog(@"Connection reset for %@", strongSelf);
#endif
            [strongSelf close];
            if ( strongSelf.eventHandler != nil )
                strongSelf.eventHandler(AQSocketEventDisconnected, nil);
        }
    };
    
#if USING_MRR
    [aSocketReader release];
#endif
    
    // socket is now available for use
    dispatch_semaphore_signal(_sync);
}

- (void) connectionFailedWithError: (SInt32) err
{
    NSError * info = [NSError errorWithDomain: NSPOSIXErrorDomain code: err userInfo: nil];
    self.eventHandler(AQSocketEventConnectionFailed, info);
    
    // Get rid of the socket now, since we might try to re-connect, which will
    // create a new CFSocketRef.
    if ( _socketRef != NULL )
    {
        CFRelease(_socketRef);
        _socketRef = NULL;
    }
}

@end

@implementation AQSocket (CFSocketAcceptCallback)

- (void) acceptNewConnection: (CFSocketNativeHandle) clientSock
{
    AQSocket * child = [[AQSocket alloc] initWithConnectedSocket: clientSock];
    if ( child == nil )
        return;
    
#if DEBUGLOG
    NSLog(@"Listening socket %@ accepted new connection on child socket %@", self, child);
#endif
    
    // Inform the client about the appearance of the child socket.
    // It's up to the client to keep it around -- we just pass it on as appropriate.
    self.eventHandler(AQSocketEventAcceptedNewConnection, child);
#if USING_MRR
    [child release];
#endif
}

@end
