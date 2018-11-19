/*===============================================================================
 Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.
 
 Vuforia is a trademark of PTC Inc., registered in the United States and other
 countries.
 ===============================================================================*/

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

@class VideoPlaybackViewController;

// Media states
typedef enum tagMEDIA_STATE {
    REACHED_END,
    PAUSED,
    STOPPED,
    PLAYING,
    READY,
    PLAYING_FULLSCREEN,
    NOT_READY,
    ERROR
} MEDIA_STATE;


// Used to specify that playback should start from the current position when
// calling the load and play methods
static const float VIDEO_PLAYBACK_CURRENT_POSITION = -1.0f;


@interface VideoPlayerHelper : NSObject {
@private
    // AVPlayer
    CMTime mPlayerCursorStartPosition;
    
    // Native playback
    BOOL mResumeOnTexturePlayback;
    
    // Timing
    float mMediaStartTime;
    float mPlayerCursorPosition;
    BOOL mStopFrameTimer;
    
    // Asset
    BOOL mSeekRequested;
    float mRequestedCursorPosition;
    BOOL mLocalFile;
    BOOL mPlayImmediately;
    
    // Playback status
    MEDIA_STATE mMediaState;
    
    // Sample and pixel buffers for video frames
    CMSampleBufferRef mLatestSampleBuffer;
    CMSampleBufferRef mCurrentSampleBuffer;
    
    // Video properties
    CGSize mVideoSize;
    Float64 mVideoLengthSeconds;
    float mVideoFrameRate;
    BOOL mPlayVideo;
    
    // Audio properties
    float mCurrentVolume;
    BOOL mPlayAudio;
    
    // OpenGL data
    GLuint mVideoTextureHandle;
    
    // Audio/video synchronisation state
    enum tagSyncState {
        SYNC_DEFAULT,
        SYNC_READY,
        SYNC_AHEAD,
        SYNC_BEHIND
    } mSyncStatus;
    
    // Media player type
    enum tagPLAYER_TYPE {
        PLAYER_TYPE_ON_TEXTURE,
        PLAYER_TYPE_NATIVE
    } mPlayerType;
}

- (id)initWithRootViewController:(VideoPlaybackViewController *) rootViewController;
- (BOOL)load:(NSString*)filename playImmediately:(BOOL)playOnTextureImmediately fromPosition:(float)seekPosition;
- (BOOL)unload;
- (BOOL)isPlayableOnTexture;
- (BOOL)isPlayableFullscreen;
- (MEDIA_STATE)getStatus;
- (int)getVideoHeight;
- (int)getVideoWidth;
- (float)getLength;
- (BOOL)play:(BOOL)fullscreen fromPosition:(float)seekPosition;
- (BOOL)pause;
- (BOOL)stop;
- (GLuint)updateVideoData;
- (BOOL)seekTo:(float)position;
- (float)getCurrentPosition;
- (BOOL)setVolume:(float)volume;

@end
