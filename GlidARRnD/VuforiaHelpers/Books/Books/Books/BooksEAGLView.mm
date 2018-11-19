/*===============================================================================
Copyright (c) 2015-2018 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <sys/time.h>

#import <Vuforia/Vuforia.h>
#import <Vuforia/State.h>
#import <Vuforia/Tool.h>
#import <Vuforia/Renderer.h>
#import <Vuforia/TrackableResult.h>
#import <Vuforia/ImageTargetResult.h>
#import <Vuforia/TrackerManager.h>
#import <Vuforia/ObjectTracker.h>
#import <Vuforia/TargetFinder.h>

#import "BooksManager.h"
#import "ImagesManager.h"

#import "BooksEAGLView.h"
#import "Texture.h"
#import "SampleApplicationUtils.h"
#import "SampleApplicationShaderUtils.h"
#import "BookOverlayPlane.h"
#import "Quad.h"

//******************************************************************************
// *** OpenGL ES thread safety ***
//
// OpenGL ES on iOS is not thread safe.  We ensure thread safety by following
// this procedure:
// 1) Create the OpenGL ES context on the main thread.
// 2) Start the Vuforia camera, which causes Vuforia to locate our EAGLView and start
//    the render thread.
// 3) Vuforia calls our renderFrameVuforia method periodically on the render thread.
//    The first time this happens, the defaultFramebuffer does not exist, so it
//    is created with a call to createFramebuffer.  createFramebuffer is called
//    on the main thread in order to safely allocate the OpenGL ES storage,
//    which is shared with the drawable layer.  The render (background) thread
//    is blocked during the call to createFramebuffer, thus ensuring no
//    concurrent use of the OpenGL ES context.
//
//******************************************************************************

// ----------------------------------------------------------------------------
// Application Render States
// ----------------------------------------------------------------------------
static int RS_NORMAL = 0;
static int RS_TRANSITION_TO_2D = 1;
static int RS_TRANSITION_TO_3D = 2;
static int RS_SCANNING = 3;
static int RS_OVERLAY = 4;

namespace {

    //Taken From VideoPlaybackEaglView
    // Texture filenames (an Object3D object is created for each texture)
    const char* textureFilenames[5] = {
        "icon_play.png",
        "icon_loading.png",
        "icon_error.png",
        "VuforiaSizzleReel_1.png",
        "VuforiaSizzleReel_2.png"
    };
    
    enum tagObjectIndex {
        OBJECT_PLAY_ICON,
        OBJECT_BUSY_ICON,
        OBJECT_ERROR_ICON,
        OBJECT_KEYFRAME_1,
        OBJECT_KEYFRAME_2,
    };
    
    const NSTimeInterval TRACKING_LOST_TIMEOUT = 2.0f;
    
    // Playback icon scale factors
    const float SCALE_ICON = 2.0f;
    
    // Video quad texture coordinates
    const GLfloat videoQuadTextureCoords[] = {
        0.0, 1.0,
        1.0, 1.0,
        1.0, 0.0,
        0.0, 0.0,
    };
    
    struct tagVideoData {
        // Needed to calculate whether a screen tap is inside the target
        Vuforia::Matrix44F modelViewMatrix;
        
        // Trackable dimensions
        Vuforia::Vec2F targetPositiveDimensions;
        
        // Currently active flag
        BOOL isActive;
    } videoData;
    
    int touchedTarget = 0;
}

@interface BooksEAGLView ()

// private properties:
// Texture used when rendering augmentation
@property (nonatomic, strong) Texture* mockBookCoverTexture;

// Whether the application is in scanning mode (or in content mode):
@property (nonatomic, readwrite) bool scanningMode;

@property (nonatomic, assign) id<BooksControllerDelegateProtocol> booksDelegate;

@property (nonatomic, assign) GLuint trackingTextureID;

@property (nonatomic, readwrite) BOOL trackingTextureIDSet;

@property (nonatomic, readwrite) BOOL trackingTextureAvailable;
@property (nonatomic, readwrite) BOOL isViewingTarget;
@property (nonatomic, readwrite) BOOL isShowing2DOverlay;

// ----------------------------------------------------------------------------
// 3D to 2D Transition control variables
// ----------------------------------------------------------------------------
@property (nonatomic, assign) Transition3Dto2D* transition3Dto2D;
@property (nonatomic, assign) Transition3Dto2D* transition2Dto3D;

@property (nonatomic, readwrite) BOOL startTransition;
@property (nonatomic, readwrite) BOOL startTransition2Dto3D;

@property (nonatomic, readwrite) BOOL reportedFinished;
@property (nonatomic, readwrite) BOOL reportedFinished2Dto3D;

@property (nonatomic, readwrite) int renderState;
@property (nonatomic, readwrite) float transitionDuration;

// Lock to prevent concurrent access of the framebuffer on the main and
// render threads (layoutSubViews and renderFrameVuforia methods)
@property (nonatomic, strong) NSLock *framebufferLock;

// Lock to synchronise data that is (potentially) accessed concurrently
@property (nonatomic, strong) NSLock* dataLock;

@property (nonatomic, readwrite) BOOL mDoLayoutSubviews;

@property (nonatomic, weak) SampleApplicationSession * vapp;

- (void)initShaders;
- (void)createFramebuffer;
- (void)deleteFramebuffer;
- (void)setFramebuffer;
- (BOOL)presentFramebuffer;

@end


@implementation BooksEAGLView

@synthesize vapp, booksDelegate, dataLock, framebufferLock;
@synthesize mockBookCoverTexture, transition2Dto3D, transition3Dto2D, trackingTextureID;

// You must implement this method, which ensures the view's underlying layer is
// of type CAEAGLLayer
+ (Class)layerClass
{
    return [CAEAGLLayer class];
}


//------------------------------------------------------------------------------
#pragma mark - Lifecycle

- (id)initWithFrame:(CGRect)frame delegate:(id<BooksControllerDelegateProtocol>) delegate appSession:(SampleApplicationSession *) app
{
    self = [super initWithFrame:frame];
    
    if (self)
    {
        vapp = app;
        videoPlaybackViewController = (BooksViewController*)delegate;
        
        booksDelegate = delegate;
        _scanningMode = YES;
        framebufferLock = [[NSLock alloc] init];
        //  Books variables
        _trackingTextureAvailable = NO;
        _isViewingTarget = NO;
        
        // Enable retina mode if available on this device
        if (YES == [vapp isRetinaDisplay]) {
            [self setContentScaleFactor:[UIScreen mainScreen].nativeScale];
        }
        // Load the "mock book cover" augmentation texture
        mockBookCoverTexture = [[Texture alloc] initWithImageFile:@"mock_book_cover.png"];
        
        // Create the OpenGL ES context
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        
        // The EAGLContext must be set for each thread that wishes to use it.
        // Set it the first time this method is called (on the main thread)
        if (context != [EAGLContext currentContext])
        {
            [EAGLContext setCurrentContext:context];
        }
        
        sampleAppRenderer = [[SampleAppRenderer alloc] initWithSampleAppRendererControl:self nearPlane:0.005 farPlane:5];
        
        // Generate the OpenGL ES texture and upload the texture data for use
        // when rendering the augmentation
        GLuint textureID;
        glGenTextures(1, &textureID);
        [mockBookCoverTexture setTextureID:textureID];
        glBindTexture(GL_TEXTURE_2D, textureID);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, [mockBookCoverTexture width], [mockBookCoverTexture height], 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)[mockBookCoverTexture pngData]);
        
        // Set appropriate texture parameters (for NPOT textures)
//        if (OBJECT_KEYFRAME_1 <= i)
//        {
//            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
//            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
//        }

        // Class data lock
        dataLock = [[NSLock alloc] init];

        [sampleAppRenderer initRendering];
        [self initShaders];
    }
    
    return self;
}

- (void) willPlayVideoFullScreen:(BOOL) fullScreen
{
    playVideoFullScreen = fullScreen;
}

- (void) prepare
{
    // For each target, create a VideoPlayerHelper object and zero the
    // target dimensions
    videoData.targetPositiveDimensions.data[0] = 0.0f;
    videoData.targetPositiveDimensions.data[1] = 0.0f;
    
    // Start video playback from the current position (the beginning) on the
    // first run of the app
    videoPlaybackTime = VIDEO_PLAYBACK_CURRENT_POSITION;
    videoPlayerHelper = [[VideoPlayerHelper alloc] initWithRootViewController: videoPlaybackViewController];
    VideoPlayerHelper *player =  videoPlayerHelper;
    NSString* filename;
    filename = @"VuforiaSizzleReel_1.mp4";
    if (![player load:filename playImmediately:NO fromPosition: videoPlaybackTime])
    {
        NSLog(@"Failed to load media");
    }
 
}

- (void) dismiss
{
    [videoPlayerHelper unload];
    videoPlayerHelper = nil;
}


- (void)dealloc
{
    [self deleteFramebuffer];

    // Tear down context
    if ([EAGLContext currentContext] == context)
    {
        [EAGLContext setCurrentContext:nil];
    }
    
    mockBookCoverTexture = nil;
}


- (void)finishOpenGLESCommands
{
    // Called in response to applicationWillResignActive.  The render loop has
    // been stopped, so we now make sure all OpenGL ES commands complete before
    // we (potentially) go into the background
    if (context)
    {
        [EAGLContext setCurrentContext:context];
        glFinish();
    }
}


- (void)freeOpenGLESResources
{
    // Called in response to applicationDidEnterBackground.  Free easily
    // recreated OpenGL ES resources
    [self deleteFramebuffer];
    glFinish();
}

- (void)layoutSubviews
{
    self.mDoLayoutSubviews = YES;
}

- (void)doLayoutSubviews
{
    // this method will be called during the rotation of the device
    // if we are in the middle of the 3D to 2D rotation, it will be aborted
    // so we need to finish the transition and put in the app in a proper state
    // otherwise we wouldn't display the book overlay as expected
    if (self.renderState == RS_TRANSITION_TO_2D)
    {
        [self endTransitionOnTargetLost];
    }

    // The framebuffer will be re-created at the beginning of the next setFramebuffer method call.
    [self deleteFramebuffer];
    
    // Initialisation done once, or once per screen size change
    [self initRendering];
}


- (void)initRendering
{
    BOOL isPortrait = false;
    UIInterfaceOrientation interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    
    // Determine device orientation
    if (UIInterfaceOrientationIsPortrait(interfaceOrientation))
    {
        isPortrait = true;
    }
    
    transition3Dto2D = new Transition3Dto2D(self.frame.size.width, self.frame.size.height, isPortrait);
    transition3Dto2D->initializeGL(shaderProgramID);
    
    transition2Dto3D = new Transition3Dto2D(self.frame.size.width, self.frame.size.height, isPortrait);
    transition2Dto3D->initializeGL(shaderProgramID);
    
    self.renderState = RS_NORMAL;
    
    self.transitionDuration = 0.5f;
    trackableSize = Vuforia::Vec2F(0.0f, 0.0f);
}


- (void)setOrientationTransform:(CGAffineTransform)transform withLayerPosition:(CGPoint)pos
{
    self.layer.position = pos;
    self.transform = transform;
}


//------------------------------------------------------------------------------
#pragma mark - UIGLViewProtocol methods

// Draw the current frame using OpenGL
//
// This method is called by Vuforia when it wishes to render the current frame to
// the screen.
//
// *** Vuforia will call this method periodically on a background thread ***
- (void)renderFrameVuforia
{
    if (!vapp.cameraIsStarted)
    {
        return;
    }
    
    [sampleAppRenderer renderFrameVuforia];
}


- (void)updateRenderingPrimitives
{
    [sampleAppRenderer updateRenderingPrimitives];
}

- (void)renderFrameWithState:(const Vuforia::State &)state projectMatrix:(Vuforia::Matrix44F &)projectionMatrix
{
    // test if the layout has changed
    if (self.mDoLayoutSubviews)
    {
        [self doLayoutSubviews];
        self.mDoLayoutSubviews = NO;
    }
    
    [framebufferLock lock];
    [self setFramebuffer];
    
    // Clear colour and depth buffers
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // Render video background and retrieve tracking state
    [sampleAppRenderer renderVideoBackgroundWithState:state];
    
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_DEPTH_TEST);
    // We must detect if background reflection is active and adjust the culling direction.
    // If the reflection is active, this means the pose matrix has been reflected as well,
    // therefore standard counter clockwise face culling will result in "inside out" models.
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    
    // ----- Synchronise data access -----
    [dataLock lock];
    
    // Did we find any trackables this frame?
    if (!state.getTrackableResults().empty())
    {
        //        // Get the trackable:
        trackableResult = state.getTrackableResults().at(0);
        modelViewMatrix = Vuforia::Tool::convertPose2GLMatrix(trackableResult->getPose());
        // Assume the target is inactive (used when determining tap locations)
        videoData.isActive = NO;
        
//                modelViewMatrix = projectionMatrix; // Done Above //TWEAK
        
        // Did we find any trackables this frame?
        //                const auto& trackableResultList = state.getTrackableResults();
        //                for (const auto* trackableResult : trackableResultList)
        //                {
//        const Vuforia::ImageTarget& imageTarget = (const Vuforia::ImageTarget&) trackableResult->getTrackable();
//        assert(imageTarget.getType().isOfType(Vuforia::ImageTarget::getClassType()));
        const Vuforia::Trackable& trackable = trackableResult->getTrackable();
        assert(trackable.getType().isOfType(Vuforia::ImageTarget::getClassType()));
        
        // Get the size of the ImageTarget
        Vuforia::ImageTargetResult *imageResult = (Vuforia::ImageTargetResult *)trackableResult;
        Vuforia::Vec3F targetSize = imageResult->getTrackable().getSize();
        //                trackableSize.data[0] = targetSize.data[0];
        //                trackableSize.data[1] = targetSize.data[1];
       
        // Mark this video (target) as active
        videoData.isActive = YES;
        
        // Get the target size (used to determine if taps are within the target)
        Vuforia::ImageTarget* imageTargetTrackable = (Vuforia::ImageTarget*)&trackable;
        NSString *uniqueTargetId = [NSString stringWithUTF8String:imageTargetTrackable->getUniqueTargetId()];
        
        // we reset this transitional state
        if (self.renderState == RS_OVERLAY)
        {
            self.renderState = RS_NORMAL;
        }
        
        // If the last scanned book is different from the one it's scanning now
        // and no network operation is active, then generate texture again
        if (![[booksDelegate lastTargetIDScanned] isEqualToString:uniqueTargetId] && NO == [[BooksManager sharedInstance] isNetworkOperationInProgress])
        {
            [booksDelegate setLastTargetIDScanned:uniqueTargetId];
            [self createContent:imageTargetTrackable];
        }
        else
        {
            return;
        }
        
        if (targetSize.data[0] == 0.0f || targetSize.data[1] == 0.0f)
        {

            
            Vuforia::Vec3F size = imageResult->getTrackable().getSize();//imageTarget.getSize();
            videoData.targetPositiveDimensions.data[0] = size.data[0];
            videoData.targetPositiveDimensions.data[1] = size.data[1];
            
            // The pose delivers the centre of the target, thus the dimensions
            // go from -width / 2 to width / 2, and -height / 2 to height / 2
            videoData.targetPositiveDimensions.data[0] /= 2.0f;
            videoData.targetPositiveDimensions.data[1] /= 2.0f;
        }
        
        // Get the current trackable pose
        const Vuforia::Matrix34F& trackablePose = trackableResult->getPose();
        
        // This matrix is used to calculate the location of the screen tap
        videoData.modelViewMatrix = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
        
        float aspectRatio;
        const GLvoid* texCoords;
        GLuint frameTextureID = 0;
        BOOL displayVideoFrame = YES;
        
        // Retain value between calls
        static GLuint videoTextureID = 0;
        
        MEDIA_STATE currentStatus = [videoPlayerHelper getStatus];
        
        // NSLog(@"MEDIA_STATE for %d is %d", playerIndex, currentStatus);
        
        // --- INFORMATION ---
        // One could trigger automatic playback of a video at this point.  This
        // could be achieved by calling the play method of the VideoPlayerHelper
        // object if currentStatus is not PLAYING.  You should also call
        // getStatus again after making the call to play, in order to update the
        // value held in currentStatus.
        // --- END INFORMATION ---
        
        switch (currentStatus)
        {
            case PLAYING:
            {
                // If the tracking lost timer is scheduled, terminate it
                if (trackingLostTimer != nil)
                {
                    // Timer termination must occur on the same thread on which
                    // it was installed
                    [self performSelectorOnMainThread:@selector(terminateTrackingLostTimer) withObject:nil waitUntilDone:YES];
                }
                
                // Upload the decoded video data for the latest frame to OpenGL
                // and obtain the video texture ID
                GLuint videoTexID = [videoPlayerHelper updateVideoData];
                
                if (videoTextureID == 0)
                {
                    videoTextureID = videoTexID;
                }
                
                // Fallthrough
            }
            case PAUSED:
                if (videoTextureID == 0) {
                    // No video texture available, display keyframe
                    displayVideoFrame = NO;
                }
                else
                {
                    // Display the texture most recently returned from the call
                    // to [videoPlayerHelper updateVideoData]
                    frameTextureID = videoTextureID;
                }
                
                break;
                
            default:
                videoTextureID = 0;
                displayVideoFrame = NO;
                break;
        }
        
        if (displayVideoFrame)
        {
            // ---- Display the video frame -----
            aspectRatio = (float)[videoPlayerHelper getVideoHeight] / (float)[videoPlayerHelper getVideoWidth];
            texCoords = videoQuadTextureCoords;
        }
        else
        {
            // ----- Display the keyframe -----
            Texture* t = mockBookCoverTexture;//[OBJECT_KEYFRAME_1 + playerIndex];
            frameTextureID = [t textureID];
            aspectRatio = (float)[t height] / (float)[t width];
            texCoords = quadTexCoords;
        }
        
        // If the current status is valid (not NOT_READY or ERROR), render the
        // video quad with the texture we've just selected
        if (currentStatus != NOT_READY)
        {
            // Convert trackable pose to matrix for use with OpenGL
            Vuforia::Matrix44F modelViewMatrixVideo = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
            Vuforia::Matrix44F modelViewProjectionVideo;
            
            SampleApplicationUtils::scalePoseMatrix(videoData.targetPositiveDimensions.data[0],
                                                    videoData.targetPositiveDimensions.data[0] * aspectRatio,
                                                    videoData.targetPositiveDimensions.data[0],
                                                    &modelViewMatrixVideo.data[0]);
            
            SampleApplicationUtils::multiplyMatrix(projectionMatrix.data,
                                                   &modelViewMatrixVideo.data[0] ,
                                                   &modelViewProjectionVideo.data[0]);
            
            glUseProgram(shaderProgramID);
            
            glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, quadVertices);
            glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, quadNormals);
            glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, texCoords);
            
            glEnableVertexAttribArray(vertexHandle);
            glEnableVertexAttribArray(normalHandle);
            glEnableVertexAttribArray(textureCoordHandle);
            
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, frameTextureID);
            glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (GLfloat*)&modelViewProjectionVideo.data[0]);
            glUniform1i(texSampler2DHandle, 0 /*GL_TEXTURE0*/);
            glDrawElements(GL_TRIANGLES, kNumQuadIndices, GL_UNSIGNED_SHORT, quadIndices);
            
            glDisableVertexAttribArray(vertexHandle);
            glDisableVertexAttribArray(normalHandle);
            glDisableVertexAttribArray(textureCoordHandle);
            
            glUseProgram(0);
        }
        
        // If the current status is not PLAYING, render an icon
        if (currentStatus != PLAYING)
        {
            GLuint iconTextureID;
            
            switch (currentStatus)
            {
                case READY:
                case REACHED_END:
                case PAUSED:
                case STOPPED:
                {
                    // ----- Display play icon -----
                    iconTextureID = [mockBookCoverTexture textureID];
                    break;
                }
                    
                case ERROR:
                {
                    // ----- Display error icon -----
                    iconTextureID = [mockBookCoverTexture textureID];
                    break;
                }
                    
                default:
                {
                    // ----- Display busy icon -----
                    iconTextureID = [mockBookCoverTexture textureID];
                    break;
                }
            }
            
            // Convert trackable pose to matrix for use with OpenGL
            Vuforia::Matrix44F modelViewMatrixButton = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
            Vuforia::Matrix44F modelViewProjectionButton;
            
            SampleApplicationUtils::translatePoseMatrix(0.0f, 0.0f, 0.01f, &modelViewMatrixButton.data[0]);
            
            SampleApplicationUtils::scalePoseMatrix(videoData.targetPositiveDimensions.data[1] / SCALE_ICON,
                                                    videoData.targetPositiveDimensions.data[1] / SCALE_ICON,
                                                    videoData.targetPositiveDimensions.data[1] / SCALE_ICON,
                                                    &modelViewMatrixButton.data[0]);
            
            SampleApplicationUtils::multiplyMatrix(projectionMatrix.data,
                                                   &modelViewMatrixButton.data[0] ,
                                                   &modelViewProjectionButton.data[0]);
            
            glDepthFunc(GL_LEQUAL);
            
            glUseProgram(shaderProgramID);
            
            glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, quadVertices);
            glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, quadNormals);
            glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, quadTexCoords);
            
            glEnableVertexAttribArray(vertexHandle);
            glEnableVertexAttribArray(normalHandle);
            glEnableVertexAttribArray(textureCoordHandle);
            
            // Blend the icon over the background
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, iconTextureID);
            glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (GLfloat*)&modelViewProjectionButton.data[0] );
            glDrawElements(GL_TRIANGLES, kNumQuadIndices, GL_UNSIGNED_SHORT, quadIndices);
            
            glDisable(GL_BLEND);
            
            glDisableVertexAttribArray(vertexHandle);
            glDisableVertexAttribArray(normalHandle);
            glDisableVertexAttribArray(textureCoordHandle);
            
            glUseProgram(0);
            
            glDepthFunc(GL_LESS);
        }
        
        SampleApplicationUtils::checkGlError("VideoPlayback renderFrameVuforia");
        //                }
        
        // --- INFORMATION ---
        // One could pause automatic playback of a video at this point.  Simply call
        // the pause method of the VideoPlayerHelper object without setting the
        // timer (as below).
        // --- END INFORMATION ---
        
        // If a video is playing on texture and we have lost tracking, create a
        // timer on the main thread that will pause video playback after
        // TRACKING_LOST_TIMEOUT seconds
        if (nil == trackingLostTimer && NO == videoData.isActive && PLAYING == [videoPlayerHelper getStatus])
        {
            [self performSelectorOnMainThread:@selector(createTrackingLostTimer) withObject:nil waitUntilDone:YES];
        }
    }
    
    if (self.renderState == RS_OVERLAY)
    {
        // if the overlay view was displayed while no target was found, we
        // need to trigger the event so that the targets shows up
        self.renderState = RS_NORMAL;
        self.isShowing2DOverlay = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kTargetLost" object:nil userInfo:nil];
    }
    
    if (self.isViewingTarget) // This means there was a target but we can't find it anymore
    {
        self.isViewingTarget = NO;
        
        // This needs to be called on main thread to make sure the thread doesn't die before the timer is called
        dispatch_async(dispatch_get_main_queue(), ^{
            [self targetLost];
        });
    }
    //    }
    //
    [dataLock unlock];
    // ----- End synchronise data access -----
    
    
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    
    glDisableVertexAttribArray(vertexHandle);
    glDisableVertexAttribArray(normalHandle);
    glDisableVertexAttribArray(textureCoordHandle);
    
    
    Vuforia::Renderer::getInstance().end();
    
    [self presentFramebuffer];
    [framebufferLock unlock];
    
}

