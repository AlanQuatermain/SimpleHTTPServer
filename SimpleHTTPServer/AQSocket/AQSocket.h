//
//  AQSocket.h
//  AQSocket
//
//  Created by Jim Dovey on 11-12-16.
//  Copyright (c) 2011 Jim Dovey Inc. All rights reserved.
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

#import <Foundation/Foundation.h>
#import <sys/socket.h>

// A special reader class where you can check and opt not to read some input
// until *n* bytes are actually available. If you leave some bytes unread,
// the next time data arrives on the socket those bytes will still be available
// to read from the new AQSocketReader instance.
@class AQSocketReader;

typedef enum
{
    AQSocketEventConnected,                 /// info == nil
    AQSocketEventDisconnected,              /// info == nil
    AQSocketEventConnectionFailed,          /// info == NSError
    AQSocketEventAcceptedNewConnection,     /// info == new accepted AQSocket
    AQSocketEventDataAvailable,             /// info == AQSocketReader
    AQSocketErrorEncountered,               /// info == NSError
    
} AQSocketEvent;

typedef enum
{
    AQSocketUnconnected,                    /// The socket is ready to connect but none has yet been initiated.
    AQSocketConnecting,                     /// The socket is waiting for a connection to complete.
    AQSocketListening,                      /// The socket is bound to a local address/port and is waiting to accept new connections.
    AQSocketConnected,                      /// The socket has successfully connected to a remote host and can be used to send and receive data.
    AQSocketDisconnected                    /// The socket has disconnected and is no longer usable.
    
} AQSocketStatus;

/** A block-based event handler. This is called for connection events (for both
 client and server-side sockets) and for incoming data. Note that it does NOT
 advertise writability-- writing happens via a separate, sequenced,
 complete-write API.
 @param event The event which prompted this callback.
 @param info An object containing more information. See AQSocketEvent for information on the info parameter's type for each event.
 */
typedef void (^AQSocketEventHandler)(AQSocketEvent event, id info);

@interface AQSocket : NSObject

/** @name Initializers */

/** The designated initializer. This will always assume the user wants IPv6 or
 IPv4 protocol sockets, the latter provided by an 6to4 wrapper. The caller can
 specify SOCK_STREAM to get a TCP socket or SOCK_DGRAM to use UDP. A destination
 address is not required at this point-- that is provided to one of the connect
 methods specified below, such as connectToAddress:error:.
 @param type A socket type, i.e. SOCK_STREAM for TCP or SOCK_DGRAM for UDP.
 @result A new unconnected AQSocket instance.
 */
- (id) initWithSocketType: (int) type;

/**
 Initializes a new AQSocket instance of type SOCK_STREAM using TCP over
 IPv6 (or 4to6).
 @see initWithSocketType:
 @result A new unconnected AQSocket instance.
 */
- (id) init;

/** @name Properties */

/// The event handler for this socket. Must be set non-zero before the socket can
/// be connected or otherwise used. See AQSocketEventHandler for more discussion.
@property (nonatomic, copy) AQSocketEventHandler eventHandler;

/** @name Connections */

/**
 Connects the socket to its remote server asynchronously, notifying success or
 failure via the installed eventHandler. Should the socket not be configured with
 an event handler yet, or should it already be connected/connecting, then upon
 return the `error` parameter will be initialized to a new autoreleased NSError
 instance containing detailed information.
 @param saddr A socket address structure containing a remote server address.
 @param error If this method returns `NO`, then on return this value contains
 an NSError object detailing the error.
 @result `YES` if the connection initialization takes place, `NO` if something prevented it from doing so.
 */
- (BOOL) connectToAddress: (struct sockaddr *) saddr
                    error: (NSError **) error;

/**
 This method allows the creation of a listening socket, which will accept()
 incoming connection requests on either the loopback interface or the appropriate
 IPv4/IPV6 'any' address. It will choose its own port, which can be obtained using
 the `port` property.
 @param useLoopback If `YES`, bind to the loopback interface. Otherwise, use 'any'.
 @param useIPv6 If `YES`, use the IPv6 protocol rather than IPv4.
 @param error If this method returns `NO`, then on return this value contains
 an NSError object detailing the error.
 @result `YES` if the connection could be bound, `NO` otherwise.
 */
- (BOOL) listenForConnections: (BOOL) useLoopback
                      useIPv6: (BOOL) useIPv6
                        error: (NSError **) error;

/**
 This is a wrapper around connectToAddress:error: which allows
 the caller to pass a DNS hostname to specify the destination for the connection.
 @param hostname The DNS hostname of the server to which to attempt connection.
 @param port The port number to which to connect.
 @param error If this method returns `NO`, then on return this value contains
 an NSError object detailing the error.
 @result Returns `YES` if the async connection attempt began, `NO` otherwise.
 */
- (BOOL) connectToHost: (NSString *) hostname
                  port: (UInt16) port
                 error: (NSError **) error;

/**
 This is a wrapper around connectToAddress:withTimeout:error: which allows
 the caller to pass a numeric IPv4 or IPv6 address to specify the destination
 for the connection.
 @param address The IPv4/6 address of the server to which to attempt connection.
 @param port The port number to which to connect.
 @param error If this method returns `NO`, then on return this value contains
 an NSError object detailing the error.
 @result Returns `YES` if the async connection attempt began, `NO` otherwise.
 */
- (BOOL) connectToIPAddress: (NSString *) address
                       port: (UInt16) port
                      error: (NSError **) error;

/**
 Closes the socket and ceases all handling of input and output.
 */
- (void) close;

/**
 Returns the connection status of the socket.
 @result One of the following values:
    * `AQSocketUnconnected`:
        The socket is ready to connect but none has yet been initiated.
    * `AQSocketConnecting`:
        The socket is waiting for a connection to complete.
    * `AQSocketListening`:
        The socket is bound to a local address/port and is waiting to accept new connections.
    * `AQSocketConnected`:
        The socket has successfully connected to a remote host and can be used to send and receive data.
    * `AQSocketDisconnected`:
        The socket has disconnected and is no longer usable.
 */
@property (nonatomic, readonly) AQSocketStatus status;

/** @name Data Transmission */

/** 
 Writes bytes to the socket. This will enqueue the write to an ordered serial
 queue, and is guaranteed to write everything in a single go, monitoring
 writability states as necessary should it ever encounter a full output buffer at
 the socket level. Should an unrecoverable error occur, the `completionHandler`
 block will be called with an appropriate NSError parameter. Should everything
 write correctly, `completionHandler` will be invoked with a `nil` NSError
 parameter.
 
 Note that error states encountered while writing data will NOT be reported via
 the eventHandler callback block property, only by the `completionHandler` passed
 to this method.
 
 @param bytes The data to write on the socket.
 @param completionHandler A callback method to invoke upon write completion or error.
 
 @exception NSInternalInconsistencyException If the socket is not connected, or is a server-side listening socket.
 */
- (void) writeBytes: (NSData *) bytes
         completion: (void (^)(NSData * unwritten, NSError * error)) completionHandler;

@end
