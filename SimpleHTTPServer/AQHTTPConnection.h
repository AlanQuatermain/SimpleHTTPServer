//
//  AQHTTPConnection.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AQSocket, AQHTTPConnection, AQHTTPResponseOperation;

@protocol AQHTTPConnectionDelegate <NSObject>
- (void) connectionDidClose: (AQHTTPConnection *) connection;
@end

/**
 The AQHTTPConnection class is used to keep track of individual
 connections established by HTTP clients.
 
 Each connection refers to a single connection; this typically means
 a single request, but if the client requests keepalive then the 
 connection will usually be kept around until the client closes its
 end of the communications channel, to allow for pipelining or the
 handling of multiple requests.
 
 This class by itself does not keep hold of any resources beyond the
 communications channel itself. It may be subclassed if other resources
 should be maintained for a single connection or series of requests.
 One example would be a connection which is serving documents from an
 archive file of some kind; in that case, the connection object would
 likely want to keep an open reference to the archive itself.
 */
@interface AQHTTPConnection : NSObject

/**
 Initializes a new HTTP connection/request handler.
 
 This is the designated initializer for AQHTTPConnection.
 @param socket A connected communications socket for this connection.
 @param documentRoot A URL describing the root location of the server's
 documents.
 @result A new AQHTTPConnection instance.
 */
- (id) initWithSocket: (AQSocket *) socket documentRoot: (NSURL *) documentRoot;

/**
 Sets the delegate for this connection.
 
 Where supported by the Objective-C runtime, the delegate is
 weakly-referenced.
 */
@property (nonatomic, property_weak) __maybe_weak id<AQHTTPConnectionDelegate> delegate;

/**
 Returns the URL specifying the document root of the webserver.
 @see initWithSocket:documentRoot: for more information.
 */
@property (nonatomic, readonly) NSURL *documentRoot;

/**
 Closes the connection, cancelling any responses whether queued or in-flight.
 */
- (void) close;

/**
 The default value for this is `YES`. If a subclass does something which
 prevents the default pipeline-able behaviour (see AQHTTPResponse for 
 details) then that subclass should return `NO` from here to ensure that
 the connection is closed following a response and no re-used.
 */
@property (nonatomic, readonly) BOOL supportsPipelinedRequests;

/**
 This method will parse a request's Range header into an array of ranges.
 
 The array returned will contain exactly the ranges specified in the request,
 in the same order they occurred. It will not unify or sort them.
 
 Subclasses can call this method in their implementation of
 responseOperationForRequest: to parse out any Range headers within that
 request.
 
 This method is based on code from HTTPConnection in
 [CocoaHTTPServer](http://github.com/robbiehanson/CocoaHTTPServer)
 @param rangeHeader The value of the Range header from a HTTP request.
 @param contentLength The size of the file referenced by the request.
 @result An array containing NSValue-wrapped DDRange (64-bit NSRange) objects.
 */
- (NSArray *) parseRangeRequest: (NSString *) rangeHeader
              withContentLength: (UInt64) contentLength;

/**
 Returns a response operation suitable for handling the request
 provided.
 
 Subclasses can override this to provide responses which deal with their
 particular data storage/transmission setups.
 */
- (AQHTTPResponseOperation *) responseOperationForRequest: (CFHTTPMessageRef) request;

@end