// Create the tracking lost timer
- (void)createTrackingLostTimer
{
    trackingLostTimer = [NSTimer scheduledTimerWithTimeInterval:TRACKING_LOST_TIMEOUT target:self selector:@selector(trackingLostTimerFired:) userInfo:nil repeats:NO];
}

// Terminate the tracking lost timer
- (void)terminateTrackingLostTimer
{
    [trackingLostTimer invalidate];
    trackingLostTimer = nil;
}

// Tracking lost timer fired, pause video playback
- (void)trackingLostTimerFired:(NSTimer*)timer
{
    // Tracking has been lost for TRACKING_LOST_TIMEOUT seconds, pause playback
    // (we can safely do this on all our VideoPlayerHelpers objects)
    
    [videoPlayerHelper pause];
    trackingLostTimer = nil;
}


-(void) endTransitionOnTargetLost
{
    self.isShowing2DOverlay = YES;
    self.startTransition = NO;

    self.renderState = RS_NORMAL;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"kTargetLost" object:nil userInfo:nil];
}


- (void)configureVideoBackgroundWithViewWidth:(float)viewWidth andHeight:(float)viewHeight
{
    [sampleAppRenderer configureVideoBackgroundWithViewWidth:viewWidth andHeight:viewHeight];
}

//------------------------------------------------------------------------------
#pragma mark - OpenGL ES management

