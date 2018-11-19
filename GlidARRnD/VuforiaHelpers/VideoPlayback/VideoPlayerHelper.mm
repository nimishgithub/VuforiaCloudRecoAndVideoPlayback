/*===============================================================================
 Copyright (c) 2015-2016,2018 PTC Inc. All Rights Reserved.
 
 Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.
 
 Vuforia is a trademark of PTC Inc., registered in the United States and other
 countries.
 ===============================================================================*/

#import "VideoPlayerHelper.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AudioServices.h>

#import "BooksViewController.h"

#ifdef DEBUG
#define DEBUGLOG(x) NSLog(x)
#else
#define DEBUGLOG(x)
#endif


// Constants
static const int TIMESCALE = 1000;  // 1 millisecond granularity for time

static const float PLAYER_CURSOR_POSITION_MEDIA_START = 0.0f;
static const float PLAYER_CURSOR_REQUEST_COMPLETE = -1.0f;

static const float PLAYER_VOLUME_DEFAULT = 1.0f;

// The number of bytes per texel (when using kCVPixelFormatType_32BGRA)
static const size_t BYTES_PER_TEXEL = 4;


// Key-value observation contexts
static void* AVPlayerItemStatusObservationContext = &AVPlayerItemStatusObservationContext;
static void* AVPlayerRateObservationContext = &AVPlayerRateObservationContext;
static void* AVPlayerViewControllerObservationContext = &AVPlayerViewControllerObservationContext;

// String constants
static NSString* const kStatusKey = @"status";
static NSString* const kTracksKey = @"tracks";
static NSString* const kRateKey = @"rate";

//---------------------------------------------------------------------------------
#pragma mark - VideoPlayerHelper private methods and properties

@interface VideoPlayerHelper ()

// We don't own rootViewController, so we use "weak" property
@property (nonatomic, weak) BooksViewController * rootViewController;
@property (nonatomic, strong) AVPlayerViewController* movieViewController;
@property (nonatomic, strong) AVPlayer* player;
@property (nonatomic, strong) NSTimer* frameTimer;
@property (nonatomic, strong) NSURL* mediaURL;
@property (nonatomic, strong) AVAssetReader* assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput* assetReaderTrackOutputVideo;
@property (nonatomic, strong) AVURLAsset* asset;
@property (nonatomic, strong) NSLock* dataLock;
@property (nonatomic, strong) NSLock* latestSampleBufferLock;

- (void)resetData;
- (BOOL)loadLocalMediaFromURL:(NSURL*)url;
- (BOOL)prepareAssetForPlayback;
- (BOOL)prepareAssetForReading:(CMTime)startTime;
- (void)prepareAVPlayer;
- (void)createFrameTimer;
- (void)getNextVideoFrame;
- (void)updatePlayerCursorPosition:(float)position;
- (void)frameTimerFired:(NSTimer*)timer;
- (BOOL)setVolumeLevel:(float)volume;
- (GLuint)createVideoTexture;
- (void)doSeekAndPlayAudio;
- (void)waitForFrameTimerThreadToEnd;
- (void)moviePlayerExitAtPosition:(CMTime)position;

@end

//------------------------------------------------------------------------------
#pragma mark - VideoPlayerHelper

@implementation VideoPlayerHelper

@synthesize rootViewController, movieViewController;
@synthesize player, frameTimer, dataLock, latestSampleBufferLock;
@synthesize mediaURL, assetReader, assetReaderTrackOutputVideo, asset;

//------------------------------------------------------------------------------
#pragma mark - Lifecycle
- (id)initWithRootViewController:(BooksViewController *) viewController
{
    self = [super init];
    
    if (self != nil)
    {
        // Set up app's audio session
        rootViewController = viewController;
        // **********************************************************************
        // *** MUST DO THIS TO BE ABLE TO GET THE VIDEO SAMPLES WITHOUT ERROR ***
        // **********************************************************************
        NSError *audioSessionError;
        [[AVAudioSession sharedInstance] setActive:YES error:&audioSessionError];
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&audioSessionError];
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&audioSessionError];
        
        if (audioSessionError != nil)
        {
            NSLog(@"Audio session init error: %@", audioSessionError.description);
        }
        
        // Initialise data
        [self resetData];
        
        // Video sample buffer lock
        latestSampleBufferLock = [[NSLock alloc] init];
        mLatestSampleBuffer = nil;
        mCurrentSampleBuffer = nil;
        
        // Class data lock
        dataLock = [[NSLock alloc] init];
        
    }
    
    return self;
}

- (void)dealloc
{
    // Stop playback
    (void)[self stop];
    [self resetData];
}


