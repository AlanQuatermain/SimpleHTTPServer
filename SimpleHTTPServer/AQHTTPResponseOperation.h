//
//  AQHTTPResponseOperation.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 2012-04-28.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DDRange.h"
#import "AQHTTPConnection.h"
#import "AQSocket.h"

@protocol AQRandomAccessFile, AQHTTPConnection;

/**
 All requests are handled by their own instance of AQHTTPResponseOperation
 or one of its subclasses. Once the HTTP request has been parsed properly,
 it is passed to a new response operation, and that operation is enqueued
 upon a serial queue for in-order processing.
 
 Note that this behaviour *does*
 allow for pipelining of requests: multiple requests can come in and each
 will be responded to FIFO order, with each response completing prior to
 the following response being constructed and sent.
 
 Subclasses can provide an NSInputStream for any response body content,
 and this class will automatically open and read from that stream to send
 its data in the response. This is the preferred method of sending entire
 files.
 
 For ranged requests, any object implementing the AQRandomAccessFile
 protocol can be used to obtain data for the requested range(s).
 */
@interface AQHTTPResponseOperation : NSOperation <NSStreamDelegate>
{
    CFHTTPMessageRef _request;
    AQSocket *_socketRef;
    AQHTTPConnection *_connection;
    BOOL _responseComplete;
    
    // ranged requests
    NSArray *_ranges;
    NSMutableIndexSet *_orderedRanges;
    BOOL _isSingleRange;
}

/**
 Initializes a new response operation.
 
 This is the designated initializer for AQHTTPResponseOperation.
 @param request The parsed HTTP request to which a response is required.
 @param aSocket The communications socket through which to send the response.
 @param ranges If the request specified ranges, this is an array of
 NSValue-wrapped DDRange values specifying those ranges, in the order specified
 by the request.
 @param connection The connection which created this operation.
 Note that this is stored as a strong reference.
 @result Returns a new response operation, ready to be enqueued.
 */
- (id) initWithRequest: (CFHTTPMessageRef) request
                socket: (AQSocket *) aSocket
                ranges: (NSArray *) ranges
         forConnection: (AQHTTPConnection *) connection;

@end

/**
 The methods in this category are intended to be used as-is by subclasses.
 */
@interface AQHTTPResponseOperation (SubclassUsableMethods)

/**
 Writes all data synchronously to the communications socket.
 
 The underlying write process is asynchronous, and uses optimal methods
 to avoid overloading the communications channel's output buffers. This
 method implements a *synthetic synchronous* wrapper around those 
 asynchronous routines to aid in correctly-ordered responses when data
 is being read in discrete chunks (such as from an asynchronous stream).
 
 If this method returns NO, the caller should assume that it is no longer
 possible to send any data as part of this response.
 @param data The data to write.
 @result Returns YES if the data was written, or NO if the communications
 channel encountered an error, or was otherwise unavailable or unable to 
 send the data.
 */
- (BOOL) writeAll: (NSData *) data;

/**
 Calculates a MIME type based on the name of the item at the given
 path.
 
 This method does not look at any file contents, it only makes decisions based
 on the item's filename extension.
 @param rootRelativePath The sub-path from the document root to the item
 requested.
 @result Returns a valid MIME type if one could be mapped based on filename
 extension, or else returns nil.
 */
- (NSString *) contentTypeForItemAtPath: (NSString *) rootRelativePath;

/**
 Creates a HTTP response object for th egiven item with a given status.
 
 Based on the provided status, certain headers may be placed in the response
 for you. Typically it will contain a *Date* header, and for 200-series
 responses will also contain a content type as determined by
 -contentTypeForItemAtPath: (with a fallback of "application/octet-stream").
 
 For 400-series responses for HTML or XHTML files, the returned response will
 include a simple formatted HTML5 document in its body specifying details of
 the error. The correct Content-Type and Content-Length headers will be set in
 this case, and the response can be sent in one pass.
 
 If the request has an If-None-Match header and the receiver also returns a
 non-nil value from the -etagForItemAtPath: method, this method may choose
 to return a 304 Not Modified response instead of a requested 200-series
 response. The caller should check for this by calling
 CFHTTPMessageGetResponseStatusCode() against the returned response.
 @param path The sub-path from the document root to the item requested.
 @param status The HTTP status code for this response.
 @result A new HTTP response object, with some headers and potentially body
 data already set.
 */
