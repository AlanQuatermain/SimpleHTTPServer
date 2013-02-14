//
//  AQHTTPConnection.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPConnection.h"
#import "AQHTTPConnection_PrivateInternal.h"
#import "AQHTTPServer.h"
#import "AQSocket.h"
#import "AQSocketReader.h"
#import "AQHTTPFileResponseOperation.h"
#import "DDRange.h"
#import "DDNumber.h"

@interface AQHTTPConnection ()
- (void) _setEventHandlerOnSocket;
- (void) _handleIncomingData: (AQSocketReader *) reader;
- (void) _socketDisconnected;
- (void) _socketErrorOccurred: (NSError *) error;
@end

@implementation AQHTTPConnection
{
    // a serial, cancellable queue
    NSOperationQueue *_requestQ;
    
    AQSocket * _socket;
    NSURL * _documentRoot;
    CFHTTPMessageRef _incomingMessage;
    
    NSTimer *   _idleDisconnectionTimer;
    
    AQHTTPServer * __maybe_weak _server;
}

@synthesize delegate, documentRoot=_documentRoot, socket=_socket, server=_server;

- (id) initWithSocket: (AQSocket *) aSocket documentRoot: (NSURL *) documentRoot forServer: (AQHTTPServer *) server
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _documentRoot = [documentRoot copy];
    _server = server;       // weak/unsafe reference
    
    _requestQ = [NSOperationQueue new];
    _requestQ.maxConcurrentOperationCount = 1;
    
    // don't install the event handler until we've got the queue ready: the event handler might be called immediately if data has already arrived.
    _socket = aSocket;
#if USING_MRR
    [_socket retain];
#endif
    
    // we need to wait for subclass initialization to complete before we install our event handlers
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        [self _setEventHandlerOnSocket];
    });
    
    return ( self );
}

- (void) dealloc
{
    if ( _incomingMessage != NULL )
        CFRelease(_incomingMessage);
    _socket.eventHandler = nil;
#if USING_MRR
    [_documentRoot release];
    [_socket release];
    [_requestQ release];
    [super dealloc];
#endif
}

- (void) close
{
    [_requestQ cancelAllOperations];
    [_socket close];
    _socket.eventHandler = nil;
#if USING_MRR
    [_socket release];
#endif
    _socket = nil;
    
    [self.delegate connectionDidClose: self];
}

- (void) setDocumentRoot: (NSURL *) documentRoot
{
    dispatch_block_t setterBody = ^{
#if USING_MRR
        NSURL * newValue = [documentRoot copy];
        NSURL * oldValue = _documentRoot;
        _documentRoot = newValue;
        [oldValue release];
#else
        _documentRoot = [documentRoot copy];
#endif
        [self documentRootDidChange];
    };
    
    if ( [_requestQ operationCount] != 0 )
    {
        // wait until the in-flight operations have completed before updating the value
        [[[_requestQ operations] lastObject] setCompletionBlock: setterBody];
        return;
    }
    
    // otherwise, we can go ahead and do it now
    setterBody();
}

- (void) _setEventHandlerOnSocket
{
    __maybe_weak AQHTTPConnection * weakSelf = self;
    _socket.eventHandler = ^(AQSocketEvent event, id info){
#if DEBUGLOG
        NSLog(@"Socket event occurred: %d (%@)", event, info);
#endif
        AQHTTPConnection * strongSelf = weakSelf;
        switch ( event )
        {
            case AQSocketEventDataAvailable:
                [strongSelf _handleIncomingData: info];
                break;
                
            case AQSocketEventDisconnected:
                [strongSelf _socketDisconnected];
                break;
                
            case AQSocketErrorEncountered:
                [strongSelf _socketErrorOccurred: info];
                break;
                
            default:
                break;
        }
    };
}

- (BOOL) supportsPipelinedRequests
{
    return ( YES );
}