//------------------------------------------------------------------------------
#pragma mark - Class API
// Load a movie
- (BOOL)load:(NSString*)filename playImmediately:(BOOL)playOnTextureImmediately fromPosition:(float)seekPosition
{
    //    (void)AudioSessionSetActive(true);
    BOOL ret = NO;
    
    // Load only if there is no media currently loaded
    if (mMediaState != NOT_READY && mMediaState != ERROR) {
        NSLog(@"Media already loaded.  Unload current media first.");
    }
    else
    {
        // ----- Info: additional player threads not running at this point -----
        
        // Determine the type of file that has been requested (simply checking
        // for the presence of a "://" in filename for remote files)
        if ([filename rangeOfString:@"://"].location == NSNotFound) {
            // For on texture rendering, we need a local file
            mLocalFile = YES;
            NSString* fullPath = nil;
            
            // If filename is an absolute path (starts with a '/'), use it as is
            if ([filename rangeOfString:@"/"].location == 0)
            {
                fullPath = [NSString stringWithString:filename];
            }
            else
            {
                // filename is a relative path, play media from this app's
                // resources folder
                fullPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:filename];
            }
            
            mediaURL = [[NSURL alloc] initFileURLWithPath:fullPath];
            
            if (playOnTextureImmediately)
            {
                mPlayImmediately = playOnTextureImmediately;
            }
            
            if (seekPosition >= 0.0f)
            {
                // If a valid position has been requested, update the player
                // cursor, which will allow playback to begin from the
                // correct position
                [self updatePlayerCursorPosition:seekPosition];
            }
            
            ret = [self loadLocalMediaFromURL:mediaURL];
        }
        else
        {
            // FULLSCREEN only
            mLocalFile = NO;
            
            mediaURL = [[NSURL alloc] initWithString:filename];
            
            // The media is actually loaded when we initialise the
            // MPMoviePlayerController, which happens when we start playback
            mMediaState = READY;
            
            ret = YES;
        }
    }
    
    if (!ret)
    {
        // Some error occurred
        mMediaState = ERROR;
    }
    
    return ret;
}


// Unload the movie
- (BOOL)unload
{
    // Stop playback
    [self stop];
    [self resetData];
    
    return YES;
}


// Indicates whether the movie is playable on texture
- (BOOL)isPlayableOnTexture
{
    // We can render local files on texture
    return mLocalFile;
}


// Indicates whether the movie is playable in fullscreen mode
- (BOOL)isPlayableFullscreen
{
    // We can play both local and remote files in fullscreen mode
    return YES;
}


// Get the current player state
- (MEDIA_STATE)getStatus
{
    return mMediaState;
}


// Get the height of the video (on-texture player only)
- (int)getVideoHeight
{
    int ret = -1;
    
    // Return information only for local files
    if ([self isPlayableOnTexture])
    {
        if (mMediaState < NOT_READY)
        {
            ret = mVideoSize.height;
        }
        else
        {
            NSLog(@"Video height not available in current state");
        }
    }
    else
    {
        NSLog(@"Video height available only for video that is playable on texture");
    }
    
    return ret;
}


// Get the width of the video (on-texture player only)
- (int)getVideoWidth
{
    int ret = -1;
    
    // Return information only for local files
    if ([self isPlayableOnTexture])
    {
        if (mMediaState < NOT_READY)
        {
            ret = mVideoSize.width;
        }
        else
        {
            NSLog(@"Video width not available in current state");
        }
    }
    else
    {
        NSLog(@"Video width available only for video that is playable on texture");
    }
    
    return ret;
}


// Get the length of the media (on-texture player only)
- (float)getLength
{
    float ret = -1.0f;
    
    // Return information only for local files
    if ([self isPlayableOnTexture])
    {
        if (mMediaState < NOT_READY)
        {
            ret = (float)mVideoLengthSeconds;
        }
        else
        {
            NSLog(@"Video length not available in current state");
        }
    }
    else
    {
        NSLog(@"Video length available only for video that is playable on texture");
    }
    
    return ret;
}


