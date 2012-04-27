//
//  AQHTTPRequestOperation.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AQSocket.h"
#import "AQHTTPConnection.h"

@interface AQHTTPRequestOperation : NSOperation <NSStreamDelegate>
- (id) initWithRequest: (CFHTTPMessageRef) request socket: (AQSocket *) theSocket documentRoot: (NSURL *) documentRoot;
@property (nonatomic, strong) AQHTTPConnection * connection;
@end
