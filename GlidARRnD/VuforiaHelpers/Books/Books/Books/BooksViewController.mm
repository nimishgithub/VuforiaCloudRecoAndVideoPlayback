/*===============================================================================
Copyright (c) 2016-2018 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import "BooksViewController.h"
#import "BooksManager.h"
#import "BookWebDetailViewController.h"
#import "TargetOverlayView.h"

#import <Vuforia/Vuforia.h>
#import <Vuforia/TrackerManager.h>
#import <Vuforia/ObjectTracker.h>
#import <Vuforia/ImageTarget.h>
#import <Vuforia/DataSet.h>
#import <Vuforia/CameraDevice.h>
#import <Vuforia/TargetFinder.h>
#import <Vuforia/TargetSearchResult.h>
#import <GlidARRnD-Swift.h>



// ----------------------------------------------------------------------------
// Credentials for authenticating with the Books service
// These are read-only access keys for accessing the image database
// specific to this sample application - the keys should be replaced
// by your own access keys. You should be very careful how you share
// your credentials, especially with untrusted third parties, and should
// take the appropriate steps to protect them within your application code
// ----------------------------------------------------------------------------

static const char* const kAccessKey = "b3b58819edccca17755cfcae95ea0f40c0eaa0da"; //default
static const char* const kSecretKey = "4f2358936188b461ad608e50a82c1593d55cfeb0";
//static const char* const kAccessKey = "7ccef2730b1f8fee9794ed2138f01d72a23d8be2";
//static const char* const kSecretKey = "bd6348f3edddcc7ca27ef0d60c3ad77523e74958";


@interface BooksViewController ()

//@property (weak, nonatomic) IBOutlet UIImageView *ARViewPlaceholder;
@property (nonatomic) BOOL isShowingWebDetail;
@property (nonatomic) BOOL pausedWhileShowingBookWebDetail;
@property (nonatomic) BOOL scanningMode;
@property (nonatomic) BOOL isVisualSearchOn;

@end

@implementation BooksViewController

@synthesize tapGestureRecognizer, vapp, eaglView, bookOverlayController;
@synthesize lastScannedBook, lastTargetIDScanned;
@synthesize isShowingWebDetail, pausedWhileShowingBookWebDetail, scanningMode, isVisualSearchOn;
@synthesize mTargetFinder;

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (lastTargetIDScanned != nil)
    {
        lastTargetIDScanned = nil;
    }
    
    if (lastScannedBook != nil)
    {
        lastScannedBook = nil;
    }
    
//    if (bookOverlayController)
//    {
//        [bookOverlayController killTimer];
//        bookOverlayController = nil;
//    }
}

- (NSString *) lastTargetIDScanned
{
    return lastTargetIDScanned;
}

- (void) setLastTargetIDScanned:(NSString *) targetId
{
    if (lastTargetIDScanned != nil)
    {
        lastTargetIDScanned = nil;
    }
    
    if (targetId != nil)
    {
        lastTargetIDScanned = [NSString stringWithString:targetId];
    }
}


- (void) setLastScannedBook: (Book *) book {
    if (lastScannedBook != nil)
    {
        lastScannedBook = nil;
    }
    
    if (book != nil)
    {
        lastScannedBook = book;
    }
}


- (BOOL) isVisualSearchOn
{
    return isVisualSearchOn;
}

- (void) setVisualSearchOn:(BOOL) isOn
{
    isVisualSearchOn = isOn;
    
    if (isOn)
    {
        [self scanlineStart];
    }
    else
    {
        [self scanlineStop];
    }
}


- (CGRect)getCurrentARViewFrame
{
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGRect viewFrame = screenBounds;
    
    // If this device has a retina display, scale the view bounds
    // for the AR (OpenGL) view
    if (YES == vapp.isRetinaDisplay)
    {
        viewFrame.size.width *= [UIScreen mainScreen].nativeScale;
        viewFrame.size.height *= [UIScreen mainScreen].nativeScale;
    }
    return viewFrame;
}

- (void)loadView
{
    // Custom initialization
    self.title = @"Books";
    
    /*if (self.ARViewPlaceholder != nil)
    {
        [self.ARViewPlaceholder removeFromSuperview];
        self.ARViewPlaceholder = nil;
    }*/
    
    mFullScreenPlayerPlaying = NO;
    mPlayFullscreenEnabled = NO;
    
    pausedWhileShowingBookWebDetail = NO;
    isShowingWebDetail = NO;
    scanningMode = YES;
    isVisualSearchOn = NO;
    lastScannedBook = nil;
    lastTargetIDScanned = nil;
    
    vapp = [[SampleApplicationSession alloc] initWithDelegate:self];
    
    CGRect viewFrame = [self getCurrentARViewFrame];
    
