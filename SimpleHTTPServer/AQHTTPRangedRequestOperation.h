//
//  AQHTTPRangedRequestOperation.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-26.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AQSocket, AQHTTPConnection;

@interface AQHTTPRangedRequestOperation : NSOperation
- (id) initWithRequest: (CFHTTPMessageRef) request socket: (AQSocket *) theSocket documentRoot: (NSURL *) documentRoot ranges: (NSArray *) ranges;
@property (nonatomic, strong) AQHTTPConnection * connection;
@end