- (void)initShaders
{
    shaderProgramID = [SampleApplicationShaderUtils createProgramWithVertexShaderFileName:@"Simple.vertsh"
                                                   fragmentShaderFileName:@"Simple.fragsh"];

    if (0 < shaderProgramID)
    {
        vertexHandle = glGetAttribLocation(shaderProgramID, "vertexPosition");
        normalHandle = glGetAttribLocation(shaderProgramID, "vertexNormal");
        textureCoordHandle = glGetAttribLocation(shaderProgramID, "vertexTexCoord");
        mvpMatrixHandle = glGetUniformLocation(shaderProgramID, "modelViewProjectionMatrix");
        texSampler2DHandle  = glGetUniformLocation(shaderProgramID,"texSampler2D");
    }
    else
    {
        NSLog(@"Could not initialise augmentation shader");
    }
}


- (void)createFramebuffer
{
    if (context)
    {
        // Create default framebuffer object
        glGenFramebuffers(1, &defaultFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
        
        // Create colour renderbuffer and allocate backing store
        glGenRenderbuffers(1, &colorRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
        
        // Allocate the renderbuffer's storage (shared with the drawable object)
        [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
        GLint framebufferWidth;
        GLint framebufferHeight;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &framebufferWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &framebufferHeight);
        
        // Create the depth render buffer and allocate storage
        glGenRenderbuffers(1, &depthRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, framebufferWidth, framebufferHeight);
        
        // Attach colour and depth render buffers to the frame buffer
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);
        
        // Leave the colour render buffer bound so future rendering operations will act on it
        glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    }
}


- (void)deleteFramebuffer
{
    if (context)
    {
        [EAGLContext setCurrentContext:context];
        
        if (defaultFramebuffer)
        {
            glDeleteFramebuffers(1, &defaultFramebuffer);
            defaultFramebuffer = 0;
        }
        
        if (colorRenderbuffer)
        {
            glDeleteRenderbuffers(1, &colorRenderbuffer);
            colorRenderbuffer = 0;
        }
        
        if (depthRenderbuffer)
        {
            glDeleteRenderbuffers(1, &depthRenderbuffer);
            depthRenderbuffer = 0;
        }
    }
}


- (void)setFramebuffer
{
    // The EAGLContext must be set for each thread that wishes to use it.  Set
    // it the first time this method is called (on the render thread)
    if (context != [EAGLContext currentContext])
    {
        [EAGLContext setCurrentContext:context];
    }
    
    if (!defaultFramebuffer)
    {
        // Perform on the main thread to ensure safe memory allocation for the
        // shared buffer.  Block until the operation is complete to prevent
        // simultaneous access to the OpenGL context
        [self performSelectorOnMainThread:@selector(createFramebuffer) withObject:self waitUntilDone:YES];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
}


- (BOOL)presentFramebuffer
{
    // setFramebuffer must have been called before presentFramebuffer, therefore
    // we know the context is valid and has been set for this (render) thread
    // Bind the colour render buffer and present it
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    
    return [context presentRenderbuffer:GL_RENDERBUFFER];
}

- (void)createContent:(Vuforia::ImageTarget *)trackable
{
    //  Avoid querying the Book database when a bad target is found
    //  (Bad Targets are targets that are exists on the Books database but
    //  not on our own book database)
    
    const char* trackableID = trackable->getUniqueTargetId();
    
    if (![[BooksManager sharedInstance] isBadTarget:trackableID])
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kStartLoading" object:nil userInfo:nil];
        
        NSString *jsonFilename = [NSString stringWithUTF8String:trackable->getMetaData()];
        [[BooksManager sharedInstance] bookWithJSONFilename:jsonFilename withDelegate:self forTrackableID:trackableID];
    }
}

-(void)infoRequestDidFinishForBook:(Book *)theBook withTrackableID:(const char*)trackable byCancelling:(BOOL)cancelled
{
    if (theBook)
    {
        self.trackingTextureAvailable = NO;
        [[ImagesManager sharedInstance] imageForBook:theBook
                                        withDelegate:self];
    }
    else
    {
        if (!cancelled)
        {
            //  The trackable exists but it doesn't exist in our book database, so
            //  we'll mark that UniqueTargetId as a bad target
            [[BooksManager sharedInstance] addBadTargetId:trackable];
        }
        
        //  If theBook is nil, the loading UI would be shown forever and it
        //  won't scan again.  Send a notification to revert that state
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kStopLoading" object:nil userInfo:nil];
    }
}

-(void)imageRequestDidFinishForBook:(Book *)theBook withImage:(UIImage *)anImage byCancelling:(BOOL)cancelled;
{
    if (!cancelled)
    {
        if (anImage != nil)
        {
            // We now have the complete book (info and image), so enter content
            // mode.  We will return to scanning mode when the book view is
            // dismissed by the user
            [self enterContentMode];
            
            // Got an image for the book
            [[NSNotificationCenter defaultCenter] postNotificationName:@"kTargetFound" object:theBook userInfo:nil];
        }
        else
        {
            // Failed to get an image, but show the other information anyway (we
            // could take some different action in this case, if it were
            // considered an error, for example)
            
            // We now have the complete book (info and image), so enter content
            // mode.  We will return to scanning mode when the book view is
            // dismissed by the user
            [self enterContentMode];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:@"kTargetFound" object:theBook userInfo:nil];
        }
    }
    else
    {
        // If the network operation was cancelled, the loading UI would be
        // shown forever and scanning will not resume.  Send a notification to
        // revert that state
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kStopLoading" object:theBook userInfo:nil];
    }
}