// Play the asset
- (BOOL)play:(BOOL)fullscreen fromPosition:(float)seekPosition
{
    BOOL ret = NO;
    
    tagPLAYER_TYPE requestedPlayerType = fullscreen ? PLAYER_TYPE_NATIVE : PLAYER_TYPE_ON_TEXTURE;
    
    // If switching player type or not currently playing, and not in an unknown
    // or error state
    if ((mMediaState != PLAYING || mPlayerType != requestedPlayerType) && mMediaState < NOT_READY) {
        if (requestedPlayerType == PLAYER_TYPE_NATIVE)
        {
            BOOL playingOnTexture = NO;
            
            if (mMediaState == PLAYING)
            {
                // Pause the on-texture player
                [self pause];
                playingOnTexture = YES;
            }
            
            // ----- Info: additional player threads not running at this point -----
            
            // Use an AVPlayerViewController to play the media, owned by our
            // own MovieViewControllerClass
            if(movieViewController == nil)
            {
                movieViewController = [[AVPlayerViewController alloc] init];
            }
            
            movieViewController.modalPresentationStyle = UIModalPresentationFullScreen;
            
            // Set up observations
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(moviePlayerPlaybackDidFinish:)
                                                         name:AVPlayerItemDidPlayToEndTimeNotification
                                                       object:nil];
            
            [movieViewController.contentOverlayView addObserver:self
                                                     forKeyPath:@"bounds"
                                                        options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                                                        context:AVPlayerViewControllerObservationContext];
            
            if (mLocalFile) {
                
                if (seekPosition >= 0.0f)
                {
                    // If a valid position has been requested, update the player
                    // cursor, which will allow playback to begin from the
                    // correct position (it will be set when the media has
                    // loaded)
                    [self updatePlayerCursorPosition:seekPosition];
                }
                
                if (playingOnTexture)
                {
                    // Store the fact that video was playing on texture when
                    // fullscreen playback was requested
                    mResumeOnTexturePlayback = YES;
                }
            }
            else
            {
                // Always start playback of remote files from the beginning
                [self updatePlayerCursorPosition:PLAYER_CURSOR_POSITION_MEDIA_START];
            }
            
            // Set the movie player and play
            movieViewController.player = player;
            [movieViewController.player play];
            
            // Present the MovieViewController in the root view controller
            [rootViewController rootViewControllerPresentViewController:movieViewController inContext:NO];
            
            mMediaState = PLAYING_FULLSCREEN;
            
            ret = YES;
        }
        // On texture playback available only for local files
        else if (mLocalFile)
        {
            // ----- Info: additional player threads not running at this point -----
            
            // Seek to the current playback cursor time (this causes the start
            // and current times to be synchronised as well as starting AVPlayer
            // playback)
            mSeekRequested = YES;
            
            if (seekPosition >= 0.0f)
            {
                // If a valid position has been requested, update the player
                // cursor, which will allow playback to begin from the
                // correct position
                [self updatePlayerCursorPosition:seekPosition];
            }
            
            mMediaState = PLAYING;
            
            if (mPlayVideo)
            {
                // Start a timer to drive the frame pump (on a background
                // thread)
                [self performSelectorInBackground:@selector(createFrameTimer) withObject:nil];
            }
            else
            {
                // The asset contains no video.  Play the audio
                [player play];
            }
            
            ret = YES;
        }
    }
    
    if (ret)
    {
        mPlayerType = requestedPlayerType;
    }
    
    // ----- Info: additional player threads now running (if ret is YES) -----
    
    return ret;
}


// Pause playback (on-texture player only)
- (BOOL)pause
{
    BOOL ret = NO;
    
    // Control available only when playing on texture (not the native player)
    if (mMediaState == PLAYING)
    {
        if (mPlayerType == PLAYER_TYPE_ON_TEXTURE)
        {
            [dataLock lock];
            mMediaState = PAUSED;
            
            // Stop the audio (if there is any)
            if (mPlayAudio)
            {
                [player pause];
            }
            
            // Stop the frame pump thread
            [self waitForFrameTimerThreadToEnd];
            
            [dataLock unlock];
            ret = YES;
        }
        else
        {
            NSLog(@"Pause control available only when playing video on texture");
        }
    }
    
    return ret;
}


// Stop playback (on-texture player only)
- (BOOL)stop
{
    BOOL ret = NO;
    
    // Control available only when playing on texture (not the native player)
    if (mMediaState == PLAYING) {
        if (mPlayerType == PLAYER_TYPE_ON_TEXTURE) {
            [dataLock lock];
            mMediaState = STOPPED;
            
            // Stop the audio (if there is any)
            if (mPlayAudio)
            {
                [player pause];
            }
            
            // Stop the frame pump thread
            [self waitForFrameTimerThreadToEnd];
            
            // Reset the playback cursor position
            [self updatePlayerCursorPosition:PLAYER_CURSOR_POSITION_MEDIA_START];
            
            [dataLock unlock];
            ret = YES;
        }
        else
        {
            NSLog(@"Stop control available only when playing video on texture");
        }
    }
    else if (mMediaState == PLAYING_FULLSCREEN)
    {
        // Stop receiving notifications
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        
        // Dismiss the MovieViewController
        [rootViewController rootViewControllerDismissPresentedViewController];
        
        movieViewController = nil;
    }
    
    return ret;
}


// Seek to a particular playback cursor position (on-texture player only)
- (BOOL)seekTo:(float)position
{
    BOOL ret = NO;
    
    // Control available only when playing on texture (not the native player)
    if (mPlayerType == PLAYER_TYPE_ON_TEXTURE)
    {
        if (mMediaState < NOT_READY)
        {
            if (position < mVideoLengthSeconds)
            {
                // Set the new time (the actual seek occurs in getNextVideoFrame)
                [dataLock lock];
                [self updatePlayerCursorPosition:position];
                mSeekRequested = YES;
                [dataLock unlock];
                ret = YES;
            }
            else
            {
                NSLog(@"Requested seek position greater than video length");
            }
        }
        else
        {
            NSLog(@"Seek control not available in current state");
        }
    }
    else
    {
        NSLog(@"Seek control available only when playing video on texture");
    }
    
    return ret;
}


