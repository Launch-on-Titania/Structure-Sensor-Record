/*
  This file is part of the Structure SDK.
  Copyright © 2019 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import "ViewController.h"
#import <Structure/Structure.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <algorithm>

const int downsample_rate = 2;

static void logToFile(NSString* content) {
    // Generate timestamp
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    // Combine content with timestamp
    NSString *textToWrite = [NSString stringWithFormat:@"\n\n// Timestamp: %@\n%@\n", timestamp, content];

    // Getting a path to the Documents directory
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSLog(@"The first element of this directory: %@", [paths objectAtIndex:0]);
    NSString *documentsDirectory = [paths objectAtIndex:0];

    // Specifying the file name
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent:@"log.txt"];

    // Writing the text to the file
    NSError *error;
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[textToWrite dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        // File does not exist, create it
        [textToWrite writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"Error writing file: %@", [error localizedDescription]);
        }
    }
}


//------------------------------------------------------------------------------

static bool convertYCbCrToBGRA(
    size_t width,
    size_t height,
    const uint8_t* yData,
    const uint8_t* cbcrData,
    uint8_t* rgbaData,
    uint8_t alpha,
    size_t yBytesPerRow,
    size_t cbCrBytesPerRow,
    size_t rgbaBytesPerRow)
{
    assert(width <= rgbaBytesPerRow);

    // Input RGBA buffer:

    vImage_Buffer rgbaBuffer{
        .data = (void*)rgbaData,
        .width = (size_t)width,
        .height = (size_t)height,
        .rowBytes = rgbaBytesPerRow};

    // Destination Y, CbCr buffers:

    vImage_Buffer cbCrBuffer{
        .data = (void*)cbcrData,
        .width = (size_t)width / 2,
        .height = (size_t)height / 2,
        .rowBytes = (size_t)cbCrBytesPerRow // 2 bytes per pixel (Cb+Cr)
    };

    vImage_Buffer yBuffer{
        .data = (void*)yData,
        .width = (size_t)width,
        .height = (size_t)height,
        .rowBytes = (size_t)yBytesPerRow};

    vImage_Error error = kvImageNoError;

    // Conversion information:
    static vImage_YpCbCrToARGB info;
    {
        static bool infoGenerated = false;

        if (!infoGenerated)
        {
            vImage_Flags flags = kvImageNoFlags;

            vImage_YpCbCrPixelRange pixelRange{
                .Yp_bias = 0,
                .CbCr_bias = 128,
                .YpRangeMax = 255,
                .CbCrRangeMax = 255,
                .YpMax = 255,
                .YpMin = 0,
                .CbCrMax = 255,
                .CbCrMin = 1};

            error = vImageConvert_YpCbCrToARGB_GenerateConversion(
                kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
                &pixelRange,
                &info,
                kvImage420Yp8_CbCr8,
                kvImageARGB8888,
                flags);

            if (kvImageNoError != error)
                return false;

            infoGenerated = true;
        }
    }

    static const uint8_t permuteMapBGRA[4]{3, 2, 1, 0};
    error = vImageConvert_420Yp8_CbCr8ToARGB8888(
        &yBuffer,
        &cbCrBuffer,
        &rgbaBuffer,
        &info,
        permuteMapBGRA,
        255,
        kvImageNoFlags | kvImageDoNotTile // Disable multithreading.
    );
    return kvImageNoError == error;
}

//------------------------------------------------------------------------------

struct AppStatus
{
    NSString* const pleaseConnectSensorMessage = @"Please connect Structure Sensor.";
    NSString* const pleaseChargeSensorMessage = @"Please charge Structure Sensor.";
    NSString* const needColorCameraAccessMessage =
        @"This app requires camera access to capture color.\nAllow access by going to Settings → Privacy → Camera.";
    NSString* const sensorIsWakingUpMessage = @"Sensor is initializing(Sad). So, wait... hahaha";

    // Whether there is currently a message to show.
    bool needsDisplayOfStatusMessage = false;

    // Flag to disable entirely status message display.
    bool statusMessageDisabled = false;
};

//------------------------------------------------------------------------------

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    STCaptureSession* _captureSession;

    UIImageView* _depthImageView;
    UIImageView* _normalsImageView;
    UIImageView* _colorImageView;

    uint8_t* _coloredDepthBuffer;
    uint8_t* _normalsBuffer;
    uint8_t* _colorImageBuffer;

    STNormalEstimator* _normalsEstimator;

    UILabel* _statusLabel;

    AppStatus _appStatus;
    
    NSString* dateString;
    
    NSString* saveDirectoryByDate;
}

- (void)renderDepthFrame:(STDepthFrame*)depthFrame;
- (void)renderNormalsFrame:(STDepthFrame*)normalsFrame;
- (void)renderColorFrame:(STColorFrame*)colorFrame;

@end

//------------------------------------------------------------------------------

@implementation ViewController

+ (instancetype)viewController
{
    return [[ViewController alloc] initWithNibName:@"ViewController" bundle:nil];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    dateString = [formatter stringFromDate:[NSDate date]];
    
    self.recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.recordButton setTitle:@"Record" forState:UIControlStateNormal];
    self.recordButton.frame = CGRectMake(75, 175, 75, 50); // Example frame
    [self.recordButton addTarget:self action:@selector(recordButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recordButton];
    
    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.stopButton setTitle:@"Stop" forState:UIControlStateNormal];
    self.stopButton.frame = CGRectMake(75, 250, 75, 50); // Example frame
    [self.stopButton addTarget:self action:@selector(stopButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.stopButton];

    self.finishButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.finishButton setTitle:@"Finish" forState:UIControlStateNormal];
    self.finishButton.frame = CGRectMake(75, 325, 75, 50); // Example frame
    [self.finishButton addTarget:self action:@selector(finishButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.finishButton];
    
    // Initialize and configure the label
    self.recordLabel = [[UILabel alloc] initWithFrame:CGRectMake(300, 150, 300, 100)]; // Example frame
    self.recordLabel.text = dateString;
    self.recordLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.recordLabel];
    
    self.imageIndex = 0;
    self.depthIndex = 0;
   
    self.recordEnabled = NO;
    
    // Create an STCaptureSession instance
    _captureSession = [STCaptureSession newCaptureSession];

    NSDictionary* sensorConfig = @{
        kSTCaptureSessionOptionColorResolutionKey: @(STCaptureSessionColorResolution640x480),
        kSTCaptureSessionOptionDepthSensorVGAEnabledIfAvailableKey: @(YES),
        kSTCaptureSessionOptionColorMaxFPSKey: @(30.0f),
        kSTCaptureSessionOptionDepthSensorEnabledKey: @(YES),
        kSTCaptureSessionOptionUseAppleCoreMotionKey: @(YES),
        kSTCaptureSessionOptionSimulateRealtimePlaybackKey: @(YES),
    };

    // Set the lens detector on, and default lens state as "non-WVL" mode
    _captureSession.lens = STLensNormal;
    _captureSession.lensDetection = STLensDetectorOn;

    // Set ourself as the delegate to receive sensor data.
    _captureSession.delegate = self;
    [_captureSession startMonitoringWithOptions:sensorConfig];
    
    // delete directories
    NSString* saveDirectory =
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    
    saveDirectoryByDate = [saveDirectory stringByAppendingPathComponent:dateString];
    
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath: saveDirectoryByDate withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"Error creating directory: %@", error);
    } else {
        NSLog(@"Directory created successfully.");
    }
    
    NSString *directoryToRemove = [saveDirectoryByDate stringByAppendingPathComponent:@"depth"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryToRemove]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:directoryToRemove error:&error]) {
            NSLog(@"Error deleting directory: %@", error);
            // Handle the error appropriately
        } else {
            NSLog(@"Directory deleted successfully.");
        }
    } else {
        NSLog(@"Directory does not exist.");
    }
    
    directoryToRemove = [saveDirectoryByDate stringByAppendingPathComponent:@"rgb"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryToRemove]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:directoryToRemove error:&error]) {
            NSLog(@"Error deleting directory: %@", error);
            // Handle the error appropriately
        } else {
            NSLog(@"Directory deleted successfully.");
        }
    } else {
        NSLog(@"Directory does not exist.");
    }

    directoryToRemove = [saveDirectoryByDate stringByAppendingPathComponent:@"extrinsics.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryToRemove]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:directoryToRemove error:&error]) {
            NSLog(@"Error deleting directory: %@", error);
            // Handle the error appropriately
        } else {
            NSLog(@"Directory deleted successfully.");
        }
    } else {
        NSLog(@"Directory does not exist.");
    }    
    
    directoryToRemove = [saveDirectoryByDate stringByAppendingPathComponent:@"rgb_intrinsics.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryToRemove]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:directoryToRemove error:&error]) {
            NSLog(@"Error deleting directory: %@", error);
            // Handle the error appropriately
        } else {
            NSLog(@"Directory deleted successfully.");
        }
    } else {
        NSLog(@"Directory does not exist.");
    }
    
    directoryToRemove = [saveDirectoryByDate stringByAppendingPathComponent:@"depth_intrinsics.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryToRemove]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:directoryToRemove error:&error]) {
            NSLog(@"Error deleting directory: %@", error);
            // Handle the error appropriately
        } else {
            NSLog(@"Directory deleted successfully.");
        }
    } else {
        NSLog(@"Directory does not exist.");
    }
}


- (IBAction)recordButtonTapped:(id)sender{
    // Display the message in the label
    self.recordLabel.text = [[saveDirectoryByDate lastPathComponent] stringByAppendingFormat: @": Recording"];

    // Set the recordEnabled to true
    self.recordEnabled = YES;
}

- (IBAction)stopButtonTapped:(id)sender{
    // Display the message in the label
    self.recordLabel.text = [[saveDirectoryByDate lastPathComponent] stringByAppendingFormat: @": Idle"];

    // Set the recordEnabled to false
    self.recordEnabled = NO;
}

//- (IBAction)finishButtonTapped:(id)sender{
//    self.recordEnabled = NO;
//    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
//    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
//    dateString = [formatter stringFromDate:[NSDate date]];
//    NSString* saveDirectory =
//        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
//    saveDirectoryByDate = [saveDirectory stringByAppendingPathComponent:dateString];
//    
//    NSError* error = nil;
//    if (![[NSFileManager defaultManager] createDirectoryAtPath: saveDirectoryByDate withIntermediateDirectories:YES attributes:nil error:&error]) {
//        NSLog(@"Error creating directory: %@", error);
//    } else {
//        NSLog(@"Directory created successfully.");
//    }
//    
//    self.recordLabel.text = [[saveDirectoryByDate lastPathComponent] stringByAppendingFormat: @": Idle"];
//    
//    self.imageIndex = 0;
//    self.depthIndex = 0;
//}

- (IBAction)finishButtonTapped:(id)sender {
    NSLog(@"finishButtonTapped 已触发");

    if (self.updateTimer) {
        [self.updateTimer invalidate];
        self.updateTimer = nil;
    }

    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                        target:self
                                                      selector:@selector(updateLabel)
                                                      userInfo:nil
                                                       repeats:YES];
    
    self.imageIndex = 0;
    self.depthIndex = 0;
    
    [self updateLabel];
}

- (void)updateLabel {
    NSLog(@"updateLabel 已调用");

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss:S"];

    NSString *currentDateString = [formatter stringFromDate:[NSDate date]];

    NSString *saveDirectory =
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];

    NSString *saveDirectoryByDate = [saveDirectory stringByAppendingPathComponent:currentDateString];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:saveDirectoryByDate
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        NSLog(@"创建目录出错: %@", error);
    } else {
        NSLog(@"已成功创建目录: %@", saveDirectoryByDate);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.recordLabel.text = [[saveDirectoryByDate lastPathComponent] stringByAppendingFormat:@": Idle"];
        self.recordLabel.hidden = NO; // 确保未被隐藏
        self.recordLabel.textColor = [UIColor blackColor]; // 确保颜色正常
        NSLog(@"Label 文本已更新为：%@", self.recordLabel.text);
    });
}


- (void)dealloc
{
    free(_coloredDepthBuffer);
    free(_normalsBuffer);
    free(_colorImageBuffer);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    static BOOL fromLaunch = YES;

    if (!fromLaunch)
        return;

    // Create a UILabel in the center of our view to display status messages.

    if (!_statusLabel)
    {
        // We do this here instead of in viewDidLoad so that we get the correctly size/rotation view bounds.
        _statusLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
        _statusLabel.backgroundColor = [UIColor systemBackgroundColor];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.font = [UIFont systemFontOfSize:35.0];
        _statusLabel.numberOfLines = 2;
        _statusLabel.textColor = [UIColor labelColor];

        [self updateAppStatusMessage];

        [self.view addSubview:_statusLabel];
        [_statusLabel.layer setZPosition:1.0];
    }

    // Allocate the depth to surface normals converter class.
    _normalsEstimator = [[STNormalEstimator alloc] init];

    fromLaunch = NO;

    // From now on, make sure we get notified when the app becomes active to restore the sensor state if necessary.

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

// Create the subview here to get the correctly size/rotation view bounds
- (void)viewDidLayoutSubviews
{
    CGRect depthFrame = self.view.frame;
    depthFrame.size.height /= 2;
    depthFrame.origin.y = self.view.frame.size.height / 2;
    depthFrame.origin.x = 1;
    depthFrame.origin.x = -self.view.frame.size.width * 0.25;

    CGRect normalsFrame = self.view.frame;
    normalsFrame.size.height /= 2;
    normalsFrame.origin.y = self.view.frame.size.height / 2;
    normalsFrame.origin.x = 1;
    normalsFrame.origin.x = self.view.frame.size.width * 0.25;

    CGRect colorFrame = self.view.frame;
    colorFrame.size.height /= 2;
    colorFrame.origin.x = self.view.frame.size.width * 0.25;

    _coloredDepthBuffer = NULL;
    _normalsBuffer = NULL;
    _colorImageBuffer = NULL;

    _depthImageView = [[UIImageView alloc] initWithFrame:depthFrame];
    _depthImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:_depthImageView];

    _normalsImageView = [[UIImageView alloc] initWithFrame:normalsFrame];
    _normalsImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:_normalsImageView];

    _colorImageView = [[UIImageView alloc] initWithFrame:colorFrame];
    _colorImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:_colorImageView];

  [self addPoweredByStructureButton];
}

- (void)appDidBecomeActive
{
    [self updateAppStatusMessage];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)showAppStatusMessage:(NSString*)msg
{
    _appStatus.needsDisplayOfStatusMessage = true;

    [self.view.layer removeAllAnimations];

    [_statusLabel setText:msg];
    [_statusLabel setHidden:NO];

    // Progressively show the message label.

    [self.view setUserInteractionEnabled:false];
    [UIView animateWithDuration:0.5f animations:^{ self->_statusLabel.alpha = 1.0f; } completion:nil];
}

- (void)hideAppStatusMessage
{
    _appStatus.needsDisplayOfStatusMessage = false;

    [self.view.layer removeAllAnimations];

    [UIView animateWithDuration:0.5f animations:^{ self->_statusLabel.alpha = 0.0f; } completion:^(BOOL finished) {
        // If nobody called showAppStatusMessage before the end of the animation, do not hide it.

        if (!self->_appStatus.needsDisplayOfStatusMessage)
        {
            [self->_statusLabel setHidden:YES];
            [self.view setUserInteractionEnabled:true];
        }
    }];
}

- (void)updateAppStatusMessage
{
    // Skip everything if we should not show app status messages (e.g. in viewing state).
    if (_appStatus.statusMessageDisabled)
    {
        [self hideAppStatusMessage];
        return;
    }

    STCaptureSessionUserInstruction userInstructions = _captureSession.userInstructions;

    // First show sensor issues, if any.
    if (userInstructions & STCaptureSessionUserInstructionNeedToConnectSensor)
    {
        [self showAppStatusMessage:_appStatus.pleaseConnectSensorMessage];
        return;
    }

    if (_captureSession.sensorMode == STCaptureSessionSensorModeWakingUp)
    {
        [self showAppStatusMessage:_appStatus.sensorIsWakingUpMessage];
        return;
    }

    if (userInstructions & STCaptureSessionUserInstructionNeedToChargeSensor)
    {
        [self showAppStatusMessage:_appStatus.pleaseChargeSensorMessage];
    }

    // Then show color camera permission issues, if any.
    if (userInstructions & STCaptureSessionUserInstructionNeedToAuthorizeColorCamera)
    {
        [self showAppStatusMessage:_appStatus.needColorCameraAccessMessage];
        return;
    }

    // Ignore the FW update notification here, we don't need new firmware for Viewer.

    // If we reach this point, no status to show.
    [self hideAppStatusMessage];
}

- (bool)isConnected
{
    return _captureSession.sensorMode >= STCaptureSessionSensorModeNotConnected;
}

- (void)addPoweredByStructureButton
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button addTarget:self
               action:@selector(openDeveloperPortal)
     forControlEvents:UIControlEventTouchUpInside];
    [button setTitle:@"" forState:UIControlStateNormal];
    button.frame = CGRectMake((self.view.frame.size.width / 2) - 50, 10, 100.0, 30.0); // Placing the button at center top position
    [button setBackgroundImage:[UIImage imageNamed:@"APPROVED_Powered_By_StructureSDK_logo3"] forState:UIControlStateNormal];
    [self.view addSubview:button];
  }

//------------------------------------------------------------------------------

#pragma mark - STCaptureSession Delegate Methods

- (void)captureSession:(STCaptureSession*)captureSession sensorDidEnterMode:(STCaptureSessionSensorMode)mode
{
    switch (mode)
    {
        case STCaptureSessionSensorModeNotConnected: _captureSession.streamingEnabled = NO; break;
        case STCaptureSessionSensorModeStandby:
        case STCaptureSessionSensorModeWakingUp: break;
        case STCaptureSessionSensorModeReady: _captureSession.streamingEnabled = YES; break;
        case STCaptureSessionSensorModeBatteryDepleted: _captureSession.streamingEnabled = NO; break;
        // Fall through intentional
        case STCaptureSessionSensorModeUnknown:
        default:
            @throw [NSException exceptionWithName:@"Viewer" reason:@"Unknown STCaptureSessionSensorMode!" userInfo:nil];
            break;
    }
    [self updateAppStatusMessage];
}

- (void)captureSession:(STCaptureSession*)captureSession colorCameraDidEnterMode:(STCaptureSessionColorCameraMode)mode
{
    switch (mode)
    {
        case STCaptureSessionColorCameraModeReady: break;
        case STCaptureSessionColorCameraModePermissionDenied: break;
        // Fall through intentional
        case STCaptureSessionColorCameraModeUnknown:
        default:
            @throw [NSException exceptionWithName:@"Viewer" reason:@"Unknown STCaptureSessionColorCameraMode!"
                                         userInfo:nil];
            break;
    }
    [self updateAppStatusMessage];
}

- (void)captureSession:(STCaptureSession*)captureSession
    sensorChargerStateChanged:(STCaptureSessionSensorChargerState)chargerState
{
    switch (chargerState)
    {
        case STCaptureSessionSensorChargerStateConnected: break;
        case STCaptureSessionSensorChargerStateDisconnected:
            // Do nothing, we only need to handle low-power notifications based on the sensor mode.
            break;
        case STCaptureSessionSensorChargerStateUnknown:
        default:
            @throw [NSException exceptionWithName:@"Viewer" reason:@"Unknown STCaptureSessionSensorChargerState!"
                                         userInfo:nil];
            break;
    }
    [self updateAppStatusMessage];
}

- (void)captureSession:(STCaptureSession*)captureSession didStartAVCaptureSession:(AVCaptureSession*)avCaptureSession
{}

- (void)captureSession:(STCaptureSession*)captureSession didStopAVCaptureSession:(AVCaptureSession*)avCaptureSession
{}

- (void)captureSession:(STCaptureSession*)captureSession
       didOutputSample:(NSDictionary*)sample
                  type:(STCaptureSessionSampleType)type
{
    // Rendering is performed on the main thread since we use UIKit APIs
    // See https://developer.apple.com/documentation/uikit/uiview#1652866
    switch (type)
    {
        case STCaptureSessionSampleTypeSensorDepthFrame:
        {
            STDepthFrame* depthFrame = [sample objectForKey:kSTCaptureSessionSampleEntryDepthFrame];
            [depthFrame applyExpensiveCorrection];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self renderDepthFrame:depthFrame];
                [self renderNormalsFrame:depthFrame];
            });
            break;
        }
        case STCaptureSessionSampleTypeIOSColorFrame:
        {
            break;
            // We only need to render synchronized frame.
//            STColorFrame* colorFrame = [sample objectForKey:kSTCaptureSessionSampleEntryIOSColorFrame];
//            dispatch_async(dispatch_get_main_queue(), ^{ [self renderColorFrame:colorFrame.sampleBuffer]; });
//            break;
        }
        case STCaptureSessionSampleTypeSynchronizedFrames:
        {
            STDepthFrame* depthFrame = [sample objectForKey:kSTCaptureSessionSampleEntryDepthFrame];
            STColorFrame* colorFrame = [sample objectForKey:kSTCaptureSessionSampleEntryIOSColorFrame];
            [depthFrame applyExpensiveCorrection];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self renderDepthFrame:depthFrame];
                [self renderNormalsFrame:depthFrame];
                [self renderColorFrame:colorFrame];
            });
            break;
        }
        case STCaptureSessionSampleTypeDeviceMotionData:
        case STCaptureSessionSampleTypeAccelData:
        case STCaptureSessionSampleTypeGyroData:
            // We'll always skip IMU / motion data. Adding cases here so as not
            // to spam the logs by saying "skipping capture session sample type 6".
            break;
        case STCaptureSessionSampleTypeUnknown:
            @throw [NSException exceptionWithName:@"Viewer" reason:@"Unknown STCaptureSessionSampleType!" userInfo:nil];
            break;
        default: NSLog(@"Skipping Capture Session sample type: %ld", static_cast<long>(type)); break;
    }
}

- (void)captureSession:(STCaptureSession*)captureSession onLensDetectorOutput:(STDetectedLensStatus)detectedLensStatus
{
    switch (detectedLensStatus)
    {
        case STDetectedLensNormal:
            // Detected a WVL is not attached to the bracket.
            NSLog(@"Detected that the WVL is off!");
            break;
        case STDetectedLensWideVisionLens:
            // Detected a WVL is attached to the bracket.
            NSLog(@"Detected that the WVL is on!");
            break;
        case STDetectedLensPerformingInitialDetection:
            // Triggers immediately when detector is turned on. Can put a message here
            // showing the user that the detector is working and they need to pan the
            // camera for best results
            NSLog(@"Performing initial detection!");
            break;
        case STDetectedLensUnsure: break;
        default:
            @throw [NSException exceptionWithName:@"Viewer" reason:@"Unknown STDetectedLensStatus!" userInfo:nil];
            break;
    }
}

//------------------------------------------------------------------------------

#pragma mark - Rendering

- (void)renderDepthFrame:(STDepthFrame*)depthFrame
{
    if (depthFrame == nil)
    {
        return;
    }
    size_t cols = depthFrame.width;
    size_t rows = depthFrame.height;
    

    STDepthToRgba* depthToRgba =
        [[STDepthToRgba alloc] initWithOptions:@{kSTDepthToRgbaStrategyKey: @(STDepthToRgbaStrategyRedToBlueGradient)}];
    _coloredDepthBuffer = [depthToRgba convertDepthFrameToRgba:depthFrame];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    bitmapInfo |= kCGBitmapByteOrder32Big;

    NSData* data = [NSData dataWithBytes:_coloredDepthBuffer length:cols * rows * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data); // toll-free ARC bridging

    CGImageRef imageRef = CGImageCreate(
        cols, // width
        rows, // height
        8, // bits per component
        8 * 4, // bits per pixel
        cols * 4, // bytes per row
        colorSpace, // Quartz color space
        bitmapInfo, // Bitmap info (alpha channel?, order, etc)
        provider, // Source of data for bitmap
        NULL, // decode
        false, // pixel interpolation
        kCGRenderingIntentDefault); // rendering intent

    // Assign CGImage to UIImage
    _depthImageView.image = [UIImage imageWithCGImage:imageRef];
    
    
//    NSString* saveDirectory =
//        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    if (self.recordEnabled == YES ){
        NSError *error = nil;
        
        NSString *extrinsicsFile = [saveDirectoryByDate stringByAppendingPathComponent:@"extrinsics.txt"];
        NSString *intrinsicsFile = [saveDirectoryByDate stringByAppendingPathComponent:@"depth_intrinsics.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:extrinsicsFile]) {
            GLKMatrix4 extrinsic = depthFrame.iOSColorFromDepthExtrinsics;
            FILE *file = fopen([extrinsicsFile UTF8String], "w");
            fwrite(extrinsic.m, sizeof(float), 16, file);
            fclose(file);
            STIntrinsics intrinsics = depthFrame.intrinsics;
            FILE *intrinsics_file = fopen([intrinsicsFile UTF8String],"w");
            NSString* intrinsics_data = [NSString stringWithFormat:@"%f %f %f %f %f %f %d %d",intrinsics.fx,intrinsics.fy,intrinsics.cx,intrinsics.cy,intrinsics.k1, intrinsics.k2 ,intrinsics.height,intrinsics.width];
            fprintf(intrinsics_file, "%s", [intrinsics_data UTF8String]);
            fclose(intrinsics_file);
        }
        
        
        
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[saveDirectoryByDate stringByAppendingPathComponent:@"depth"] withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating directory: %@", error);
        } else {
            NSLog(@"Directory created successfully.");
        }
        if (self.depthIndex % downsample_rate == 0){
            NSInteger index = self.depthIndex / downsample_rate;
            NSString* filePath = [saveDirectoryByDate stringByAppendingPathComponent:[NSString stringWithFormat:@"depth/%04zu_depth.bin", index]];
            
            FILE *file = fopen([filePath UTF8String], "wb");
            if (file != NULL) {
                fwrite(depthFrame.depthInMillimeters, sizeof(float), depthFrame.width * depthFrame.height, file);
                fclose(file);
                NSLog(@"Array written to file successfully.");
            } else {
                NSLog(@"Failed to open file for writing.");
            }
        }
       
        
        self.depthIndex += 1;
    }
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

- (void)renderNormalsFrame:(STDepthFrame*)depthFrame
{
    if (depthFrame == nil)
    {
        return;
    }
    // Estimate surface normal direction from depth float values
    STNormalFrame* normalsFrame = [_normalsEstimator calculateNormalsWithDepthFrame:depthFrame];

    size_t cols = normalsFrame.width;
    size_t rows = normalsFrame.height;

    // Convert normal unit vectors (ranging from -1 to 1) to RGB (ranging from 0 to 255)
    // Z can be slightly positive in some cases too!
    if (_normalsBuffer == NULL)
    {
        _normalsBuffer = (uint8_t*)malloc(cols * rows * 4);
    }
    for (size_t i = 0; i < cols * rows; i++)
    {
        _normalsBuffer[4 * i + 0] = (uint8_t)(((normalsFrame.normals[i].x / 2) + 0.5) * 255);
        _normalsBuffer[4 * i + 1] = (uint8_t)(((normalsFrame.normals[i].y / 2) + 0.5) * 255);
        _normalsBuffer[4 * i + 2] = (uint8_t)(((normalsFrame.normals[i].z / 2) + 0.5) * 255);
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    bitmapInfo |= kCGBitmapByteOrder32Little;

    NSData* data = [NSData dataWithBytes:_normalsBuffer length:cols * rows * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);

    CGImageRef imageRef = CGImageCreate(
        cols,
        rows,
        8,
        8 * 4,
        cols * 4,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault);

    _normalsImageView.image = [[UIImage alloc] initWithCGImage:imageRef];

    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

- (void)renderColorFrame:(STColorFrame*)colorFrame
{
    CMSampleBufferRef yCbCrSampleBuffer = colorFrame.sampleBuffer;
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(yCbCrSampleBuffer);
 
    // get image size
    size_t cols = CVPixelBufferGetWidth(pixelBuffer);
    size_t rows = CVPixelBufferGetHeight(pixelBuffer);

    // allocate memory for RGBA image for the first time
    if (_colorImageBuffer == NULL)
        _colorImageBuffer = (uint8_t*)malloc(cols * rows * 4);

    // color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // get y plane
    const uint8_t* yData = reinterpret_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));

    // get cbCr plane
    const uint8_t* cbCrData = reinterpret_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));

    size_t yBytePerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t cbcrBytePerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    assert(yBytePerRow == cbcrBytePerRow);

    uint8_t* bgra = _colorImageBuffer;

    bool ok = convertYCbCrToBGRA(cols, rows, yData, cbCrData, bgra, 0xff, yBytePerRow, cbcrBytePerRow, 4 * cols);

    if (!ok)
    {
        NSLog(@"YCbCr to BGRA conversion failed.");
        CGColorSpaceRelease(colorSpace);
        return;
    }

    NSData* data = [[NSData alloc] initWithBytes:_colorImageBuffer length:rows * cols * 4];

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    bitmapInfo |= kCGBitmapByteOrder32Little;

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);

    CGImageRef imageRef = CGImageCreate(
        cols,
        rows,
        8,
        8 * 4,
        cols * 4,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault);

    _colorImageView.image = [[UIImage alloc] initWithCGImage:imageRef];


//    NSString* saveDirectory =
//        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    if (self.recordEnabled == YES ){
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[saveDirectoryByDate stringByAppendingPathComponent:@"rgb"] withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating directory: %@", error);
        } else {
            NSLog(@"Directory created successfully.");
        }
        if (self.imageIndex % downsample_rate==0){
            NSInteger index = self.imageIndex/downsample_rate;
            NSString* filePath = [saveDirectoryByDate stringByAppendingPathComponent:[NSString stringWithFormat:@"rgb/%04zu_color.png", index]];
            
            NSData *pngData = UIImagePNGRepresentation([[UIImage alloc] initWithCGImage:imageRef]);
            [pngData writeToFile:filePath options:NSDataWritingAtomic error:&error];
        }
        
        
        NSString *intrinsicsFile = [saveDirectoryByDate stringByAppendingPathComponent:@"rgb_intrinsics.txt"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:intrinsicsFile]) {
            STIntrinsics intrinsics = colorFrame.intrinsics;
            FILE *intrinsics_file = fopen([intrinsicsFile UTF8String],"w");
            NSString* intrinsics_data = [NSString stringWithFormat:@"%f %f %f %f %f %f %d %d",intrinsics.fx,intrinsics.fy,intrinsics.cx,intrinsics.cy,intrinsics.k1, intrinsics.k2 ,intrinsics.height,intrinsics.width];
            fprintf(intrinsics_file, "%s", [intrinsics_data UTF8String]);
            fclose(intrinsics_file);
        }
        
        self.imageIndex += 1;
    }
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

#pragma mark - UI Callbacks
- (void)openDeveloperPortal
{
  [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://structure.io/developers"] options:@{} completionHandler:nil];
}

  
@end