//    bookOverlayController = [[BooksOverlayViewController alloc] initWithDelegate:self];
    eaglView = [[BooksEAGLView alloc] initWithFrame:viewFrame delegate:self appSession:vapp];
    [eaglView setBackgroundColor:UIColor.clearColor];
//    [eaglView addSubview:bookOverlayController.view];
    [self setView: eaglView];
    [AppDelegate shared].glResourceHandler = eaglView;
    
    // a single tap will trigger a single autofocus operation
    tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGestureRecognizer.delegate = self;
    
    [self scanlineCreate];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dismissARViewController)
                                                 name:@"kDismissARViewController"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bookWebDetailDismissed:) name:@"kBookWebDetailDismissed" object:nil];
    
    // we use the iOS notification to pause/resume the AR when the application goes (or come back from) background
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(pauseAR)
     name:UIApplicationWillResignActiveNotification
     object:nil];
    
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(resumeAR)
     name:UIApplicationDidBecomeActiveNotification
     object:nil];
    
    // initialize AR
    [vapp initAR:Vuforia::GL_20 orientation:[[UIApplication sharedApplication] statusBarOrientation] deviceMode:Vuforia::Device::MODE_AR stereo:false];

    // show loading animation while AR is being initialized
    [self showLoadingAnimation];
}

- (void) pauseAR
{
    if (isShowingWebDetail)
    {
        pausedWhileShowingBookWebDetail = YES;
        if (self.bookWebDetailController != nil)
        {
            [self.bookWebDetailController.navigationController popViewControllerAnimated:NO];
        }
    }
    
    NSError * error = nil;
    if (![vapp pauseAR:&error])
    {
        NSLog(@"Error pausing AR:%@", [error description]);
    }
}

- (void) resumeAR
{
    NSError * error = nil;
    if(! [vapp resumeAR:&error])
    {
        NSLog(@"Error resuming AR:%@", [error description]);
    }

    // on resume, we reset the flash
    Vuforia::CameraDevice::getInstance().setFlashTorchMode(false);
        
    [self handleRotation:[[UIApplication sharedApplication] statusBarOrientation]];
    
    if (pausedWhileShowingBookWebDetail)
    {
        //  Show Book WebView Detail
        isShowingWebDetail = YES;
        pausedWhileShowingBookWebDetail = NO;
        [self performSegueWithIdentifier:@"PushWebDetail" sender:self];
    }
}

