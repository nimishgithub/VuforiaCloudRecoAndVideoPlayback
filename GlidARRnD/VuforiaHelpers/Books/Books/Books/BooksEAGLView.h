/*===============================================================================
Copyright (c) 2016 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import <UIKit/UIKit.h>

#import <Vuforia/UIGLViewProtocol.h>
#import "Texture.h"
#import "SampleApplicationSession.h"
#import "BooksControllerDelegateProtocol.h"
#import "Transition3Dto2D.h"
#import "BooksManagerDelegateProtocol.h"
#import "ImagesManagerDelegateProtocol.h"
#import "SampleGLResourceHandler.h"
#import "SampleAppRenderer.h"
#import "VideoPlayerHelper.h"

static const int kNumAugmentationTextures = 5;

// Books is a subclass of UIView and conforms to the informal protocol
// UIGLViewProtocol
@interface BooksEAGLView : UIView <UIGLViewProtocol, BooksManagerDelegateProtocol, ImagesManagerDelegateProtocol, SampleGLResourceHandler, SampleAppRendererControl> {
@private
    
    // OpenGL ES context
    EAGLContext *context;
    
    // The OpenGL ES names for the framebuffer and renderbuffers used to render
    // to this view
    GLuint defaultFramebuffer;
    GLuint colorRenderbuffer;
    GLuint depthRenderbuffer;

    // Shader handles
    GLuint shaderProgramID;
    GLint vertexHandle;
    GLint normalHandle;
    GLint textureCoordHandle;
    GLint mvpMatrixHandle;
    GLint texSampler2DHandle;
    
    // ----------------------------------------------------------------------------
    // Trackable Data Global Variables
    // ----------------------------------------------------------------------------
    
    const Vuforia::TrackableResult* trackableResult;
    Vuforia::Vec2F trackableSize;
    Vuforia::Matrix34F pose;
    Vuforia::Matrix44F modelViewMatrix;
    
    Vuforia::Matrix44F tapProjectionMatrix;
    
    // Texture used when rendering augmentation
    Texture* augmentationTexture[kNumAugmentationTextures];
    
    // Texture used when rendering augmentation
    SampleAppRenderer *sampleAppRenderer;
    
    
    // From VideoPlaybackEaglview---------------------
    
    // Instantiate one VideoPlayerHelper per target
    VideoPlayerHelper *videoPlayerHelper;
    float videoPlaybackTime;
    
    BooksViewController * videoPlaybackViewController;
    
    // Timer to pause on-texture video playback after tracking has been lost.
    // Note: written/read on two threads, but never concurrently
    NSTimer* trackingLostTimer;
    
    // Coordinates of user touch
    float touchLocation_X;
    float touchLocation_Y;
    
    // indicates how the video will be played
    BOOL playVideoFullScreen;
    
    // Lock to synchronise data that is (potentially) accessed concurrently
    NSLock* dataLock;
    

}

- (id)initWithFrame:(CGRect)frame  delegate:(id<BooksControllerDelegateProtocol>) delegate appSession:(SampleApplicationSession *) app;

// From videoPlaybackEaglView
- (void) willPlayVideoFullScreen:(BOOL) fullScreen;

- (void) prepare;
- (void) dismiss;
// From videoPlaybackEaglView

- (void)finishOpenGLESCommands;
- (void)freeOpenGLESResources;
- (void)updateRenderingPrimitives;
- (void) configureVideoBackgroundWithViewWidth:(float)viewWidth andHeight:(float)viewHeight;

- (void)setOverlayLayer:(CALayer *)overlayLayer;
- (void)enterScanningMode;
- (BOOL)isPointInsideAROverlay:(CGPoint)aPoint;
- (bool) isTouchOnTarget:(CGPoint) touchPoint;

- (void) setOrientationTransform:(CGAffineTransform)transform withLayerPosition:(CGPoint)pos;



@end

