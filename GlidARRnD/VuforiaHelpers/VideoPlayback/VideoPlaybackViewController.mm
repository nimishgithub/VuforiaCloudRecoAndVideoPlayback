/*===============================================================================
Copyright (c) 2016-2018 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import "VideoPlaybackViewController.h"
//#import "VideoPlaybackAppDelegate.h"
#import <Vuforia/Vuforia.h>
#import <Vuforia/TrackerManager.h>
#import <Vuforia/ObjectTracker.h>
#import <Vuforia/Trackable.h>
#import <Vuforia/DataSet.h>
#import <Vuforia/CameraDevice.h>
#import <GlidARRnD-Swift.h>

//#import "UnwindMenuSegue.h"
//#import "PresentMenuSegue.h"
//#import "SampleAppMenuViewController.h"

@interface VideoPlaybackViewController ()

@property (weak, nonatomic) IBOutlet UIImageView *ARViewPlaceholder;

@end

@implementation VideoPlaybackViewController

@synthesize tapGestureRecognizer, vapp, eaglView;

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView
{
    // Custom initialization
    self.title = @"Video Playback";

    if (self.ARViewPlaceholder != nil)
    {
        [self.ARViewPlaceholder removeFromSuperview];
        self.ARViewPlaceholder = nil;
    }
    
    mFullScreenPlayerPlaying = NO;
    mPlayFullscreenEnabled = NO;
    
    vapp = [[SampleApplicationSession alloc] initWithDelegate:self];
    CGRect viewFrame = [vapp getCurrentARViewBounds];
    eaglView = [[VideoPlaybackEAGLView alloc] initWithFrame:viewFrame rootViewController:self appSession:vapp];
    [eaglView setBackgroundColor:UIColor.clearColor];
    [self setView:eaglView];
    [AppDelegate shared].glResourceHandler = eaglView;
    
    // double tap used to also trigger the menu
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget: self action:@selector(doubleTapGestureAction:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:doubleTap];
    
    // a single tap will trigger a single autofocus operation
    tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    
    if (doubleTap != nil)
    {
        [tapGestureRecognizer requireGestureRecognizerToFail:doubleTap];
    }
    
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeGestureAction:)];
    [swipeRight setDirection:UISwipeGestureRecognizerDirectionRight];
    [self.view addGestureRecognizer:swipeRight];
    
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dismissARViewController)
                                                 name:@"kDismissARViewController"
                                               object:nil];
    
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
    [eaglView dismissPlayers];
    NSError * error = nil;
    if (![vapp pauseAR:&error])
    {
        NSLog(@"Error pausing AR:%@", [error description]);
    }
}

- (void) resumeAR {
    [eaglView preparePlayers];
    NSError * error = nil;
    if(![vapp resumeAR:&error])
    {
        NSLog(@"Error resuming AR:%@", [error description]);
    }
    
    [eaglView updateRenderingPrimitives];
}


- (void)viewDidLoad
{
    [super viewDidLoad];
    [eaglView prepare];
    
    // we set the UINavigationControllerDelegate
    // so that we can enforce portrait only for this view controller
    self.navigationController.delegate = (id<UINavigationControllerDelegate>)self;
    
    self.showingMenu = NO;
    
    // Do any additional setup after loading the view.
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    [self.view addGestureRecognizer:tapGestureRecognizer];
    
    NSLog(@"self.navigationController.navigationBarHidden: %s", self.navigationController.navigationBarHidden ? "Yes" : "No");
}

- (void)viewWillDisappear:(BOOL)animated
{
    // This is called when the full time player is being displayed
    // so we check the boolean to avoid shutting down AR
    if (!mFullScreenPlayerPlaying && !self.showingMenu)
    {
        [eaglView dismiss];
        
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

//------------------------------------------------------------------------------
#pragma mark - Autorotation
- (NSUInteger)navigationControllerSupportedInterfaceOrientations:(UINavigationController *)navigationController
{
    // We allow autorotation when we are playing in full screen
    NSUInteger orientationMask = UIInterfaceOrientationMaskPortrait;
    if(mFullScreenPlayerPlaying)
    {
        orientationMask = UIInterfaceOrientationMaskAll;
    }
    
    return orientationMask;
}

- (UIInterfaceOrientation)navigationControllerPreferredInterfaceOrientationForPresentation:(UINavigationController *)navigationController
{
    return UIInterfaceOrientationPortrait;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate
{
    return YES;
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
    // Initialize the image tracker
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* trackerBase = trackerManager.initTracker(Vuforia::ObjectTracker::getClassType());
    if (trackerBase == nil)
    {
        NSLog(@"Failed to initialize ObjectTracker.");
        return false;
    }
    return true;
}

// load the data associated to the trackers
- (bool) doLoadTrackersData
{
    return [self loadAndActivateImageTrackerDataSet:@"StonesAndChips.xml"];;
}

// start the application trackers
- (bool) doStartTrackers
{
    // Set the number of simultaneous targets to two
    Vuforia::setHint(Vuforia::HINT_MAX_SIMULTANEOUS_IMAGE_TARGETS, kNumVideoTargets);
    
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* tracker = trackerManager.getTracker(Vuforia::ObjectTracker::getClassType());
    if(tracker == nullptr)
    {
        return false;
    }
    tracker->start();
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
        
        [eaglView updateRenderingPrimitives];
        
        // by default, we try to set the continuous auto focus mode
        Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
        
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
}

// stop your trackerts
- (bool) doStopTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* tracker = trackerManager.getTracker(Vuforia::ObjectTracker::getClassType());
    
    if (tracker == nullptr)
    {
        NSLog(@"ERROR: failed to get the tracker from the tracker manager");
        return false;
    }
    
    tracker->stop();
    return true;
}

// unload the data associated to your trackers
- (bool) doUnloadTrackersData
{
    if (mDataSet != nullptr)
    {
        // Get the image tracker:
        Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
        Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
        
        if (objectTracker == nullptr)
        {
            NSLog(@"Failed to unload tracking data set because the ImageTracker has not been initialized.");
            return false;
        }
        
        // Activate the data set:
        if (!objectTracker->deactivateDataSet(mDataSet))
        {
            NSLog(@"Failed to deactivate data set.");
            return false;
        }
        
        // Activate the data set:
        if (!objectTracker->destroyDataSet(mDataSet))
        {
            NSLog(@"Failed to destroy data set.");
            return false;
        }
        
        mDataSet = nullptr;
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
        [eaglView handleTouchPoint:touchPoint];
    }
    
    [self autofocus:sender];
}

- (void)autofocus:(UITapGestureRecognizer *)sender
{
    [self performSelector:@selector(cameraPerformAutoFocus) withObject:nil afterDelay:.4];
}

- (void)cameraPerformAutoFocus
{
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_TRIGGERAUTO);
    
    // After triggering an autofocus event,
    // we must restore the previous focus mode
    [self performSelector:@selector(restoreContinuousAutoFocus) withObject:nil afterDelay:2.0];
}

- (void)restoreContinuousAutoFocus
{
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
}

- (void)doubleTapGestureAction:(UITapGestureRecognizer*)theGesture
{
    if (!self.showingMenu)
    {
        [self performSegueWithIdentifier: @"PresentMenu" sender: self];
    }
}

- (void)swipeGestureAction:(UISwipeGestureRecognizer*)gesture
{
    if (!self.showingMenu)
    {
        [self performSegueWithIdentifier:@"PresentMenu" sender:self];
    }
}


// Load the image tracker data set
- (BOOL)loadAndActivateImageTrackerDataSet:(NSString*)dataFile
{
    NSLog(@"loadAndActivateImageTrackerDataSet (%@)", dataFile);
    BOOL ret = YES;
    mDataSet = nullptr;
    
    // Get the Vuforia tracker manager image tracker
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker == nullptr)
    {
        NSLog(@"ERROR: failed to get the ImageTracker from the tracker manager");
        ret = NO;
    }
    else
    {
        mDataSet = objectTracker->createDataSet();
        
        if (mDataSet != nullptr)
        {
            // Load the data set from the app's resources location
            if (!mDataSet->load([dataFile cStringUsingEncoding:NSASCIIStringEncoding], Vuforia::STORAGE_APPRESOURCE))
            {
                NSLog(@"ERROR: failed to load data set");
                objectTracker->destroyDataSet(mDataSet);
                mDataSet = nullptr;
                ret = NO;
            }
            else
            {
                // Activate the data set
                if (objectTracker->activateDataSet(mDataSet))
                {
                    NSLog(@"INFO: successfully activated data set");
                }
                else
                {
                    NSLog(@"ERROR: failed to activate data set");
                    ret = NO;
                }
            }
        }
        else
        {
            NSLog(@"ERROR: failed to create data set");
            ret = NO;
        }
        
    }
    
    return ret;
}

#pragma mark - menu delegate protocol implementation

- (BOOL) menuProcess:(NSString *)itemName value:(BOOL)value
{
    if ([@"Play Fullscreen" isEqualToString:itemName])
    {
        [eaglView willPlayVideoFullScreen:value];
        mPlayFullscreenEnabled = value;
        return YES;
    }
    return NO;
}

- (void) menuDidExit
{
    self.showingMenu = NO;
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

//- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
//    if ([segue isKindOfClass:[PresentMenuSegue class]])
//    {
//        UIViewController *dest = [segue destinationViewController];
//        if ([dest isKindOfClass:[SampleAppMenuViewController class]])
//        {
//            self.showingMenu = YES;
//
//            SampleAppMenuViewController *menuVC = (SampleAppMenuViewController *)dest;
//            menuVC.menuDelegate = self;
//            menuVC.sampleAppFeatureName = @"Video Playback";
//            menuVC.dismissItemName = @"About";
//            menuVC.backSegueId = @"BackToVideoPlayback";
//
//            // initialize menu item values (ON / OFF)
//            [menuVC setValue:mPlayFullscreenEnabled forMenuItem:@"Play Fullscreen"];
//        }
//    }


@end
