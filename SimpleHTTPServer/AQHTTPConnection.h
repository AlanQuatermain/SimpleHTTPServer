//
//  AQHTTPConnection.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AQSocket, AQHTTPConnection;

@protocol AQHTTPConnectionDelegate <NSObject>
- (void) connectionDidClose: (AQHTTPConnection *) connection;
@end

@interface AQHTTPConnection : NSObject

- (id) initWithSocket: (AQSocket *) socket documentRoot: (NSURL *) documentRoot;
@property (nonatomic, property_weak) __maybe_weak id<AQHTTPConnectionDelegate> delegate;

- (void) close;

@end