-(void)showUIAlertFromErrorCode:(int)code
{
    if (lastErrorCode == code)
    {
        // we don't want to show twice the same error
        return;
    }
    lastErrorCode = code;
    
    NSString *title = nil;
    NSString *message = nil;
    
    if (code == Vuforia::TargetFinder::UPDATE_ERROR_NO_NETWORK_CONNECTION)
    {
        title = @"Network Unavailable";
        message = @"Please check your internet connection and try again.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_REQUEST_TIMEOUT)
    {
        title = @"Request Timeout";
        message = @"The network request has timed out, please check your internet connection and try again.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_SERVICE_NOT_AVAILABLE)
    {
        title = @"Service Unavailable";
        message = @"The cloud recognition service is unavailable, please try again later.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_UPDATE_SDK)
    {
        title = @"Unsupported Version";
        message = @"The application is using an unsupported version of Vuforia.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_TIMESTAMP_OUT_OF_RANGE)
    {
        title = @"Clock Sync Error";
        message = @"Please update the date and time and try again.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_AUTHORIZATION_FAILED)
    {
        title = @"Authorization Error";
        message = @"The cloud recognition service access keys are incorrect or have expired.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_PROJECT_SUSPENDED)
    {
        title = @"Authorization Error";
        message = @"The cloud recognition service has been suspended.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_BAD_FRAME_QUALITY)
    {
        title = @"Poor Camera Image";
        message = @"The camera does not have enough detail, please try again later";
    }
    else
    {
        title = @"Unknown error";
        message = [NSString stringWithFormat:@"An unknown error has occurred (Code %d)", code];
    }
    
    //  Call the UIAlert on the main thread to avoid undesired behaviors
    dispatch_async( dispatch_get_main_queue(), ^{
        if (title && message)
        {
            
            UIAlertController *uiAlertController =
            [UIAlertController alertControllerWithTitle:title
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *defaultAction =
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *action) {
                                       [[NSNotificationCenter defaultCenter] postNotificationName:@"kDismissARViewController" object:nil];
                                   }];
            [uiAlertController addAction:defaultAction];
            [self presentViewController:uiAlertController animated:YES completion:nil];
        }
    });
}

- (void)bookWebDetailDismissed:(NSNotification *)notification
{
    isShowingWebDetail = NO;
    [self handleRotation:[[UIApplication sharedApplication] statusBarOrientation]];
}


- (void)viewDidLoad
{
    [super viewDidLoad];
    [eaglView prepare];
    
    // we set the UINavigationControllerDelegate
    // so that we can enforce portrait only for this view controller
    self.navigationController.delegate = (id<UINavigationControllerDelegate>)self;
    
    // Do any additional setup after loading the view.
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    [self.view addGestureRecognizer:tapGestureRecognizer];
    
    NSLog(@"self.navigationController.navigationBarHidden: %s", self.navigationController.navigationBarHidden ? "Yes" : "No");
    
    lastErrorCode = 99;
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (!isShowingWebDetail) 
    {    
        // so we check the boolean to avoid shutting down AR
        [vapp stopAR:nil];
        
        // Be a good OpenGL ES citizen: now that Vuforia is paused and the render
        // thread is not executing, inform the root view controller that the
        // EAGLView should finish any OpenGL ES commands
        [self finishOpenGLESCommands];
        
        [AppDelegate shared].glResourceHandler = nil;
    }
    
    [super viewWillDisappear:animated];
}

- (void)finishOpenGLESCommands
{
    // Called in response to applicationWillResignActive.  Inform the EAGLView
    [eaglView finishOpenGLESCommands];
}


- (void)freeOpenGLESResources
{
    // Called in response to applicationDidEnterBackground.  Inform the EAGLView
    [eaglView freeOpenGLESResources];
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    if (!self.pausedWhileShowingBookWebDetail)
    {
        isShowingWebDetail = NO;
    }
    
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    
    // make sure we're oriented/sized properly before reappearing/restarting
    [self handleARViewRotation:[[UIApplication sharedApplication] statusBarOrientation]];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [self handleRotation:[[UIApplication sharedApplication] statusBarOrientation]];
}

- (void) handleRotation:(UIInterfaceOrientation)interfaceOrientation
{
    dispatch_async(dispatch_get_main_queue(), ^{
        // ensure overlay size and AR orientation is correct for screen orientation
        [self handleARViewRotation:[[UIApplication sharedApplication] statusBarOrientation]];
//        [self->bookOverlayController handleViewRotation:[[UIApplication sharedApplication] statusBarOrientation]];
        [self->vapp changeOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
        [self->eaglView updateRenderingPrimitives];
    });
}

- (void) handleARViewRotation:(UIInterfaceOrientation)interfaceOrientation
{
    // Retrieve up-to-date view frame.
    // Note that, while on iOS 7 and below, the frame size does not change
    // with rotation events,
    // on the contray, on iOS 8 the frame size is orientation-dependent,
    // i.e. width and height get swapped when switching from
    // landscape to portrait and vice versa.
    // This requires that the latest (current) view frame is retrieved.
    CGRect viewBounds = [[UIScreen mainScreen] bounds];
    
    int smallerSize = MIN(viewBounds.size.width, viewBounds.size.height);
    int largerSize = MAX(viewBounds.size.width, viewBounds.size.height);
    
    if (interfaceOrientation == UIInterfaceOrientationPortrait ||
        interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown)
    {
        NSLog(@"AR View: Rotating to Portrait");
        
        CGRect viewBounds;
        viewBounds.origin.x = 0;
        viewBounds.origin.y = 0;
        viewBounds.size.width = smallerSize;
        viewBounds.size.height = largerSize;
        
        [eaglView setFrame:viewBounds];
    }
    else if (interfaceOrientation == UIInterfaceOrientationLandscapeLeft ||
             interfaceOrientation == UIInterfaceOrientationLandscapeRight)
    {
        NSLog(@"AR View: Rotating to Landscape");
        
        CGRect viewBounds;
        viewBounds.origin.x = 0;
        viewBounds.origin.y = 0;
        viewBounds.size.width = largerSize;
        viewBounds.size.height = smallerSize;
        
        [eaglView setFrame:viewBounds];
    }
    
    if (isVisualSearchOn)
    {
        [self scanlineUpdateRotation];
    }
}

#pragma mark - loading animation

- (void) showLoadingAnimation
{
    CGRect indicatorBounds;
    CGRect mainBounds = [[UIScreen mainScreen] bounds];
    int smallerBoundsSize = MIN(mainBounds.size.width, mainBounds.size.height);
    int largerBoundsSize = MAX(mainBounds.size.width, mainBounds.size.height);
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    if (orientation == UIInterfaceOrientationPortrait || orientation == UIInterfaceOrientationPortraitUpsideDown )
    {
        indicatorBounds = CGRectMake(smallerBoundsSize / 2 - 12,
                                     largerBoundsSize / 2 - 12, 24, 24);
    }
    else
    {
        indicatorBounds = CGRectMake(largerBoundsSize / 2 - 12,
                                     smallerBoundsSize / 2 - 12, 24, 24);
    }
    
    UIActivityIndicatorView *loadingIndicator = [[UIActivityIndicatorView alloc]
                                                  initWithFrame:indicatorBounds];
    
    loadingIndicator.tag  = 1;
    loadingIndicator.activityIndicatorViewStyle = UIActivityIndicatorViewStyleWhiteLarge;
    [eaglView addSubview:loadingIndicator];
    [loadingIndicator startAnimating];
}

- (void) hideLoadingAnimation
{
    UIActivityIndicatorView *loadingIndicator = (UIActivityIndicatorView *)[eaglView viewWithTag:1];
    [loadingIndicator removeFromSuperview];
}


#pragma mark - SampleApplicationControl

// Initialize the application trackers
- (bool) doInitTrackers
{
    // Initialize the object tracker
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* objectTracker = trackerManager.initTracker(Vuforia::ObjectTracker::getClassType());
    if (objectTracker == nullptr)
    {
        NSLog(@"Failed to initialize ObjectTracker.");
        return false;
    }
    
    return true;
}

// load the data associated to the trackers
- (bool) doLoadTrackersData
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    if (objectTracker == NULL)
    {
        NSLog(@"Failed to load tracking data set because the ObjectTracker has not been initialized.");
        return false;
    }
    
    // Initialize visual search:
    
    NSDate *start = [NSDate date];
    
    Vuforia::TargetFinder* targetFinder = objectTracker->getTargetFinder();
    
    if (targetFinder == NULL)
    {
        NSLog(@"Failed to get target finder.");
        return false;
    }
    
    targetFinder->startInit(kAccessKey, kSecretKey);
   
    targetFinder->waitUntilInitFinished();

    NSDate *methodFinish = [NSDate date];
    NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:start];
        
    NSLog(@"waitUntilInitFinished Execution Time: %lf", executionTime);
    
    int resultCode = targetFinder->getInitState();
    if ( resultCode != Vuforia::TargetFinder::INIT_SUCCESS)
    {
        int initErrorCode;
        if(resultCode == Vuforia::TargetFinder::INIT_ERROR_NO_NETWORK_CONNECTION)
        {
            initErrorCode = Vuforia::TargetFinder::UPDATE_ERROR_NO_NETWORK_CONNECTION;
        }
        else
        {
            initErrorCode = Vuforia::TargetFinder::UPDATE_ERROR_SERVICE_NOT_AVAILABLE;
        }
        [self showUIAlertFromErrorCode: initErrorCode];
        return false;
    }
    else
    {
        NSLog(@"target finder initialized");
    }
    mTargetFinder = targetFinder;
    return true;
}

// start the application trackers
- (bool) doStartTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    if (objectTracker == nullptr)
    {
        NSLog(@"ObjectTracker null.");
        return false;
    }
    objectTracker->start();
    
    // Start cloud based recognition if we are in scanning mode:
    if (scanningMode && mTargetFinder)
    {
        [self scanlineStart];
        isVisualSearchOn = mTargetFinder->startRecognition();
    }
    return true;
}

// callback called when the initailization of the AR is done
- (void) onInitARDone:(NSError *)initError
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityIndicatorView *loadingIndicator = (UIActivityIndicatorView *)[self->eaglView viewWithTag:1];
        [loadingIndicator removeFromSuperview];
    });
    
    if (initError == nil)
    {
        NSError * error = nil;
        [vapp startAR:Vuforia::CameraDevice::CAMERA_DIRECTION_BACK error:&error];
        
        // by default, we try to set the continuous auto focus mode
        Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
        
        //  the camera is initialized, this call will reset the screen configuration
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleRotation:[[UIApplication sharedApplication] statusBarOrientation]];
        });
        
    }
    else
    {
        NSLog(@"Error initializing AR:%@", [initError description]);
        dispatch_async( dispatch_get_main_queue(), ^{
            
            UIAlertController *uiAlertController =
            [UIAlertController alertControllerWithTitle:@"Error"
                                                message:[initError localizedDescription]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *defaultAction =
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *action) {
                                       [[NSNotificationCenter defaultCenter] postNotificationName:@"kDismissARViewController" object:nil];
                                   }];
            
            [uiAlertController addAction:defaultAction];
            [self presentViewController:uiAlertController animated:YES completion:nil];
        });
    }
}

