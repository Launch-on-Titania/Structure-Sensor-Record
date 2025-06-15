/*
  This file is part of the Structure SDK.
  Copyright © 2019 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import <UIKit/UIKit.h>
#import <Structure/Structure.h>
#import <Structure/STCaptureSession.h>

@interface ViewController : UIViewController <STCaptureSessionDelegate>
+ (instancetype)viewController;
@property (strong, nonatomic) UIButton* recordButton;
@property (strong, nonatomic) UIButton* stopButton;
@property (strong, nonatomic) UIButton* finishButton;

@property (strong, nonatomic) UILabel *recordLabel;
@property (nonatomic, strong) NSString *saveDirectoryByDate;

@property (assign, nonatomic) BOOL recordEnabled;
@property (assign, nonatomic) NSInteger imageIndex;
@property (assign, nonatomic) NSInteger depthIndex;
@property (strong, nonatomic) NSTimer *updateTimer;
//@property (weak, nonatomic) IBOutlet UILabel *recordLabel;
@end
