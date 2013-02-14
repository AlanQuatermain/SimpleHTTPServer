//
//  AQHTTPServer.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AQHTTPConnection.h"

/**
 The AQHTTPServer class implements a small HTTP server instance.
 
 The server is bound to a local address and listens for incoming
 connections. As connections arrive, they are passed to an instance
 of AQHTTPConnection (or a provided subclass) which will then take over
 handling of that connection, receiving and parsing requests and scheduling
 responses to return along the same channel.
 */
@interface AQHTTPServer : NSObject <AQHTTPConnectionDelegate>

/**
 Initialize a server with an address upon which to listen and receive
 new connections.
 
 This is the designated initializer for AQHTTPServer.
 @param address A string DNS address or IPv4/IPv6 address. Alternatively,
 the strings "loopback" and "localhost" will be interpreted as the IPv4
 loopback interface, while "loopback6" and "localhost6" will use the
 IPv6 loopback.
 @param root The URL of a local folder from which all content will be
 served. May be `nil`, at which point a call to setDocumentRoot: will be required
 to make it usable. Without a document root, the server will run but will reject
 all incoming connections.
 @result A new AQHTTPServer instance.
 */
- (id) initWithAddress: (NSString *) address root: (NSURL *) root;

/**
 Start the server running, attempting to open the local port and begin
 listening for incoming connections.
 @param error Upon failure, this value will point to an object describing
 the underlying error. Can be `NULL`.
 @result Returns YES if the connection was bound, NO otherwise.
 */
- (BOOL) start: (NSError **) error;

/**
 Closes down the server and reclaims network resources.
 
 This also stops all in-progress resource requests and responses.
 */
- (void) stop;

/**
 Resets the server, closing down any in-flight requests and responses and re-creating
 the server sockets.
 
 This method is a little more optimized than using -stop and -start: in sequence, and
 will attempt to keep the existing port(s).
 @result Returns `YES` if the existing port numbers were retained on the new sockets,
 `NO` if new port numbers were assigned.
 */
- (BOOL) reset;

/**
 The server's current document root URL.
 
 This can be called while the server is running; existing connections will keep
 the old document root, while new ones will inherit the new. If set to `nil`,
 the server will reject any new incoming connections.
 */
@property (nonatomic, copy) NSURL * documentRoot;

/**
 Returns `YES` if the server is currently running and listening for connections.
 */
@property (nonatomic, readonly, getter=isListening) BOOL listening;

/**
 Provides a custom class to use to manage incoming connections.
 @param connectionClass A class to instantiate to manage new connections
 to the server.
 
 The provided class is expected to be a subclass of AQHTTPConnection. If
 it is not, it will not be used. Passing `Nil` will reset the default
 behaviour of using the AQHTTPConnection class itself.
 */
- (void) setConnectionClass: (Class) connectionClass;

/**
 Returns a string containing the IP and port of the server. This method prefers IPv6
 if available.
 */
@property (nonatomic, readonly) NSString * serverAddress;

@end
