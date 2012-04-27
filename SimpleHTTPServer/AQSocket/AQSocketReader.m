//
//  AQSocketReader.m
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

#import "AQSocketReader.h"
#import "AQSocketReader+PrivateInternal.h"
#import "AQSocketIOChannel.h"
#import <dispatch/dispatch.h>

#define LOCKED(block) do {                                          \
        dispatch_semaphore_wait(self.lock, DISPATCH_TIME_FOREVER);  \
        @try {                                                      \
            block();                                                \
        } @finally {                                                \
            dispatch_semaphore_signal(self.lock);                   \
        }                                                           \
    } while (0)

@interface AQSocketDispatchDataReader : AQSocketReader
@end

@interface AQSocketReader ()
@property (nonatomic, assign) size_t offset;
@property (nonatomic, readonly) dispatch_semaphore_t lock;
@end

@implementation AQSocketReader
{
    NSMutableData *         _mutableData;
    size_t                  _offset;
    dispatch_semaphore_t    _lock;
}

@synthesize offset=_offset, lock=_lock;

+ (id) allocWithZone: (NSZone *) zone
{
    if ( self == [AQSocketReader class] && dispatch_data_create != 0 )
    {
        return ( [AQSocketDispatchDataReader allocWithZone: zone] );
    }
    
    return ( [super allocWithZone: zone] );
}

- (id) init
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    // By default, it has a NULL dispatch data object, since it's empty to start.
    
    // create a critical section lock
    _lock = dispatch_semaphore_create(1);
    
    return ( self );
}

- (void) dealloc
{
#if DISPATCH_USES_ARC == 0
    if ( _lock != NULL )
    {
        dispatch_release(_lock);
        _lock = NULL;
    }
#endif
#if USING_MRR
    [_mutableData release];
    [super dealloc];
#endif
}

- (NSUInteger) length
{
    return ( [_mutableData length] );
}

- (NSData *) peekBytes: (NSUInteger) count
{
    if ( count == 0 )
        return ( nil );
    
    __block NSData * result = nil;
    LOCKED(^{
        result = [_mutableData subdataWithRange: NSMakeRange(0, MIN(count, [_mutableData length]))];
    });
    
    return ( result );
}

- (NSData *) readBytes: (NSUInteger) count
{
    if ( count == 0 )
        return ( nil );
    
    __block NSData * result = nil;
    LOCKED(^{
        if ( count < [_mutableData length] )
        {
            NSRange r = NSMakeRange(0, count);
            result = [_mutableData subdataWithRange: r];
            [_mutableData replaceBytesInRange: r withBytes: NULL length: 0];
        }
        else
        {
            result = [_mutableData copy];
            [_mutableData setLength: 0];
#if USING_MRR
            [result autorelease];
#endif
        }
    });
    
    return ( result );
}

- (NSInteger) readBytes: (uint8_t *) buffer size: (NSUInteger) bufSize
{
    if ( bufSize == 0 || buffer == NULL )
        return ( 0 );
    
    __block NSInteger copied = 0;
    LOCKED(^{
        copied = MIN(bufSize, [_mutableData length]);
        if ( copied == 0 )
            return;
        
        [_mutableData getBytes: buffer length: bufSize];
        if ( copied == [_mutableData length] )
            [_mutableData setLength: 0];
        else
            [_mutableData replaceBytesInRange: NSMakeRange(0, copied) withBytes: NULL length: 0];
    });
    
    return ( copied );
}

@end

@implementation AQSocketReader (PrivateInternal)

- (void) appendDispatchData: (dispatch_data_t) data
{
    LOCKED(^{
        if ( _mutableData == nil )
            _mutableData = [[NSMutableData alloc] initWithCapacity: dispatch_data_get_size(data)];
        
        // append all regions within the dispatch data
        dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
            [_mutableData appendBytes: buffer length: size];
            return ( true );
        });
    });
}

- (void) appendData: (NSData *) data
{
    LOCKED(^{
        if ( _mutableData == nil )
        {
            _mutableData = [data mutableCopy];
        }
        else
        {
            [_mutableData appendData: data];
        }
    });
}

@end

#pragma mark -

@implementation AQSocketDispatchDataReader
{
    dispatch_data_t         _data;
}

#if DISPATCH_USES_ARC == 0
- (void) dealloc
{
    if ( _data != NULL )
    {
        dispatch_release(_data);
        _data = NULL;
    }
#if USING_MRR
    [super dealloc];
#endif
}
#endif

- (NSUInteger) length
{
    if ( _data == NULL )
        return ( 0 );
    
    // we keep track of an offset to handle full reads of partial data regions
    return ( (NSUInteger)dispatch_data_get_size(_data) - self.offset );
}