// Get the current playback cursor position (on-texture player only)
- (float)getCurrentPosition
{
    float ret = -1.0f;
    
    // Return information only when playing on texture (not the native player)
    if (mPlayerType == PLAYER_TYPE_ON_TEXTURE) {
        if (mMediaState < NOT_READY)
        {
            [dataLock lock];
            ret = mPlayerCursorPosition;
            [dataLock unlock];
        }
        else
        {
            NSLog(@"Current playback position not available in current state");
        }
    }
    else
    {
        NSLog(@"Current playback position available only when playing video on texture");
    }
    
    return ret;
}


// Set the volume level (on-texture player only)
- (BOOL)setVolume:(float)volume
{
    BOOL ret = NO;
    
    // Control available only when playing on texture (not the native player)
    if (mPlayerType == PLAYER_TYPE_ON_TEXTURE)
    {
        if (mMediaState < NOT_READY)
        {
            [dataLock lock];
            ret = [self setVolumeLevel:volume];
            [dataLock unlock];
        }
        else
        {
            NSLog(@"Volume control not available in current state");
        }
    }
    else
    {
        NSLog(@"Volume control available only when playing video on texture");
    }
    
    return ret;
}


// Update the OpenGL video texture with the latest available video data
- (GLuint)updateVideoData
{
    GLuint textureID = 0;
    
    // If currently playing on texture
    if (mMediaState == PLAYING && mPlayerType == PLAYER_TYPE_ON_TEXTURE) {
        [latestSampleBufferLock lock];
        
        unsigned char* pixelBufferBaseAddress = nil;
        CVImageBufferRef pixelBuffer = nil;
        
        // If we have a valid buffer, lock the base address of its pixel buffer
        if (mLatestSampleBuffer != nil)
        {
            pixelBuffer = CMSampleBufferGetImageBuffer(mLatestSampleBuffer);
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            pixelBufferBaseAddress = (unsigned char*)CVPixelBufferGetBaseAddress(pixelBuffer);
        }
        else
        {
            // No video sample buffer available: we may have been asked to
            // provide one before any are available, or we may have read all
            // available frames
            DEBUGLOG(@"No video sample buffer available");
        }
        
        if (pixelBufferBaseAddress != nil)
        {
            // If we haven't created the video texture, do so now
            if (mVideoTextureHandle == 0)
            {
                mVideoTextureHandle = [self createVideoTexture];
            }
            
            glBindTexture(GL_TEXTURE_2D, mVideoTextureHandle);
            const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            
            if (mVideoSize.width == bytesPerRow / BYTES_PER_TEXEL)
            {
                // No padding between lines of decoded video
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, mVideoSize.width, mVideoSize.height, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixelBufferBaseAddress);
            }
            else
            {
                // Decoded video contains padding between lines.  We must not
                // upload it to graphics memory as we do not want to display it
                
                // Allocate storage for the texture (correctly sized)
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, mVideoSize.width, mVideoSize.height, 0, GL_BGRA, GL_UNSIGNED_BYTE, nil);
                
                // Now upload each line of texture data as a sub-image
                for (int i = 0; i < mVideoSize.height; ++i)
                {
                    GLubyte* line = pixelBufferBaseAddress + i * bytesPerRow;
                    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, i, mVideoSize.width, 1, GL_BGRA, GL_UNSIGNED_BYTE, line);
                }
            }
            
            glBindTexture(GL_TEXTURE_2D, 0);
            
            // Unlock the buffers
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            
            textureID = mVideoTextureHandle;
        }
        
        [latestSampleBufferLock unlock];
    }
    
    return textureID;
}