- (void)dismissARViewController
{
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController popToRootViewControllerAnimated:NO];
}

- (void)configureVideoBackgroundWithViewWidth:(float)viewWidth andHeight:(float)viewHeight
{
    [eaglView configureVideoBackgroundWithViewWidth:(float)viewWidth andHeight:(float)viewHeight];
}

// update from the Vuforia loop
- (void) onVuforiaUpdate: (Vuforia::State *) state
{
    // Get the target finder:
    Vuforia::TargetFinder* finder = mTargetFinder;
    
    if (!finder)
    {
        NSLog(@"TargetFinder not initialized");
        return;
    }

    // Check if there are new results available:
    const auto& queryResult = finder->updateQueryResults();
    if (queryResult.status < 0)
    {
        // Show a message if we encountered an error:
        NSLog(@"update search result failed:%d", queryResult.status);
        if (queryResult.status == Vuforia::TargetFinder::UPDATE_ERROR_NO_NETWORK_CONNECTION)
        {
            [self showUIAlertFromErrorCode:queryResult.status];
        }
    }
    else if (queryResult.status == Vuforia::TargetFinder::UPDATE_RESULTS_AVAILABLE)
    {
        // Iterate through the new results:
        for (const auto* result : queryResult.results)
        {
            // Check if this target is suitable for tracking:
            if (result->getTrackingRating() > 0)
            {
                // Create a new Trackable from the result:
                Vuforia::Trackable* newTrackable = finder->enableTracking(*result);
                if (newTrackable != 0)
                {
                    Vuforia::ImageTarget* imageTargetTrackable = (Vuforia::ImageTarget*)newTrackable;
                    
                    //  Avoid entering on ContentMode when a bad target is found
                    //  (Bad Targets are targets that are exists on the Books database but not on our
                    //  own book database)
                    if (![[BooksManager sharedInstance] isBadTarget:imageTargetTrackable->getUniqueTargetId()])
                    {
                        NSLog(@"Successfully created new trackable '%s' with rating '%d', meta dataInfo %s.",
                              newTrackable->getName(), result->getTrackingRating(), result->getMetaData());
                    }
                }
                else
                {
                    NSLog(@"Failed to create new trackable.");
                }
            }
        }
    }
    
}


