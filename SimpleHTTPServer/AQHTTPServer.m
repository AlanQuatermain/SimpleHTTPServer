//
//  AQHTTPServer.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPServer.h"
#import "AQSocket.h"
#import "AQHTTPConnection_PrivateInternal.h"
#import <arpa/inet.h>

@implementation AQHTTPServer
{
    AQSocket *      _serverSocket4;
    AQSocket *      _serverSocket6;
    NSMutableSet *  _connections;
    
    BOOL            _isLocalhost;
    NSString *      _address;
    NSURL *         _root;
    
    Class           _connectionClass;
    
    BOOL            _disconnecting;
}

@synthesize documentRoot=_root;

- (id) initWithAddress: (NSString *) address root: (NSURL *) root
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _address = [address copy];
    _root = [root copy];
    _connections = [NSMutableSet new];
    
    return ( self );
}

#if USING_MRR
- (void) dealloc
{
    [_address release];
    [_root release];
    [_connections release];
    [_serverSocket4 release];
    [_serverSocket6 release];
    [super dealloc];
}
#endif

- (BOOL) start: (NSError **) error
{
    if ( _serverSocket4 != nil || _serverSocket6 != nil )
        return ( NO );
    
    _serverSocket4 = [[AQSocket alloc] init];
    _serverSocket6 = [[AQSocket alloc] init];
    
    AQHTTPServer * __maybe_weak server = self;
    AQSocketEventHandler handlerBlock = ^(AQSocketEvent event, id info) {
        // ooooh, retain-cycle warnings FTW
        AQHTTPServer * strongServer = server;
        if ( strongServer == nil )
            return;
        
        if ( event == AQSocketEventDisconnected && !strongServer->_disconnecting )
        {
            NSLog(@"Server socket disconnected unexpectedly!");
            return;
        }
        
        if ( event != AQSocketEventAcceptedNewConnection )
            return;
        
#if DEBUGLOG
        NSLog(@"New connection incoming; socket=%@", info);
#endif
        AQSocket *newSocket = info;
        if ( strongServer->_root == nil )
        {
#if DEBUGLOG
            NSLog(@"No document root URL: rejecting on socket %@", newSocket);
#endif
            [newSocket close];
            return;
        }
        
        Class connectionClass = strongServer->_connectionClass;
        if ( connectionClass == nil )
            connectionClass = [AQHTTPConnection class];
        AQHTTPConnection * newConnection = [[connectionClass alloc] initWithSocket: info documentRoot: strongServer->_root forServer: self];
        newConnection.delegate = strongServer;
        [strongServer->_connections addObject: newConnection];
#if DEBUGLOG
        NSLog(@"Created new connection %@", newConnection);
#endif
#if USING_MRR
        [newConnection release];
#endif
    };
    
    _serverSocket4.eventHandler = handlerBlock;
    _serverSocket6.eventHandler = handlerBlock;
    
    _isLocalhost = ([_address caseInsensitiveCompare: @"loopback"] == NSOrderedSame || [_address caseInsensitiveCompare: @"localhost"] == NSOrderedSame);
    
    if ( [_serverSocket4 listenForConnections: _isLocalhost useIPv6: NO error: error] == NO )
    {
#if USING_MRR
        [_serverSocket4 release];
        [_serverSocket6 release];
#endif
        _serverSocket4 = nil;
        _serverSocket6 = nil;
        return ( NO );
    }
    
    NSError * ipv6Error = nil;
    if ( [_serverSocket6 listenForConnections: _isLocalhost useIPv6: YES error: &ipv6Error] == NO )
    {
        // drop down to IPv4 only
#if USING_MRR
        [_serverSocket6 release];
#endif
        _serverSocket6 = nil;
    }
    
    return ( YES );
}

- (void) _clearConnections
{
    for ( AQHTTPConnection * connection in _connections )
    {
        connection.delegate = nil;      // so we don't get the callback immediately after calling -close
        [connection close];
    }
    
    [_connections removeAllObjects];
}

- (void) _shutdownSockets
{
    _serverSocket4.eventHandler = nil;
    [_serverSocket4 close];
    _serverSocket6.eventHandler = nil;
    [_serverSocket6 close];
}

- (void) stop
{
    [self _clearConnections];
    [self _shutdownSockets];
    
#if USING_MRR
    [_serverSocket4 release];
    [_serverSocket6 release];
#endif
    _serverSocket4 = nil;
    _serverSocket6 = nil;
}