//------------------------------------------------------------------------------
#pragma mark - AVPlayer observation
// Called when the value at the specified key path relative to the given object
// has changed.  Note, this method is invoked on the main queue
- (void)observeValueForKeyPath:(NSString*) path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context
{
    if (context == AVPlayerItemStatusObservationContext)
    {
        AVPlayerItemStatus status = static_cast<AVPlayerItemStatus>([[change objectForKey:NSKeyValueChangeNewKey] integerValue]);
        
        switch (status)
        {
            case AVPlayerItemStatusUnknown:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> AVPlayerItemStatusUnknown");
                if (mMediaState != PLAYING) {
                    mMediaState = NOT_READY;
                }
                break;
            case AVPlayerItemStatusReadyToPlay:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> AVPlayerItemStatusReadyToPlay");
                if (mMediaState != PLAYING) {
                    mMediaState = READY;
                }
                
                // If immediate on-texture playback has been requested, start
                // playback
                if (mPlayImmediately) {
                    [self play:NO fromPosition:VIDEO_PLAYBACK_CURRENT_POSITION];
                }
                
                break;
            case AVPlayerItemStatusFailed:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> AVPlayerItemStatusFailed");
                NSLog(@"Error - AVPlayer unable to play media: %@", [[[player currentItem] error] localizedDescription]);
                mMediaState = ERROR;
                break;
            default:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> Unknown");
                mMediaState = NOT_READY;
                break;
        }
    }
    else if (context == AVPlayerRateObservationContext && !mPlayVideo && mMediaState == PLAYING)
    {
        // We must detect the end of playback here when playing audio-only
        // media, because the video frame pump is not running (end of playback
        // is detected by the frame pump when playing video-only and audio/video
        // media).  We detect the difference between reaching the end of the
        // media and the user pausing/stopping playback by testing the value of
        // mediaState
        DEBUGLOG(@"AVPlayerRateObservationContext");
        float rate = [[change objectForKey:NSKeyValueChangeNewKey] floatValue];
        
        if (rate == 0.0f)
        {
            // Playback has reached end of media
            mMediaState = REACHED_END;
            
            // Reset AVPlayer cursor position (audio)
            CMTime startTime = CMTimeMake(PLAYER_CURSOR_POSITION_MEDIA_START * TIMESCALE, TIMESCALE);
            [player seekToTime:startTime];
        }
    }
    else if(context == AVPlayerViewControllerObservationContext)
    {
        if([path isEqualToString:@"bounds"])
        {
            // Check if the new size is equals to the screen, that would mean that the new size is full screen
            CGSize newBoundsSize = [[change objectForKey:NSKeyValueChangeNewKey] CGRectValue].size;
            CGSize screenBoundsSize = [UIScreen mainScreen].bounds.size;
            BOOL exitedFullscreen = CGSizeEqualToSize(newBoundsSize, screenBoundsSize);
            
            if(exitedFullscreen)
            {
                [self moviePlayerDidExitFullscreen];
            }
        }
    }
}


//------------------------------------------------------------------------------
#pragma mark - MPMoviePlayerController observation
// Called when the movie player's media playback ends
- (void)moviePlayerPlaybackDidFinish:(NSNotification*)notification
{
    DEBUGLOG(@"moviePlayerPlaybackDidFinish");
    mResumeOnTexturePlayback = NO;
    [self moviePlayerExitAtPosition:CMTimeMake(PLAYER_CURSOR_POSITION_MEDIA_START * TIMESCALE, TIMESCALE)];
}


- (void)moviePlayerDidExitFullscreen
{
    DEBUGLOG(@"moviePlayerDidExitFullscreen");
    CMTime currentTime = [movieViewController.player currentTime];
    if(CMTIME_IS_VALID(currentTime))
    {
        currentTime = CMTime(kCMTimeZero);
    }
    
    [self moviePlayerExitAtPosition:currentTime];
    
}


- (void)moviePlayerExitAtPosition:(CMTime)position
{
#ifdef DEBUG
    NSLog(@"moviePlayerExitAtPosition: %lf", CMTimeGetSeconds(position));
#endif
    
    // Dismiss the MovieViewController
    if(mMediaState == PLAYING_FULLSCREEN)
    {
        [rootViewController rootViewControllerDismissPresentedViewController];
    }
    
    [self updatePlayerCursorPosition:PLAYER_CURSOR_POSITION_MEDIA_START];
    
    [dataLock lock];
    
    // Update the playback cursor position
    if(CMTIME_IS_VALID(position))
    {
        [self.player.currentItem seekToTime:position];
        [self updatePlayerCursorPosition:CMTimeGetSeconds(position)];
    }
    else
    {
        NSLog(@"Exit position not valid");
    }
    
    [dataLock unlock];
    
    // If video was playing on texture before switching to fullscreen mode,
    // restart playback
    if (mResumeOnTexturePlayback)
    {
        mResumeOnTexturePlayback = NO;
        [self play:NO fromPosition:VIDEO_PLAYBACK_CURRENT_POSITION];
    }
    else {
        mMediaState = PAUSED;
    }
}


//------------------------------------------------------------------------------
#pragma mark - Private methods
- (void)resetData
{
    // ----- Info: additional player threads not running at this point -----
    
    // Reset media state and information
    mMediaState = NOT_READY;
    mSyncStatus = SYNC_DEFAULT;
    mPlayerType = PLAYER_TYPE_ON_TEXTURE;
    mRequestedCursorPosition = PLAYER_CURSOR_REQUEST_COMPLETE;
    mPlayerCursorPosition = PLAYER_CURSOR_POSITION_MEDIA_START;
    mPlayImmediately = NO;
    mVideoSize.width = 0.0f;
    mVideoSize.height = 0.0f;
    mVideoLengthSeconds = 0.0f;
    mVideoFrameRate = 0.0f;
    mPlayAudio = NO;
    mPlayVideo = NO;
    
    // Remove KVO observers
    [[player currentItem] removeObserver:self forKeyPath:kStatusKey];
    [player removeObserver:self forKeyPath:kRateKey];
    
    // Release AVPlayer, AVAsset, etc.
    player = nil;
    asset = nil;
    assetReader = nil;
    assetReaderTrackOutputVideo = nil;
    movieViewController = nil;
    mediaURL = nil;
}