// stop your trackerts
- (bool) doStopTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker == nullptr)
    {
        NSLog(@"Failed to unload tracking data set because the ObjectTracker has not been initialized.");
        return false;
    }
    objectTracker->stop();
        
    // Stop cloud based recognition:
    if (mTargetFinder)
    {
        isVisualSearchOn = !mTargetFinder->stop();
    }
    
    return true;
}

// unload the data associated to your trackers
- (bool) doUnloadTrackersData
{
  
    // Deinitialize visual search:
    if (mTargetFinder)
    {
        mTargetFinder->deinit();
    }
    return true;
}

// deinitialize your trackers
- (bool) doDeinitTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    trackerManager.deinitTracker(Vuforia::ObjectTracker::getClassType());
    return true;
}

// tap handler
- (void)handleTap:(UITapGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateEnded)
    {
        // handling code
        CGPoint touchPoint = [sender locationInView:eaglView];
        if ([eaglView isTouchOnTarget:touchPoint] )
        {
            if (lastScannedBook)
            {
                //  Show Book WebView Detail
                isShowingWebDetail = YES;
                [self performSegueWithIdentifier:@"PushWebDetail" sender:self];
            }
        }
    }
    [self performSelector:@selector(cameraPerformAutoFocus) withObject:nil afterDelay:.4];
}

