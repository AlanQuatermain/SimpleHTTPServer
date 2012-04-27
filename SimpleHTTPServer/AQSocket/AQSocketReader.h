//
//  AQSocketReader.h
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

#import <Foundation/Foundation.h>

/// A special reader class where you can check and opt not to read some input
/// until *n* bytes are actually available. If you leave some bytes unread,
/// the next time data arrives on the socket those bytes will still be available
/// to read from the new AQSocketReader instance.
@interface AQSocketReader : NSObject

/// Returns the total number of bytes available to read at this time.
@property (nonatomic, readonly) NSUInteger length;

/**
 Peeks at a number of available bytes. This method does not actually remove
 the returned bytes from any protocol buffers, so they will still be returned
 from a succeeding call to -readBytes: or -readBytes:size:.
 @param count The number of bytes at which to peek.
 @return An NSData object containing the peeked-at bytes, or `nil`.
 */
- (NSData *) peekBytes: (NSUInteger) count;

/**
 Reads a number of bytes of data, removing them from the protocol buffers.
 @param count The number of bytes to read.
 @return An NSData object containing the read bytes, or `nil`.
 */
- (NSData *) readBytes: (NSUInteger) count;

/**
 Reads a number of bytes of data into a caller-supplied buffer.
 @param buffer A pre-allocated buffer of at least `bufSize` bytes.
 @param bufSize The number of bytes allocated in `buffer`.
 @return The number of bytes copied into `buffer`.
 */
- (NSInteger) readBytes: (uint8_t *) buffer size: (NSUInteger) bufSize;

@end