- (BOOL)loadLocalMediaFromURL:(NSURL*)url
{
    BOOL ret = NO;
    asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    
    if (asset != nil)
    {
        // We can now attempt to load the media, so report success.  We will
        // discover if the load actually completes successfully when we are
        // called back by the system
        ret = YES;
        
        [asset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:kTracksKey] completionHandler:
         ^{
             // Completion handler block (dispatched on main queue when loading
             // completes)
             dispatch_async(dispatch_get_main_queue(),
                            ^{
                                NSError *error = nil;
                                AVKeyValueStatus status = [self->asset statusOfValueForKey:kTracksKey error:&error];
                                
                                if (status == AVKeyValueStatusLoaded)
                                {
                                    // Asset loaded, retrieve info and prepare
                                    // for playback
                                    if (![self prepareAssetForPlayback])
                                    {
                                        NSLog(@"Error - Unable to prepare media for playback");
                                        self->mMediaState = ERROR;
                                    }
                                }
                                else
                                {
                                    // Error
                                    NSLog(@"Error - The asset's tracks were not loaded: %@", [error localizedDescription]);
                                    self->mMediaState = ERROR;
                                }
                            });
         }];
    }
    
    return ret;
}


// Prepare the AVURLAsset for playback
- (BOOL)prepareAssetForPlayback
{
    // Get video properties
    mVideoSize = [[[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0] naturalSize];
    mVideoLengthSeconds = CMTimeGetSeconds([asset duration]);
    
    // Start playback at time 0.0
    mPlayerCursorStartPosition = kCMTimeZero;
    
    // Start playback at full volume (audio mix level, not system volume level)
    mCurrentVolume = PLAYER_VOLUME_DEFAULT;
    
    // Create asset tracks for reading
    BOOL ret = [self prepareAssetForReading:mPlayerCursorStartPosition];
    
    if (ret) {
        if (mPlayAudio)
        {
            // Prepare the AVPlayer to play the audio
            [self prepareAVPlayer];
        }
        else
        {
            // Inform our client that the asset is ready to play
            mMediaState = READY;
        }
    }
    
    return ret;
}


// Prepare the AVURLAsset for reading so we can obtain video frame data from it
- (BOOL)prepareAssetForReading:(CMTime)startTime
{
    BOOL ret = YES;
    NSError* error = nil;
    
    // ===== Video =====
    // Get the first video track
    AVAssetTrack* assetTrackVideo = nil;
    NSArray* arrayTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if ([arrayTracks count] > 0)
    {
        mPlayVideo = YES;
        assetTrackVideo = [arrayTracks objectAtIndex:0];
        mVideoFrameRate = [assetTrackVideo nominalFrameRate];
        
        // Create an asset reader for the video track
        assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        
        // Create an output for the video track
        NSDictionary* outputSettings = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
        assetReaderTrackOutputVideo = [[AVAssetReaderTrackOutput alloc] initWithTrack:assetTrackVideo outputSettings:outputSettings];
        
        // Add the video output to the asset reader
        if ([assetReader canAddOutput:assetReaderTrackOutputVideo])
        {
            [assetReader addOutput:assetReaderTrackOutputVideo];
        }
        
        // Set the time range
        CMTimeRange requiredTimeRange = CMTimeRangeMake(startTime, kCMTimePositiveInfinity);
        [assetReader setTimeRange:requiredTimeRange];
        
        // Start reading the track
        [assetReader startReading];
        
        if ([assetReader status] != AVAssetReaderStatusReading)
        {
            NSLog(@"Error - AVAssetReader not in reading state");
            ret = NO;
        }
    }
    else
    {
        NSLog(@"***** No video tracks in asset *****");
    }
    
    // ===== Audio =====
    // Get the first audio track
    arrayTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if ([arrayTracks count] > 0)
    {
        mPlayAudio = YES;
        AVAssetTrack* assetTrackAudio = [arrayTracks objectAtIndex:0];
        
        AVMutableAudioMixInputParameters* audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParameters];
        [audioInputParams setVolume:mCurrentVolume atTime:mPlayerCursorStartPosition];
        [audioInputParams setTrackID:[assetTrackAudio trackID]];
        
        NSArray* audioParams = [NSArray arrayWithObject:audioInputParams];
        AVMutableAudioMix* audioMix = [AVMutableAudioMix audioMix];
        [audioMix setInputParameters:audioParams];
        
        AVPlayerItem* item = [player currentItem];
        [item setAudioMix:audioMix];
    }
    else
    {
        NSLog(@"***** No audio tracks in asset *****");
    }
    
    return ret;
}