- (void)targetLost
{
    if ((self.renderState == RS_NORMAL) || (self.renderState == RS_TRANSITION_TO_3D)|| (self.renderState == RS_OVERLAY)|| (self.renderState == RS_SCANNING))
    {
        self.transitionDuration = 0.5f;
        //When the target is lost starts the 3d to 2d Transition
        self.renderState = RS_TRANSITION_TO_2D;
        self.startTransition = YES;
    }
    
    self.isViewingTarget = NO;
}


- (void)targetReacquired
{
    if ((self.renderState == RS_NORMAL && self.isShowing2DOverlay) || self.renderState == RS_TRANSITION_TO_2D || self.renderState == RS_OVERLAY)
    {
        self.renderState = RS_TRANSITION_TO_3D;
        self.startTransition2Dto3D = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kTargetReacquired" object:nil userInfo:nil];
    }
}

- (void) enterContentMode
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker != nullptr) {
        Vuforia::TargetFinder* targetFinder = objectTracker->getTargetFinder();
        
        if (targetFinder != nullptr) {
            // Stop visual search
            [booksDelegate setVisualSearchOn:!targetFinder->stop()];
            
            // Remember we are in content mode
            self.scanningMode = NO;
        }
    }
    else
    {
        NSLog(@"Failed to enter content mode: ObjectTracker is NULL.");
    }
}


