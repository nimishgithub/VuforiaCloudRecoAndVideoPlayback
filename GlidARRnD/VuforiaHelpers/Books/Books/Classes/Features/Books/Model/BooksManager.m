/*===============================================================================
Copyright (c) 2018 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.
 
Confidential and Proprietary - Protected under copyright and other laws.
Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/


#import "BooksManager.h"
#import "ImagesManager.h"
#import "BooksManagerDelegateProtocol.h"
#import "BookDataParser.h"

@implementation BooksManager

@synthesize cancelNetworkOperation, networkOperationInProgress;
@synthesize badTargets, delegate, bookInfo, thisTrackable;

static const NSString *kBooksJsonURL = @"https://developer.vuforia.com/samples/cloudreco/json";

static BooksManager *sharedInstance = nil;

#pragma mark - Public

-(void)bookWithJSONFilename:(NSString *)jsonFilename withDelegate:(id <BooksManagerDelegateProtocol>)aDelegate forTrackableID:(const char *)trackableID
{
    networkOperationInProgress = YES;
    
    //  Get URL
    NSString *anURLString = [NSString stringWithFormat:@"%@/%@", kBooksJsonURL, jsonFilename];
    NSURL *anURL = [NSURL URLWithString:anURLString];
    
    [self infoForBookAtURL:anURL withDelegate:aDelegate forTrackableID:trackableID];
}

-(void)infoForBookAtURL:(NSURL* )url withDelegate:(id <BooksManagerDelegateProtocol>)aDelegate forTrackableID:(const char*)trackable
{
    // Store the delegate
    delegate = aDelegate;
    
    // Store the trackable ID
    thisTrackable = [[NSString alloc] initWithCString:trackable encoding:NSASCIIStringEncoding];
    
    // Download the book info
    [self asyncDownloadInfoForBookAtURL:url];
}

-(void)asyncDownloadInfoForBookAtURL:(NSURL *)url
{
    // Download the info for this book
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask * downloadTask = [session dataTaskWithURL:url
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

                                                     NSData *dataToShow = data;
                                                     if(error != nil || [self cancelNetworkOperation])
                                                     {
                                                         dataToShow = nil;
                                                     }
                                                     
                                                     [self infoDownloadDidFinishWithBookData: dataToShow];
                                                 }];

    // Start the download task
    [downloadTask resume];
}

-(void)addBadTargetId:(const char*)aTargetId
{
    NSString *tid = [NSString stringWithUTF8String:aTargetId];
    
    if (tid)
    {
        [badTargets addObject:tid];
    }
}

-(BOOL)isBadTarget:(const char*)aTargetId
{
    BOOL retVal = NO;
    NSString *tid = [NSString stringWithUTF8String:aTargetId];
    
    if (tid)
    {
        retVal = [badTargets containsObject:tid];
        
        if (retVal)
        {
            NSLog(@"#DEBUG bad target found");
        }
    }
    else
    {
        NSLog(@"#DEBUG error: could not convert const char * to NSString");
    }
    
    return retVal;
}

-(id)init
{
    self = [super init];
    if (self)
    {
        badTargets = [[NSMutableSet alloc] init];
    }
    return self;
}

+(BooksManager *)sharedInstance
{
	@synchronized(self)
    {
		if (sharedInstance == nil)
        {
			sharedInstance = [[self alloc] init];
		}
	}
	return sharedInstance;
}

-(BOOL)isNetworkOperationInProgress
{
    // The BooksManager or ImagesManager may have a network operation in
    // progress
    return networkOperationInProgress | [[ImagesManager sharedInstance] networkOperationInProgress] ? YES : NO;
}

-(void)cancelNetworkOperations:(BOOL)cancel
{
    // Set or clear the cancel flags, which will be checked in each network
    // callback
    
    // BooksManager (self)
    cancelNetworkOperation = cancel;
    
    // ImagesManager
    [[ImagesManager sharedInstance] setCancelNetworkOperation:cancel];
}

-(void)infoDownloadDidFinishWithBookData:(NSData *)bookData
{
    Book *book = nil;
    
    if (bookData)
    {
        //  Given a NSData, parse the book to a dictionary and then convert it into a Book object
        NSError *anError = nil;
        NSDictionary *bookDictionary = nil;
        
        //  Find out on runtime if the device can use NSJSONSerialization (iOS5 or later)
        NSString *className = @"NSJSONSerialization";
        Class class = NSClassFromString(className);
        
        if (!class)
        {
            //  Use custom BookDataParser.
            //
            //  IMPORTANT: BookDataParser is written to parse data specific to the Books
            //  sample application and is not designed to be used in other applications.
            
            bookDictionary = [BookDataParser parseData:bookData];
            NSLog(@"Using custom JSONBookParser");
        }
        else
        {
            //  Use native JSON parser, NSJSONSerialization
            bookDictionary = [NSJSONSerialization JSONObjectWithData: bookData
                                                             options: NSJSONReadingMutableContainers
                                                               error: &anError];
            NSLog(@"Using NSJSONSerialization");
        }

        
        if (!bookDictionary)
        {
            NSLog(@"Error parsing JSON: %@", anError);
        }
        else
        {
            book = [[Book alloc] initWithDictionary:bookDictionary];
        }
        
        if (nil == bookInfo)
        {
            bookInfo = [[NSMutableData alloc] init];
        }
        
        [bookInfo appendData:bookData];
    }
    
    //  Inform the delegate that the request has completed
    [delegate infoRequestDidFinishForBook:book withTrackableID:[thisTrackable cStringUsingEncoding:NSASCIIStringEncoding] byCancelling:[self cancelNetworkOperation]];
    
    if ([self cancelNetworkOperation])
    {
        // Inform the ImagesManager that the network operation has already been
        // cancelled (so its network operation will not be started and therefore
        // does not need to be cancelled)
        [self cancelNetworkOperations:NO];
    }
    
    // Release objects associated with the completed network operation
    thisTrackable = nil;
    delegate = nil;
    bookInfo = nil;
    
    networkOperationInProgress = NO;
}

@end