- (NSArray *) parseRangeRequest:(NSString *)rangeHeader withContentLength:(UInt64)contentLength
{
//	HTTPLogTrace();
	
	// Examples of byte-ranges-specifier values (assuming an entity-body of length 10000):
	// 
	// - The first 500 bytes (byte offsets 0-499, inclusive):  bytes=0-499
	// 
	// - The second 500 bytes (byte offsets 500-999, inclusive): bytes=500-999
	// 
	// - The final 500 bytes (byte offsets 9500-9999, inclusive): bytes=-500
	// 
	// - Or bytes=9500-
	// 
	// - The first and last bytes only (bytes 0 and 9999):  bytes=0-0,-1
	// 
	// - Several legal but not canonical specifications of the second 500 bytes (byte offsets 500-999, inclusive):
	// bytes=500-600,601-999
	// bytes=500-700,601-999
	//
	
	NSRange eqsignRange = [rangeHeader rangeOfString:@"="];
	
	if(eqsignRange.location == NSNotFound) return nil;
	
	NSUInteger tIndex = eqsignRange.location;
	NSUInteger fIndex = eqsignRange.location + eqsignRange.length;
	
	NSMutableString *rangeType  = [[rangeHeader substringToIndex:tIndex] mutableCopy];
	NSMutableString *rangeValue = [[rangeHeader substringFromIndex:fIndex] mutableCopy];
#if USING_MRR
    [rangeType autorelease];
    [rangeValue autorelease];
#endif
	
	CFStringTrimWhitespace((__bridge CFMutableStringRef)rangeType);
	CFStringTrimWhitespace((__bridge CFMutableStringRef)rangeValue);
	
	if([rangeType caseInsensitiveCompare:@"bytes"] != NSOrderedSame) return nil;
	
	NSArray *rangeComponents = [rangeValue componentsSeparatedByString:@","];
	
	if([rangeComponents count] == 0) return nil;
	
	NSMutableArray * ranges = [[NSMutableArray alloc] initWithCapacity:[rangeComponents count]];
#if USING_MRR
    [ranges autorelease];
#endif
	
	// Note: We store all range values in the form of DDRange structs, wrapped in NSValue objects.
	// Since DDRange consists of UInt64 values, the range extends up to 16 exabytes.
	
	NSUInteger i;
	for (i = 0; i < [rangeComponents count]; i++)
	{
		NSString *rangeComponent = [rangeComponents objectAtIndex:i];
		
		NSRange dashRange = [rangeComponent rangeOfString:@"-"];
		
		if (dashRange.location == NSNotFound)
		{
			// We're dealing with an individual byte number
			
			UInt64 byteIndex;
			if(![NSNumber parseString:rangeComponent intoUInt64:&byteIndex]) return nil;
			
			if(byteIndex >= contentLength) return nil;
			
			[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(byteIndex, 1)]];
		}
		else
		{
			// We're dealing with a range of bytes
			
			tIndex = dashRange.location;
			fIndex = dashRange.location + dashRange.length;
			
			NSString *r1str = [rangeComponent substringToIndex:tIndex];
			NSString *r2str = [rangeComponent substringFromIndex:fIndex];
			
			UInt64 r1, r2;
			
			BOOL hasR1 = [NSNumber parseString:r1str intoUInt64:&r1];
			BOOL hasR2 = [NSNumber parseString:r2str intoUInt64:&r2];
			
			if (!hasR1)
			{
				// We're dealing with a "-[#]" range
				// 
				// r2 is the number of ending bytes to include in the range
				
				if(!hasR2) return nil;
				if(r2 > contentLength) return nil;
				
				UInt64 startIndex = contentLength - r2;
				
				[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(startIndex, r2)]];
			}
			else if (!hasR2)
			{
				// We're dealing with a "[#]-" range
				// 
				// r1 is the starting index of the range, which goes all the way to the end
				
				if(r1 >= contentLength) return nil;
				
				[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(r1, contentLength - r1)]];
			}
			else
			{
				// We're dealing with a normal "[#]-[#]" range
				// 
				// Note: The range is inclusive. So 0-1 has a length of 2 bytes.
				
				if(r1 > r2) return nil;
				if(r2 >= contentLength) return nil;
				
				[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(r1, r2 - r1 + 1)]];
			}
		}
	}
	
	if([ranges count] == 0) return nil;
    
    // NB: no sorting or combining-- that's being done later
	
	return [NSArray arrayWithArray: ranges];
}

- (void) _maybeInstallIdleTimer
{
    if ( [_requestQ operationCount] != 0 )
        return;
    
    if ( _idleDisconnectionTimer != nil )
        return;
    
    _idleDisconnectionTimer = [[NSTimer alloc] initWithFireDate: [NSDate dateWithTimeIntervalSinceNow: 2.0]
                                                       interval: 2.0
                                                         target: self
                                                       selector: @selector(_checkIdleTimer:)
                                                       userInfo: nil
                                                        repeats: NO];
    [[NSRunLoop mainRunLoop] addTimer: _idleDisconnectionTimer forMode: NSRunLoopCommonModes];
}

