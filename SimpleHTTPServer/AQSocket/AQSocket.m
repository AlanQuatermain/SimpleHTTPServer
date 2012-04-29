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
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <syslog.h>

// See -connectToAddress:port:error: for discussion.
#if TARGET_OS_IPHONE
#import <UIKit/UIApplication.h>
#else
#import <AppKit/NSApplication.h>
#endif

@interface AQSocket (CFSocketConnectionCallback)
- (void) connectedSuccessfully;
- (void) connectionFailedWithError: (SInt32) err;
@end

@interface AQSocket (CFSocketAcceptCallback)
- (void) acceptNewConnection: (CFSocketNativeHandle) clientSock;
@end

static void _CFSocketConnectionCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if ( type != kCFSocketConnectCallBack )
        return;
    
    AQSocket * aqsock = (__bridge AQSocket *)info;
    if ( data == NULL )
        [aqsock connectedSuccessfully];
    else
        [aqsock connectionFailedWithError: *((SInt32 *)data)];
}

static void _CFSocketAcceptCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if ( type != kCFSocketAcceptCallBack )
        return;
    
    AQSocket * aqsock = (__bridge AQSocket *)info;
    [aqsock acceptNewConnection: *((CFSocketNativeHandle *)data)];
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
        NSLog(@"Error from getaddrinfo() for address %@: %s", addrStr, gai_strerror(err));
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

@implementation AQSocket
{
    int                 _socketType;
    int                 _socketProtocol;
    AQSocketStatus      _status;
    CFSocketRef         _socketRef;
    CFRunLoopSourceRef  _socketRunloopSource;
    AQSocketIOChannel * _socketIO;
    AQSocketReader *    _socketReader;
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
    
    CFSocketContext ctx = { 0, (__bridge void *)self, NULL, NULL, CFCopyDescription };
    _socketRef = CFSocketCreateWithNative(kCFAllocatorDefault, nativeSocket, 0, NULL, &ctx);
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
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
#if 0
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                              UITrackingRunLoopMode
#else
                              NSEventTrackingRunLoopMode
#endif
                              );
#endif
        
        // Now we can safely release our reference to it.
        CFRelease(_socketRunloopSource);
    }
#if USING_MRR
    [_socketReader release];
    [super dealloc];
#endif
}

- (BOOL) listenForConnections: (BOOL) useLoopback error: (NSError **) error
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
    
    struct sockaddr_in saddr = {0};
    NSData * sockData = [[NSData alloc] initWithBytesNoCopy: &saddr length: sizeof(struct sockaddr_in) freeWhenDone: NO];
    
    // Create a local address to which we'll bind. Sticking with IPv4 for now.
    struct sockaddr_in *pIn = &saddr;
    pIn->sin_family = AF_INET;
    pIn->sin_len = sizeof(struct sockaddr_in);
    pIn->sin_port = 0;
    pIn->sin_addr.s_addr = htonl((useLoopback ? INADDR_LOOPBACK : INADDR_ANY));
    
    // Create the socket with the appropriate socket family from the address
    // structure.
    CFSocketContext ctx = {
        .version = 0,
        .info = (__bridge void *)self,  // just a plain bridge cast
        .retain = CFRetain,
        .release = CFRelease,
        .copyDescription = CFCopyDescription
    };
    
    _socketRef = CFSocketCreate(kCFAllocatorDefault, saddr.sin_family, _socketType, _socketProtocol, kCFSocketAcceptCallBack, _CFSocketAcceptCallBack, &ctx);
    if ( _socketRef == NULL )
    {
        // We failed to create the socket, so build an error (if appropriate)
        // and return `NO`.
        if ( error != NULL )
        {
            // This error code is -1004.
            *error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorCannotConnectToHost userInfo: nil];
        }
        
#if USING_MRR
        [sockData release];
#endif
        return ( NO );
    }
    
    // Create a runloop source for the socket reference and bind it to a
    // runloop that's guaranteed to be running some time in the future: the main
    // one.
    _socketRunloopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socketRef, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
    
    // We also want to ensure that the connection callback fires during
    // input event tracking. There are different constants for this on iOS and
    // OS X, so I've used a compiler switch for that.
#if 0
    CFRunLoopAddSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                       UITrackingRunLoopMode
#else
                       NSEventTrackingRunLoopMode
#endif
                       );
#endif
    CFSocketError sockErr = CFSocketSetAddress(_socketRef, (__bridge CFDataRef)sockData);
#if USING_MRR
    [sockData release];
#endif
    if ( sockErr != kCFSocketSuccess )
        return ( NO );
    
    // Find out what port we were assigned.
    struct sockaddr_in myAddr = {0};
    socklen_t slen = sizeof(struct sockaddr_in);
    getsockname(CFSocketGetNative(_socketRef), (struct sockaddr *)&myAddr, &slen);
    
    NSLog(@"Using port %hu", ntohs(myAddr.sin_port));
    
    CFSocketSetSocketFlags(_socketRef, kCFSocketAutomaticallyReenableAcceptCallBack);
    CFSocketEnableCallBacks(_socketRef, kCFSocketAcceptCallBack);
    
    // Record the change in status.
    _status = AQSocketListening;
    
    return ( YES );
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
    
    // Create a runloop source for the socket reference and bind it to a
    // runloop that's guaranteed to be running some time in the future: the main
    // one.
    _socketRunloopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socketRef, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
    
    // We also want to ensure that the connection callback fires during
    // input event tracking. There are different constants for this on iOS and
    // OS X, so I've used a compiler switch for that.