// Prepare the AVPlayer object for media playback
- (void)prepareAVPlayer
{
    // Create a player item
    AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
    
    // Add player item status KVO observer
    NSKeyValueObservingOptions opts = NSKeyValueObservingOptionNew;
    [item addObserver:self forKeyPath:kStatusKey options:opts context:AVPlayerItemStatusObservationContext];
    
    // Create an AV player
    player = [[AVPlayer alloc] initWithPlayerItem:item];
    
    // Add player rate KVO observer
    [player addObserver:self forKeyPath:kRateKey options:opts context:AVPlayerRateObservationContext];
}


// Video frame pump timer callback
- (void)frameTimerFired:(NSTimer*)timer;
{
    if (!mStopFrameTimer) {
        [self getNextVideoFrame];
    }
    else {
        // NSTimer invalidate must be called on the timer's thread
        [frameTimer invalidate];
    }
}


// Decode the next video frame and make it available for use (do not assume the
// timer driving the frame pump will be accurate)
- (void)getNextVideoFrame
{
    // Synchronise access to publicly accessible internal data.  We use tryLock
    // here to prevent possible deadlock when pause or stop are called on
    // another thread
    if (![dataLock tryLock]) {
        return;
    }
    
    @try {
        // If we've been told to seek to a new time, do so now
        if (mSeekRequested)
        {
            mSeekRequested = NO;
            [self doSeekAndPlayAudio];
        }
        
        // Simple video synchronisation mechanism:
        // If the video frame time is within tolerance, make it available to our
        // client.  This state is SYNC_READY.
        // If the video frame is behind, throw it away and get the next one.  We
        // will either catch up with the reference time (and become SYNC_READY),
        // or run out of frames.  This state is SYNC_BEHIND.
        // If the video frame is ahead, make it available to the client, but do
        // not retrieve more frames until the reference time catches up.  This
        // state is SYNC_AHEAD.
        
        while (mSyncStatus != SYNC_READY) {
            Float64 delta;
            
            if (mSyncStatus != SYNC_AHEAD) {
                mCurrentSampleBuffer = [assetReaderTrackOutputVideo copyNextSampleBuffer];
            }
            
            if (mCurrentSampleBuffer == nil)
            {
                // Failed to read the next sample buffer
                break;
            }
            
            // Get the time stamp of the video frame
            CMTime frameTimeStamp = CMSampleBufferGetPresentationTimeStamp(mCurrentSampleBuffer);
            
            // Get the time since playback began
            mPlayerCursorPosition = CACurrentMediaTime() - mMediaStartTime;
            CMTime caCurrentTime = CMTimeMake(mPlayerCursorPosition * TIMESCALE, TIMESCALE);
            
            // Compute delta of video frame and current playback times
            delta = CMTimeGetSeconds(caCurrentTime) - CMTimeGetSeconds(frameTimeStamp);
            
            if (delta < 0)
            {
                delta *= -1;
                mSyncStatus = SYNC_AHEAD;
            }
            else
            {
                mSyncStatus = SYNC_BEHIND;
            }
            
            if (delta < 1 / mVideoFrameRate)
            {
                // Video in sync with audio
                mSyncStatus = SYNC_READY;
            }
            else if (mSyncStatus == SYNC_AHEAD)
            {
                // Video ahead of audio: stay in SYNC_AHEAD state, exit loop
                break;
            }
            else
            {
                // Video behind audio (SYNC_BEHIND): stay in loop
                CFRelease(mCurrentSampleBuffer);
            }
        }
    }
    @catch (NSException* e)
    {
        // Assuming no other error, we are trying to read past the last sample
        // buffer
        DEBUGLOG(@"Failed to copyNextSampleBuffer");
        mCurrentSampleBuffer = nil;
    }
    
    if (mCurrentSampleBuffer == nil)
    {
        switch ([assetReader status])
        {
            case AVAssetReaderStatusCompleted:
                // Playback has reached the end of the video media
                DEBUGLOG(@"getNextVideoFrame -> AVAssetReaderStatusCompleted");
                mMediaState = REACHED_END;
                break;
            case AVAssetReaderStatusFailed:
            {
                NSError* error = [assetReader error];
                NSLog(@"getNextVideoFrame -> AVAssetReaderStatusFailed: %@", [error localizedDescription]);
                mMediaState = ERROR;
                break;
            }
            default:
                DEBUGLOG(@"getNextVideoFrame -> Unknown");
                break;
        }
        
        // Stop the frame pump
        [frameTimer invalidate];
        
        // Reset the playback cursor position
        [self updatePlayerCursorPosition:PLAYER_CURSOR_POSITION_MEDIA_START];
    }
    
    [latestSampleBufferLock lock];
    
    if (mLatestSampleBuffer != nil)
    {
        // Release the latest sample buffer
        CFRelease(mLatestSampleBuffer);
    }
    
    if (mSyncStatus == SYNC_READY)
    {
        // Audio and video are synchronised, so transfer ownership of
        // currentSampleBuffer to latestSampleBuffer
        mLatestSampleBuffer = mCurrentSampleBuffer;
    }
    else
    {
        // Audio and video not synchronised, do not supply a sample buffer
        mLatestSampleBuffer = nil;
    }
    
    [latestSampleBufferLock unlock];
    
    // Reset the sync status, unless video is ahead of the reference time
    if (mSyncStatus != SYNC_AHEAD)
    {
        mSyncStatus = SYNC_DEFAULT;
    }
    
    [dataLock unlock];
}


