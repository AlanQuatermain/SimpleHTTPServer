//
//  AQHTTPConnection.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 12-04-25.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQHTTPConnection.h"
#import "AQSocket/AQSocket.h"
#import "AQSocket/AQSocketReader.h"
#import "AQHTTPRequestOperation.h"
#import "AQHTTPRangedRequestOperation.h"
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
}

@synthesize delegate;

- (id) initWithSocket: (AQSocket *) aSocket documentRoot: (NSURL *) documentRoot
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _documentRoot = documentRoot;
    
    _requestQ = [NSOperationQueue new];
    _requestQ.maxConcurrentOperationCount = 1;
    
    // don't install the event handler until we've got the queue ready: the event handler might be called immediately if data has already arrived.
    _socket = aSocket;
    [self _setEventHandlerOnSocket];
    
    return ( self );
}

- (void) dealloc
{
    if ( _incomingMessage != NULL )
        CFRelease(_incomingMessage);
#if USING_MRR
    [super dealloc];
#endif
}

- (void) close
{
    [_requestQ cancelAllOperations];
    [_socket close];
#if USING_MRR
    [_socket release];
#endif
    _socket = nil;
    
    [self.delegate connectionDidClose: self];
}

- (void) _setEventHandlerOnSocket
{
    __maybe_weak AQHTTPConnection * weakSelf = self;
    _socket.eventHandler = ^(AQSocketEvent event, id info){
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

- (void) _handleIncomingData: (AQSocketReader *) reader
{
    NSLog(@"Data arriving on %p; length=%lu", self, reader.length);
    
    if ( _incomingMessage == NULL )
        _incomingMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);
    
    NSData * data = [reader readBytes: reader.length];
    CFHTTPMessageAppendBytes(_incomingMessage, [data bytes], [data length]);
    
    if ( CFHTTPMessageIsHeaderComplete(_incomingMessage) )
    {
#if 1
        NSString * httpVersion = CFBridgingRelease(CFHTTPMessageCopyVersion(_incomingMessage));
        NSString * httpMethod  = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(_incomingMessage));
        NSURL * url = CFBridgingRelease(CFHTTPMessageCopyRequestURL(_incomingMessage));
        NSDictionary * headers = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(_incomingMessage));
        NSData * body = CFBridgingRelease(CFHTTPMessageCopyBody(_incomingMessage));
        
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
        NSOperation * op = nil;
        
        NSString * rangeHeader = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(_incomingMessage, CFSTR("Range")));
        if ( rangeHeader != nil )
        {
            NSString * path = [(NSURL *)CFBridgingRelease(CFHTTPMessageCopyRequestURL(_incomingMessage)) path];
            path = [[_documentRoot path] stringByAppendingPathComponent: path];
            NSArray * ranges = [self parseRangeRequest: rangeHeader withContentLength: [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL] fileSize]];
            if ( [ranges count] != 0 )
            {
                AQHTTPRangedRequestOperation * rop = [[AQHTTPRangedRequestOperation alloc] initWithRequest: _incomingMessage socket: _socket documentRoot: _documentRoot ranges: ranges];
                rop.connection = self;
                op = rop;
            }
        }
        
        if ( op == nil )
        {
            // the best thing about this approach? It works with pipelining! (well, kinda)
            AQHTTPRequestOperation * rop = [[AQHTTPRequestOperation alloc] initWithRequest: _incomingMessage socket: _socket documentRoot: _documentRoot];
            rop.connection = self;
            op = rop;
        }
        
        [_requestQ addOperation: op];
#if USING_MRR
        [op release];
#endif
        
        CFRelease(_incomingMessage);
        _incomingMessage = NULL;
    }
}

- (void) _socketDisconnected
{
    _socket = nil;
    [self.delegate connectionDidClose: self];
}

- (void) _socketErrorOccurred: (NSError *) error
{
    NSLog(@"Error occurred on socket: %@", error);
    _socket = nil;
    [self.delegate connectionDidClose: self];
}

@end