- (void)cameraPerformAutoFocus
{
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_TRIGGERAUTO);
    
    // After triggering an autofocus event,
    // we try and restore the continuous autofocus mode
    [self performSelector:@selector(restoreContinuousAutoFocus) withObject:nil afterDelay:2.0];
}

- (void)restoreContinuousAutoFocus
{
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
}

- (void) toggleVisualSearch:(BOOL)visualSearchOn
{
    if (mTargetFinder)
    {
        if (visualSearchOn == NO)
        {
            mTargetFinder->startRecognition();
            isVisualSearchOn = YES;
        }
        else
        {
            mTargetFinder->stop();
            isVisualSearchOn = NO;
        }
    }
    else
    {
        NSLog(@"Failed to toggle visual search - VS not initialized");
    }
}


- (void)setOverlayLayer:(CALayer *)overlayLayer
{
    [eaglView setOverlayLayer:overlayLayer];
}

- (void)enterScanningMode
{
    [eaglView enterScanningMode];
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    // prepare segue for BookWebDetailViewController
    UIViewController *dest = segue.destinationViewController;
    if ([dest isKindOfClass:[BookWebDetailViewController class]])
    {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
        
        BookWebDetailViewController *bookWebDetailViewController = (BookWebDetailViewController*)dest;
        self.bookWebDetailController = bookWebDetailViewController;
        bookWebDetailViewController.book = lastScannedBook;
    }
}

#pragma mark - scan line
const int VIEW_SCAN_LINE_TAG = 1111;

- (void) scanlineCreate
{
    CGRect frame = [[UIScreen mainScreen] bounds];
    
    UIImageView *scanLineView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 50)];
    scanLineView.tag = VIEW_SCAN_LINE_TAG;
    scanLineView.contentMode = UIViewContentModeScaleToFill;
    [scanLineView setImage:[UIImage imageNamed:@"scanline.png"]];
    [scanLineView setHidden:YES];
    [self.view addSubview:scanLineView];
}

- (void) scanlineStart
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView * scanLineView = [self.view viewWithTag:VIEW_SCAN_LINE_TAG];
        if (scanLineView)
        {
            [scanLineView setHidden:NO];
            CGRect frame = [[UIScreen mainScreen] bounds];
            scanLineView.frame = CGRectMake(0, 0, frame.size.width, 50);

            NSLog(@"frame: %@", NSStringFromCGRect(frame));
            CABasicAnimation *animation = [CABasicAnimation
                                           animationWithKeyPath:@"position"];
          
            animation.toValue = [NSValue valueWithCGPoint:CGPointMake(scanLineView.center.x, frame.size.height)];
            animation.autoreverses = YES;
            // we make the animation faster in landcsape mode
            animation.duration = frame.size.height > frame.size.width ? 4.0 : 2.0;
            animation.repeatCount = HUGE_VAL;
            animation.removedOnCompletion = NO;
            animation.fillMode = kCAFillModeForwards;
            [scanLineView.layer addAnimation:animation forKey:@"position"];
        }
    });
}

- (void) scanlineStop
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView * scanLineView = [self.view viewWithTag:VIEW_SCAN_LINE_TAG];
        if (scanLineView)
        {
            [scanLineView setHidden:YES];
            [scanLineView.layer removeAllAnimations];
        }
    });
}

- (void) scanlineUpdateRotation
{
    [self scanlineStop];
    [self scanlineStart];
}

#pragma mark - Navigation

// Present a view controller using the root view controller (eaglViewController)
- (void)rootViewControllerPresentViewController:(UIViewController*)viewController inContext:(BOOL)currentContext
{
    mFullScreenPlayerPlaying = YES;
    [self.navigationController pushViewController:viewController animated:YES];
}

// Dismiss a view controller presented by the root view controller
// (eaglViewController)
- (void)rootViewControllerDismissPresentedViewController
{
    mFullScreenPlayerPlaying = NO;
    [self.navigationController popViewControllerAnimated:YES];
}


@end