- (size_t) _copyBytes: (uint8_t *) buffer length: (size_t) length
{
    __block size_t copied = 0;
    
    // iterate the regions in our data object until we've read `count` bytes
    dispatch_data_apply(_data, ^bool(dispatch_data_t region, size_t off, const void * buf, size_t size) {
        if ( off + self.offset > length )
            return ( false );
        
        // if there's nothing in the output buffer yet, take our global read offset into account
        if ( copied == 0 && self.offset != 0 )
        {
            // tweak all the variables at once, to ease checking later on
            buf = (const void *)((const uint8_t *)buf + self.offset);
            size -= self.offset;
            off += self.offset;
        }
        
        size_t stillNeeded = copied - length;
        size_t sizeToCopy = stillNeeded > size ? size : size - stillNeeded;
        
        if ( sizeToCopy > 0 )
        {
            memcpy(buffer + copied, buf, sizeToCopy);
            copied += sizeToCopy;
        }
        
        // if this region satisfied the read, then cease iteration
        if ( off + size >= length )
            return ( false );
        
        // otherwise, continue on to the next region
        return ( true );
    });
    
    return ( copied );
}

- (void) _removeBytesOfLength: (NSUInteger) length
{
    // NB: this is called while the lock is already held.
    if ( _data == NULL )
        return;
    
    self.offset = self.offset - length;
    
    if ( self.length == length )
    {
#if DISPATCH_USES_ARC == 0
        dispatch_release(_data);
#endif
        _data = NULL;
        return;
    }
    
    // simple version: just create a subrange data object
    dispatch_data_t newData = dispatch_data_create_subrange(_data, length, self.length - length);
    if ( newData == NULL )
        return;     // ARGH!
#if DISPATCH_USES_ARC == 0
    dispatch_release(_data);
#endif
    _data = newData;
}

- (NSData *) peekBytes: (NSUInteger) count
{
    if ( _data == NULL )
        return ( nil );
    
    NSMutableData * result = [NSMutableData dataWithCapacity: count];
    LOCKED(^{
        [self _copyBytes: (uint8_t *)[result mutableBytes]
                  length: count];
    });
	
	return ( result );
}

- (NSData *) readBytes: (NSUInteger) count
{
    if ( _data == NULL )
        return ( nil );
    
    NSMutableData * result = [NSMutableData dataWithLength: count];
    
    LOCKED(^{
        size_t copied = [self _copyBytes: (uint8_t*)[result mutableBytes]
                                  length: count];
        [result setLength: copied];
        self.offset = self.offset + copied;
        
        // adjust content parameters while the lock is still held
        [self _removeBytesOfLength: copied];
    });
	
	return ( result );
}

- (NSInteger) readBytes: (uint8_t *) buffer size: (NSUInteger) bufSize
{
    if ( _data == NULL )
        return ( 0 );
    
    __block NSInteger numRead = 0;
    LOCKED(^{
        numRead = [self _copyBytes: buffer length: bufSize];
        [self _removeBytesOfLength: bufSize];
    });
	
	return ( numRead );
}

@end

@implementation AQSocketDispatchDataReader (PrivateInternal)

- (void) appendDispatchData: (dispatch_data_t) appendedData
{
    LOCKED(^{
        if ( _data == NULL )
        {
#if DISPATCH_USES_ARC == 0
            dispatch_retain(appendedData);
#endif
            _data = appendedData;
        }
        else
        {
            dispatch_data_t newData = dispatch_data_create_concat(_data, appendedData);
            if ( newData != NULL )
            {
#if DISPATCH_USES_ARC == 0
                dispatch_release(_data);
#endif
                _data = newData;
            }
        }
    });
}

- (void) appendData: (NSData *) data
{
    if ( [data length] == 0 )
        return;
    
    if ( [data isKindOfClass: [_AQDispatchData class]] )
    {
        _AQDispatchData * __data = (_AQDispatchData *)data;
        dispatch_data_t ddata = [__data _aq_getDispatchData];
        [self appendDispatchData: ddata];
        return;
    }
    
    // Ensure we have an immutable data object. If it's already immutable, this -copy just does -retain.
    NSData * dataCopy = [data copy];
    dispatch_data_t ddata = dispatch_data_create([dataCopy bytes], [dataCopy length], dispatch_get_main_queue(), ^{
#if USING_MRR
        [dataCopy release];
#endif
    });
    
    if ( ddata == NULL )
        return;
    
    [self appendDispatchData: ddata];
#if DISPATCH_USES_ARC == 0
    dispatch_release(ddata);
#endif
}

@end