- (void) enterScanningMode
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    if (objectTracker != nullptr)
    {
        Vuforia::TargetFinder* targetFinder = objectTracker->getTargetFinder();
        if (targetFinder != nullptr)
        {
            // Start visual search
            [booksDelegate setVisualSearchOn:targetFinder->startRecognition()];
            
            // Clear all trackables created previously
            targetFinder->clearTrackables();
        }
        
        self.scanningMode = YES;
        
        self.isViewingTarget = NO;
        self.renderState = RS_SCANNING;
        self.isShowing2DOverlay = NO;
    }
    else
    {
        NSLog(@"Failed to enter scanning mode: ObjectTracker is NULL.");
    }
}

- (CGRect) rectForAR
{
    CGRect retVal = CGRectZero;
    
    retVal = CGRectMake(0, 0, self.frame.size.width * .6, self.frame.size.width * .6);
    retVal.origin.x = (self.frame.size.width - retVal.size.width) / 2;
    retVal.origin.y = (self.frame.size.height - retVal.size.height) / 2;
    
    return retVal;
}

- (BOOL)isPointInsideAROverlay:(CGPoint)aPoint
{
    BOOL retVal = NO;
    
    CGRect arRect = [self rectForAR];
    
    if (CGRectContainsPoint(arRect, aPoint))
    {
        retVal = YES;
    }
    
    return retVal;
}


