//
//  AQSocketIOChannel.h
//  AQSocket
//
//  Created by Jim Dovey on 2012-04-24.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AQSocketReader.h"

@interface AQSocketIOChannel : NSObject
{
    CFSocketNativeHandle _nativeSocket;
    dispatch_queue_t _q;        // a serial queue upon which notifiers will be enqueued for rigidly serialized calls
    void (^_cleanupHandler)(void);
    void (^_readHandler)(NSData *, NSError *);
}
- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler;
- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData * unsentData, NSError *error)) completion;
@property (nonatomic, copy) void (^readHandler)(NSData *data, NSError *error);
- (void) close;
@end

// A sly little NSData class simplifying the dispatch_data_t -> NSData transition.
@interface _AQDispatchData : NSData
{
    dispatch_data_t _ddata;
    const void *    _buf;
    size_t          _len;
}
- (id) initWithDispatchData: (dispatch_data_t) ddata;
- (dispatch_data_t) _aq_getDispatchData;
@end
