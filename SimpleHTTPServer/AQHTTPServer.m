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
    AQSocket *      _serverSocket;
    NSMutableSet *  _connections;
    
    NSString *      _address;
    NSURL *         _root;
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
    if ( _serverSocket != nil )
        return ( NO );
    
    _serverSocket = [[AQSocket alloc] init];
    
    AQHTTPServer * __maybe_weak server = self;
    _serverSocket.eventHandler = ^(AQSocketEvent event, id info) {
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
    
    BOOL useLoopback = ([_address caseInsensitiveCompare: @"loopback"] == NSOrderedSame || [_address caseInsensitiveCompare: @"localhost"] == NSOrderedSame);
    return ( [_serverSocket listenForConnections: useLoopback error: error] );
}

- (void) stop
{
    for ( AQHTTPConnection * connection in _connections )
    {
        connection.delegate = nil;      // so we don't get the callback immediately after calling -close
        [connection close];
    }
    
    [_connections removeAllObjects];
    _serverSocket.eventHandler = nil;
    _serverSocket = nil;
}

#pragma mark - AQHTTPConnectionDelegate Protocol

- (void) connectionDidClose: (AQHTTPConnection *) connection
{
    [_connections removeObject: connection];
}

@end