#if 0
    CFRunLoopAddSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                       UITrackingRunLoopMode
#else
                       NSEventTrackingRunLoopMode
#endif
                       );
#endif
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
        NSLog(@"Error connecting socket: %ld", err);
        
        if ( error != NULL )
        {
            if ( err == kCFSocketError )
            {
                // Try to get hold of the underlying error from the raw socket.
                int sockerr = 0;
                socklen_t len = sizeof(sockerr);
                if ( getsockopt(CFSocketGetNative(_socketRef), SOL_SOCKET, SO_ERROR, &sockerr, &len) == -1 )
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
    [_socketIO close];
#if USING_MRR
    [_socketIO release];
#endif
    _socketIO = nil;
    
    if ( _socketRef != NULL )
    {
        int sock = CFSocketGetNative(_socketRef);
        CFRelease(_socketRef);
        _socketRef = NULL;
        close(sock);
    }
    
    // We set 'disconnected' state if we close because of a connection reset or broken pipe, etc.
    // If that isn't set, then this is considered a voluntary disconnect, so we mark the socket
    // as being reusable.
    if ( _status != AQSocketDisconnected )
        _status = AQSocketUnconnected;
}

- (void) writeBytes: (NSData *) bytes
         completion: (void (^)(NSData *, NSError *)) completionHandler
{
    NSParameterAssert([bytes length] != 0);
    
    if ( _socketIO == nil )
    {
        [NSException raise: NSInternalInconsistencyException format: @"-[%@ %@]: socket is not connected.", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    }
    
    // Pass the write along to our IO channel, along with the completion/unsent handler.
    [_socketIO writeData: bytes withCompletion: completionHandler];
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
    struct sockaddr_storage sockname = {0};
    struct sockaddr_storage peername = {0};
    socklen_t socknamelen = sockname.ss_len = sizeof(struct sockaddr_storage);
    socklen_t peernamelen = peername.ss_len = sizeof(struct sockaddr_storage);
    
    BOOL gotMine = (getsockname(CFSocketGetNative(_socketRef), (struct sockaddr *)&sockname, &socknamelen) == 0);
    BOOL gotPeer = (getpeername(CFSocketGetNative(_socketRef), (struct sockaddr *)&peername, &peernamelen) == 0);
    
    char socknamestr[INET6_ADDRSTRLEN];
    char peernamestr[INET6_ADDRSTRLEN];
    
    if ( gotMine )
        inet_ntop(sockname.ss_family, &sockname, socknamestr, INET6_ADDRSTRLEN);
    else
        socknamestr[0] = '\0';
    
    if ( gotPeer )
        inet_ntop(peername.ss_family, &peername, peernamestr, INET6_ADDRSTRLEN);
    else
        peernamestr[0] = '\0';
    
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
    
    static NSArray * __statusStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __statusStrings = [[NSArray alloc] initWithObjects: @"AQSocketUnconnected", @"AQSocketConnecting", @"AQSocketListening", @"AQSocketConnected", @"AQSocketDisconnected", nil];
    });
    
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
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
#if 0
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                              UITrackingRunLoopMode
#else
                              NSEventTrackingRunLoopMode
#endif
                              );
#endif
        // All done with this one now.
        CFRelease(_socketRunloopSource);
        _socketRunloopSource = NULL;
    }
    
    // Note that we are now connected.
    _status = AQSocketConnected;
    
    // First, the IO channel. We will have its cleanup handler release the
    // CFSocketRef for us; in other words, the IO channel now owns the
    // CFSocketRef.
    _socketIO = [[AQSocketIOChannel alloc] initWithNativeSocket: CFSocketGetNative(_socketRef) cleanupHandler: ^{
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
        NSLog(@"Incoming data on %@: %lu bytes", strongSelf, [data length]);
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
                NSLog(@"Socket %@: zero-length data received, closing now", strongSelf);
                dispatch_async(dispatch_get_main_queue(), ^{[strongSelf close];});
            }
        }
        else if ( error != nil )
        {
            NSLog(@"Error on %@; %@", strongSelf, error);
            if ( strongSelf.eventHandler != nil )
                strongSelf.eventHandler(AQSocketErrorEncountered, error);
        }
        else if ( data == nil )
        {
            strongSelf->_status = AQSocketDisconnected;
            NSLog(@"Connection reset for %@", strongSelf);
            dispatch_async(dispatch_get_main_queue(), ^{[strongSelf close];});
        }
    };
}

- (void) connectionFailedWithError: (SInt32) err
{
    NSError * info = [NSError errorWithDomain: NSPOSIXErrorDomain code: err userInfo: nil];
    self.eventHandler(AQSocketEventConnectionFailed, info);
    
    // Get rid of the socket now, since we might try to re-connect, which will
    // create a new CFSocketRef.
    CFRelease(_socketRef); _socketRef = NULL;
}

@end

@implementation AQSocket (CFSocketAcceptCallback)

- (void) acceptNewConnection: (CFSocketNativeHandle) clientSock
{
    AQSocket * child = [[AQSocket alloc] initWithConnectedSocket: clientSock];
    if ( child == nil )
        return;
    
    // Inform the client about the appearance of the child socket.
    // It's up to the client to keep it around -- we just pass it on as appropriate.
    self.eventHandler(AQSocketEventAcceptedNewConnection, child);
#if USING_MRR
    [child release];
#endif
}

@end
