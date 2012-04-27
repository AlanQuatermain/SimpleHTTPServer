//
//  AQHTTPServer.h
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AQHTTPConnection.h"

@interface AQHTTPServer : NSObject <AQHTTPConnectionDelegate>
- (id) initWithAddress: (NSString *) address root: (NSURL *) root;
- (BOOL) start: (NSError **) error;
- (void) stop;
@end
