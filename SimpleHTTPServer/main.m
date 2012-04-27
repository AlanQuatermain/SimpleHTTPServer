//
//  main.m
//  SimpleHTTPServer
//
//  Created by Jim Dovey on 2012-04-24.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <getopt.h>
#import <sysexits.h>
#import <asl.h>

#import "AQHTTPServer.h"

static const char *gVersionNumber = "1.0";

aslclient gASLClient = NULL;

static const char *		_shortCommandLineArgs = "hvda:r:";
static struct option	_longCommandLineArgs[] = {
	{ "help", no_argument, NULL, 'h' },
	{ "version", no_argument, NULL, 'v' },
	{ "debug", no_argument, NULL, 'd' },
    { "address", required_argument, NULL, 'a' },
    { "webroot", required_argument, NULL, 'r' },
	{ NULL, 0, NULL, 0 }
};

static void usage(FILE *fp)
{
    NSString * usageStr = [[NSString alloc] initWithFormat: @"Usage: %@ [OPTIONS] [ARGUMENTS]\n"
                           @"\n"
                           @"Options:\n"
                           @"  -h, --help         Display this information.\n"
                           @"  -v, --version      Display the version number.\n"
                           @"  -d, --debug        Enable debugging output.\n"
                           @"\n"
                           @"Arguments:\n"
                           @"  -a, --address      The address on which to listen. Can be IPv4, IPv6, or a name.\n"
                           @"  -r, --webroot      The path of a folder from which to serve content.\n"
                           @"\n", [[NSProcessInfo processInfo] processName]];
    fprintf(fp, "%s", [usageStr UTF8String]);
#if USING_MRR
    [usageStr release];
#endif
    fflush(fp);
}

static void version(FILE *fp)
{
    fprintf(fp, "%s: version %s\n", [[[NSProcessInfo processInfo] processName] UTF8String], gVersionNumber);
    fflush(fp);
}

int main(int argc, char * const argv[])
{
    gASLClient = asl_open("me.alanquatermain.SimpleHTTPServer", "SimpleHTTPServer", ASL_OPT_NO_DELAY);
    
    @autoreleasepool
    {
        int ch = 0;
        NSString * address = nil;
        NSString * root = nil;
        
        @try
        {
            while ((ch = getopt_long(argc, argv, _shortCommandLineArgs, _longCommandLineArgs, NULL)) != -1)
            {
                switch ( ch )
                {
                    case 'h':
                        usage(stdout);
                        exit(EX_OK);
                        break;
                        
                    case 'v':
                        version(stdout);
                        exit(EX_OK);
                        break;
                        
                    case 'd':
                        asl_close(gASLClient);
                        uint32_t opts = ASL_OPT_NO_DELAY|ASL_OPT_NO_REMOTE;
                        if ( isatty(STDERR_FILENO) )
                            opts |= ASL_OPT_STDERR;
                        gASLClient = asl_open("me.alanquatermain.SimpleHTTPServer", "SimpleHTTPServer", opts);
                        asl_set_filter(gASLClient, ASL_FILTER_MASK_UPTO(ASL_LEVEL_DEBUG));
                        break;
                        
                    case 'a':
                        if (optarg == NULL)
                        {
                            usage(stderr);
                            exit(EX_USAGE);
                        }
                        
                        address = [NSString stringWithUTF8String: optarg];
                        break;
                        
                    case 'r':
                        if (optarg == NULL)
                        {
                            usage(stderr);
                            exit(EX_USAGE);
                        }
                        
                        root = [NSString stringWithUTF8String: optarg];
                        break;
                        
                    default:
                        usage(stderr);
                        exit(EX_USAGE);
                        break;
                }
            }
        }
        @catch (NSException *e)
        {
            fprintf(stderr, "Caught %s while parsing command-line arguments: %s", [[e name] UTF8String], [[e reason] UTF8String]);
            exit(EX_OSERR);
        }
        
        if ( address == nil || root == nil )
        {
            fprintf(stderr, "You must specify an address and a root path.\n");
            usage(stderr);
            exit(EX_USAGE);
        }
        
        AQHTTPServer * server = [[AQHTTPServer alloc] initWithAddress: address root: [NSURL fileURLWithPath: root]];
        NSError * error = nil;
        if ( [server start: &error] == NO )
        {
            NSLog(@"Error starting server: %@", error);
            exit(EX_OSERR);
        }
        
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{
            CFRunLoopStop(CFRunLoopGetCurrent());
        });
        
        CFRunLoopRun();
        
        [server stop];
    }
    
    return ( EX_OK );
}