// Create a timer to drive the video frame pump
- (void)createFrameTimer
{
    @autoreleasepool
    {
        frameTimer = [NSTimer scheduledTimerWithTimeInterval:(1 / mVideoFrameRate) target:self selector:@selector(frameTimerFired:) userInfo:nil repeats:YES];
        
        // Set thread priority explicitly to the default value (0.5),
        // to ensure that the frameTimer can tick at the expected rate.
        [[NSThread currentThread] setThreadPriority:0.5];
        
        // Execute the current run loop (it will terminate when its associated timer
        // becomes invalid)
        [[NSRunLoop currentRunLoop] run];
        
        // Release frameTimer (set to nil to notify any threads waiting for the
        // frame pump to stop)
        frameTimer = nil;
        
        // Make sure we do not leak a sample buffer
        [latestSampleBufferLock lock];
        
        if (mLatestSampleBuffer != nil)
        {
            // Release the latest sample buffer
            CFRelease(mLatestSampleBuffer);
            mLatestSampleBuffer = nil;
        }
        
        [latestSampleBufferLock unlock];
    }
}


// Create an OpenGL texture for the video data
- (GLuint)createVideoTexture
{
    GLuint handle;
    glGenTextures(1, &handle);
    glBindTexture(GL_TEXTURE_2D, handle);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    
    return handle;
}


// Update the playback cursor position
// [Always called with dataLock locked]
- (void)updatePlayerCursorPosition:(float)position
{
    // Set the player cursor position so the native player can restart from the
    // appropriate time if play (fullscreen) is called again
    mPlayerCursorPosition = position;
    
    // Set the requested cursor position to cause the on texture player to seek
    // to the appropriate time if play (on texture) is called again
    mRequestedCursorPosition = position;
}


// Set the volume level (on-texture player only)
// [Always called with dataLock locked]
- (BOOL)setVolumeLevel:(float)volume
{
    BOOL ret = NO;
    NSArray* arrayTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    
    if ([arrayTracks count] > 0) {
        // Get the asset's audio track
        AVAssetTrack* assetTrackAudio = [arrayTracks objectAtIndex:0];
        
        if (assetTrackAudio != nil)
        {
            // Set up the audio mix
            AVMutableAudioMixInputParameters* audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParameters];
            [audioInputParams setVolume:volume atTime:mPlayerCursorStartPosition];
            [audioInputParams setTrackID:[assetTrackAudio trackID]];
            NSArray* audioParams = [NSArray arrayWithObject:audioInputParams];
            AVMutableAudioMix* audioMix = [AVMutableAudioMix audioMix];
            [audioMix setInputParameters:audioParams];
            
            // Apply the audio mix the the AVPlayer's current item
            [[player currentItem] setAudioMix:audioMix];
            
            // Store the current volume level
            mCurrentVolume = volume;
            ret = YES;
        }
    }
    
    return ret;
}


// Seek to a particular playback position (when playing on texture)
// [Always called with dataLock locked]
- (void)doSeekAndPlayAudio
{
    if ( mRequestedCursorPosition > PLAYER_CURSOR_REQUEST_COMPLETE)
    {
        // Store the cursor position from which playback will start
        mPlayerCursorStartPosition = CMTimeMake(mRequestedCursorPosition * TIMESCALE, TIMESCALE);
        
        // Ensure the volume continues at the current level
        [self setVolumeLevel:mCurrentVolume];
        
        if (mPlayAudio)
        {
            // Set AVPlayer cursor position (audio)
            [player seekToTime:mPlayerCursorStartPosition];
        }
        
        // Set the asset reader's start time to the new time (video)
        [self prepareAssetForReading:mPlayerCursorStartPosition];
        
        // Indicate seek request is complete
        mRequestedCursorPosition = PLAYER_CURSOR_REQUEST_COMPLETE;
    }
    
    if (mPlayAudio) {
        // Play the audio (if there is any)
        [player play];
    }
    
    // Store the media start time for reference
    mMediaStartTime = CACurrentMediaTime() - mPlayerCursorPosition;
}


// Request the frame timer to terminate and wait for its thread to end
- (void)waitForFrameTimerThreadToEnd
{
    mStopFrameTimer = YES;
    
    // Wait for the frame pump thread to stop
    while (frameTimer != nil)
    {
        [NSThread sleepForTimeInterval:0.01];
    }
    
    mStopFrameTimer = NO;
}
@end