- (void) _checkIdleTimer: (NSTimer *) timer
{
    if ( [_requestQ operationCount] != 0 )
        return;
    
    // disconnect due to under-utilization
    [self close];
}

- (AQHTTPResponseOperation *) responseOperationForRequest: (CFHTTPMessageRef) request
{
    NSString * rangeHeader = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
    NSArray * ranges = nil;
    if ( rangeHeader != nil )
    {
        NSString * path = [(NSURL *)CFBridgingRelease(CFHTTPMessageCopyRequestURL(request)) path];
        path = [[_documentRoot path] stringByAppendingPathComponent: path];
        ranges = [self parseRangeRequest: rangeHeader withContentLength: [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL] fileSize]];
    }
    
    // the best thing about this approach? It works with pipelining!
    AQHTTPFileResponseOperation * op = [[AQHTTPFileResponseOperation alloc] initWithRequest: request socket: _socket ranges: ranges forConnection: self];
#if USING_MRR
    [op autorelease];
#endif
    return ( op );
}

- (void) _handleIncomingData: (AQSocketReader *) reader
{
#if DEBUGLOG
    NSLog(@"Data arriving on %p; length=%lu", self, (unsigned long)reader.length);
#endif
    
    CFHTTPMessageRef msg = NULL;
    if ( _incomingMessage != NULL )
        msg = (CFHTTPMessageRef)CFRetain(_incomingMessage);
    else
        msg = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);
    
    NSData * data = [reader readBytes: reader.length];
    CFHTTPMessageAppendBytes(msg, [data bytes], [data length]);
    
    if ( CFHTTPMessageIsHeaderComplete(msg) )
    {
        if ( _incomingMessage == msg && _incomingMessage != NULL )
        {
            CFRelease(_incomingMessage);
            _incomingMessage = NULL;
        }
        
#if DEBUGLOG
        NSString * httpVersion = CFBridgingRelease(CFHTTPMessageCopyVersion(msg));
        NSString * httpMethod  = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(msg));
        NSURL * url = CFBridgingRelease(CFHTTPMessageCopyRequestURL(msg));
        NSDictionary * headers = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(msg));
        NSData * body = CFBridgingRelease(CFHTTPMessageCopyBody(msg));
        
        NSMutableString * debugStr = [NSMutableString string];
        [debugStr appendFormat: @"%@ %@ \"%@\"\n", httpVersion, httpMethod, [url absoluteString]];
        [headers enumerateKeysAndObjectsUsingBlock: ^(id key, id obj, BOOL *stop) {
            [debugStr appendFormat: @"%@: %@\n", key, obj];
        }];
        if ( [body length] != 0 )
        {
            NSString * bodyStr = [[NSString alloc] initWithData: body encoding: NSUTF8StringEncoding];
            [debugStr appendFormat: @"\n%@\n", bodyStr];
#if USING_MRR
            [bodyStr release];
#endif
        }
        
        NSLog(@"Incoming request:\n%@", debugStr);
#endif
        AQHTTPResponseOperation * op = [self responseOperationForRequest: msg];
        if ( op != nil )
        {
            [op setCompletionBlock: ^{ [self _maybeInstallIdleTimer]; }];
            if ( [_idleDisconnectionTimer isValid] )
            {
                [_idleDisconnectionTimer invalidate];
#if USING_MRR
                [_idleDisconnectionTimer release];
#endif
                _idleDisconnectionTimer = nil;
            }
            
            [_requestQ addOperation: op];
        }
    }
    else
    {
        _incomingMessage = (CFHTTPMessageRef)CFRetain(msg);
    }
    
    if (msg != NULL)
        CFRelease(msg);
}

- (void) _socketDisconnected
{
#if USING_MRR
    AQSocket * tmp = [_socket retain];
    [self close];
    [tmp release];
#else
    [self close];
#endif
}

- (void) _socketErrorOccurred: (NSError *) error
{
#if DEBUGLOG
    NSLog(@"Error occurred on socket: %@", error);
#endif
#if USING_MRR
    AQSocket * tmp = [_socket retain];
    [self close];
    [tmp release];
#else
    [self close];
#endif
}

@end
