//
//  AQHTTPServer.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPServer.h"
#import "AQSocket.h"

@implementation AQHTTPServer
{
    AQSocket *      _serverSocket4;
    AQSocket *      _serverSocket6;
    NSMutableSet *  _connections;
    
    NSString *      _address;
    NSURL *         _root;
    
    Class           _connectionClass;
}

- (id) initWithAddress: (NSString *) address root: (NSURL *) root
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _address = address;
    _root = root;
    _connections = [NSMutableSet new];
    
    return ( self );
}

- (BOOL) start: (NSError **) error
{
    if ( _serverSocket4 != nil || _serverSocket6 != nil )
        return ( NO );
    
    _serverSocket4 = [[AQSocket alloc] init];
    _serverSocket6 = [[AQSocket alloc] init];
    
    AQHTTPServer * __maybe_weak server = self;
    AQSocketEventHandler handlerBlock = ^(AQSocketEvent event, id info) {
        if ( event != AQSocketEventAcceptedNewConnection )
            return;
        
        NSLog(@"New connection incoming; socket=%@", info);
        
        // ooooh, retain-cycle warnings FTW
        AQHTTPServer * strongServer = server;
        if ( strongServer == nil )
            return;
        
        AQHTTPConnection * newConnection = [[AQHTTPConnection alloc] initWithSocket: info documentRoot: strongServer->_root];
        newConnection.delegate = self;
        [strongServer->_connections addObject: newConnection];
        NSLog(@"Created new connection %@", newConnection);
    };
    
    _serverSocket4.eventHandler = handlerBlock;
    _serverSocket6.eventHandler = handlerBlock;
    
    BOOL useLoopback = ([_address caseInsensitiveCompare: @"loopback"] == NSOrderedSame || [_address caseInsensitiveCompare: @"localhost"] == NSOrderedSame);
    
    if ( [_serverSocket4 listenForConnections: useLoopback useIPv6: NO error: error] == NO )
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
    if ( [_serverSocket6 listenForConnections: useLoopback useIPv6: YES error: &ipv6Error] == NO )
    {
        // drop down to IPv4 only
#if USING_MRR
        [_serverSocket6 release];
#endif
        _serverSocket6 = nil;
    }
    
    return ( YES );
}

- (void) stop
{
    for ( AQHTTPConnection * connection in _connections )
    {
        connection.delegate = nil;      // so we don't get the callback immediately after calling -close
        [connection close];
    }
    
    [_connections removeAllObjects];
    _serverSocket4.eventHandler = nil;
    _serverSocket6.eventHandler = nil;
#if USING_MRR
    [_serverSocket4 release];
    [_serverSocket6 release];
#endif
    _serverSocket4 = nil;
    _serverSocket6 = nil;
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

#pragma mark - AQHTTPConnectionDelegate Protocol

- (void) connectionDidClose: (AQHTTPConnection *) connection
{
    [_connections removeObject: connection];
}

@end