- (bool) isTouchOnTarget:(CGPoint) touchPoint
{
    bool result = false;

    if (self.renderState == RS_NORMAL)
    {
        if (self.isViewingTarget || self.isShowing2DOverlay)
        {
            result = [self isPointInsideAROverlay:touchPoint];
        }
    }
    return result;
}

- (void)setOverlayLayer:(CALayer *)overlayLayer
{
    UIImage* image = nil;
    
    UIGraphicsBeginImageContext(overlayLayer.frame.size);
    {
        [overlayLayer renderInContext: UIGraphicsGetCurrentContext()];
        image = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();
    
    // Get the inner CGImage from the UIImage wrapper
    CGImageRef cgImage = image.CGImage;
    
    // Get the image size
    int width = (int)CGImageGetWidth(cgImage);
    int height = (int)CGImageGetHeight(cgImage);
    
    // Record the number of channels
    NSInteger channels = CGImageGetBitsPerPixel(cgImage)/CGImageGetBitsPerComponent(cgImage);
    
    // Generate a CFData object from the CGImage object (a CFData object represents an area of memory)
    CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    
    unsigned char* pngData = new unsigned char[width * height * channels];
    const long rowSize = width * channels;
    const unsigned char* pixels = (unsigned char*)CFDataGetBytePtr(imageData);
    
    // Copy the row data from bottom to top
    for (int i = 0; i < height; ++i)
    {
        memcpy(pngData + rowSize * i, pixels + rowSize * (height - 1 - i), width * channels);
    }
    
    glClearColor(0.0f, 0.0f, 0.0f, Vuforia::requiresAlpha() ? 0.0f : 1.0f);
    
    if (!self.trackingTextureIDSet)
    {
        glGenTextures(1, &trackingTextureID);
    }
    
    glBindTexture(GL_TEXTURE_2D, trackingTextureID);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_BGRA_EXT, GL_UNSIGNED_BYTE, (GLvoid*)pngData);
    
    self.trackingTextureIDSet = YES;
    self.trackingTextureAvailable = YES;
    
    delete[] pngData;
    CFRelease(imageData);
    
    self.renderState = RS_OVERLAY;
    // Books Sample Methods
    
}

@end