- (CFHTTPMessageRef) newResponseForItemAtPath: (NSString *) path
                               withHTTPStatus: (NSUInteger) status;

@end

/**
 The methods in this category are intended to be overridden by subclasses
 to adapt them to each subclass's requirements.
 */
@interface AQHTTPResponseOperation (SubclassOverriddenMethods)

/**
 Returns a valid states code for the given path.
 
 Subclasses can inspect the provided path and determine whether the resource
 can be accessed, returning a status code appropriate for the desired response.
 
 The superclass will always return a status of `404 Not Found`.
 @param rootRelativePath The sub-path below the document root at which the
 requested item resides.
 @result A valid HTTP status code.
 */
- (NSUInteger) statusCodeForItemAtPath: (NSString *) rootRelativePath;

/**
 Returns the size of the requested item.
 @param rootRelativePath The sub-path below the document root at which the
 requested item resides.
 @result The size of the item, or `(UInt64)-1` on failure.
 */
- (UInt64) sizeOfItemAtPath: (NSString *) rootRelativePath;

/**
 Generates an Etag for the given item.
 
 Any valid Etag returned from this method will be placed in the response
 as-is under the Etag header, and may additionally be compared with any 
 If-None-Match header in the request. If these match, a response of 
 304 Not Modified may be returned.
 
 The base class returns nil, at which point no Etag header will be placed in
 the response, and any If-None-Match header in the request will be ignored.
 
 Note that this method may be called multiple times, so if computing the Etag
 is expensive it would be a good idea to cache the result within the operation.
 @param rootRelativePath The sub-path below the document root at which the
 requested item resides.
 @result A valid etag string, or `nil` if no etag could be created, or is not
 desired.
 */
- (NSString *) etagForItemAtPath: (NSString *) rootRelativePath;

/**
 Returns an input stream from which the contents of an item can be read.
 
 This will be used as the primary method of reading from a file when the
 entire file is requested by a HTTP client. If this returns `nil`, the
 -randomAccessFileForItemAtPath: method will be called instead.
 @param rootRelativePath The sub-path below the document root at which the
 requested item resides.
 @result A new, unopened input stream initialized to point at the requested
 item.
 */
- (NSInputStream *) inputStreamForItemAtPath: (NSString *) rootRelativePath;

/**
 Returns an object providing non-sequential access to an item.
 
 The base class will attempt to use this as the primary source of data when
 a HTTP client provides a range in its request, or when 
 -inputStreamForItemAtPath: returns `nil` for a complete file request.
 
 Note that a category on NSFileHandle provides that class with support 
 for the AQRandomAccessFile protocol, so subclasses can return an NSFileHandle
 (or a subclass) in response to this message.
 @param rootRelativePath The sub-path below the document root at which the
 requested item resides.
 @result A new object which conforms to the AQRandomAccessFile protocol.
 */
- (id<AQRandomAccessFile>) randomAccessFileForItemAtPath: (NSString *) rootRelativePath;

@end

/**
 This protocol defines an interface by which data from specific byte ranges
 of a file may be obtained in a synchronous manner.
 */
@protocol AQRandomAccessFile <NSObject>

/**
 Use this method to obtain the size of the file referenced by the receiver.
 @result The size of the file.
 @exception NSInternalInconsistencyException if the file does not have a file
 descriptor, or the file's attributes cannot be obtained.
 */
@property (nonatomic, readonly) UInt64 length;

/**
 Reads the data from a file corresponding to a particular byte range.
 @param range A DDRange (64-bit range object) specifying the location and
 length of the data to read.
 @result The data read from the file at the range specified.
 @exception NSInvalidArgumentException if the supplied range is outside the
 available range of the receiver.
 */
- (NSData *) readDataFromByteRange: (DDRange) range;

@end

/**
 A category on NSFileHandle is provided to make that class compatible with
 the AQRandomAccessFile protocol.
 */
@interface NSFileHandle (AQRandomAccessFileIsSupported) <AQRandomAccessFile>
@end