- (BOOL) reset
{
    AQSocketEventHandler handlerBlock = _serverSocket4.eventHandler;
#if USING_MRR
    [handlerBlock retain];
#endif
    
    struct sockaddr_storage in4addr = _serverSocket4.socketAddress;
    struct sockaddr_storage in6addr = _serverSocket6.socketAddress;
    
    [self _clearConnections];
    [self _shutdownSockets];
    
    BOOL keptPorts = YES;
    
    NSError * error = nil;
    if ( [_serverSocket4 listenOnAddress: (struct sockaddr *)&in4addr error: &error] == NO )
    {
        keptPorts = NO;
#if DEBUGLOG
        NSLog(@"Error resetting IPv4 listening socket using old address: %@", error);
#endif
        struct sockaddr_in *pIn = (struct sockaddr_in *)&in4addr;
        pIn->sin_port = 0;
        [_serverSocket4 listenOnAddress: (struct sockaddr *)pIn error: NULL];
    }
    
    error = nil;
    if ( [_serverSocket6 listenOnAddress: (struct sockaddr *)&in6addr error: &error] == NO )
    {
        keptPorts = NO;
#if DEBUGLOG
        NSLog(@"Error resetting IPv6 listening socket using old address: %@", error);
#endif
        struct sockaddr_in6 *pIn = (struct sockaddr_in6 *)&in6addr;
        pIn->sin6_port = 0;
        [_serverSocket6 listenOnAddress: (struct sockaddr *)pIn error: NULL];
    }
    
    _serverSocket4.eventHandler = handlerBlock;
    _serverSocket6.eventHandler = handlerBlock;
    
#if USING_MRR
    [handlerBlock release];
#endif
    
    return ( keptPorts );
}

- (BOOL) isListening
{
    return ( _serverSocket4 != nil || _serverSocket6 != nil );
}

- (NSString *) serverAddress
{
    struct sockaddr_storage saddr = {0};
    
    // for localhost I'll stick to IPv4, since I don't know how to force IPv6 for a hostname
    if ( _isLocalhost == NO && _serverSocket6 != nil )
        saddr = _serverSocket6.socketAddress;
    
    if ( saddr.ss_len == 0 )
        saddr = _serverSocket4.socketAddress;
    
    if ( saddr.ss_len == 0 )
        return ( nil );
    
    char namebuf[INET6_ADDRSTRLEN];
    uint16_t port = 0;
    
    if ( saddr.ss_family == AF_INET )
    {
        struct sockaddr_in *pIn = (struct sockaddr_in *)&saddr;
        if ( _isLocalhost )
            strlcpy(namebuf, "localhost", INET6_ADDRSTRLEN);
        else
            inet_ntop(AF_INET, &pIn->sin_addr, namebuf, INET6_ADDRSTRLEN);
        port = ntohs(pIn->sin_port);
    }
    else if ( saddr.ss_family == AF_INET6 )
    {
        struct sockaddr_in6 *pIn = (struct sockaddr_in6 *)&saddr;
        if ( _isLocalhost )
            strlcpy(namebuf, "localhost", INET6_ADDRSTRLEN);
        else
            inet_ntop(AF_INET6, &pIn->sin6_addr, namebuf, INET6_ADDRSTRLEN);
        port = ntohs(pIn->sin6_port);
    }
    else
    {
        return ( nil );
    }
    
    // IPv6 addresses need to be wrapped with [ ]'s to be interpreted correctly within a URL
    if ( saddr.ss_family == AF_INET6 )
        return ( [NSString stringWithFormat: @"[%s]:%hu", namebuf, port] );
    
    return ( [NSString stringWithFormat: @"%s:%hu", namebuf, port] );
}

- (void) setConnectionClass: (Class) connectionClass
{
    if ( connectionClass == Nil || connectionClass == [AQHTTPConnection class] )
    {
        // resetting to the default behaviour.
        _connectionClass = Nil;
        return;
    }
    
    if ( [connectionClass isSubclassOfClass: [AQHTTPConnection class]] )
        _connectionClass = connectionClass;
}

- (void) setDocumentRoot: (NSURL *) documentRoot
{
#if USING_MRR
    NSURL * newURL = [documentRoot copy];
    NSURL * oldURL = _root;
    _root = newURL;
    [oldURL release];
#else
    _root = [documentRoot copy];
#endif
    
    // never propagate nil URLs
    if ( _root == nil )
        return;
    
    for ( AQHTTPConnection * connection in _connections )
    {
        connection.documentRoot = _root;
    }
}

#pragma mark - AQHTTPConnectionDelegate Protocol

- (void) connectionDidClose: (AQHTTPConnection *) connection
{
    [_connections removeObject: connection];
}

@end
