//
//  ViewController.m
//  sample
//
//  Created by Igor Gorelik on 4/5/15.
//  Copyright (c) 2015 Igor Gorelik. All rights reserved.
//

#import "ViewController.h"

#import "Acidify.h"

@interface ViewController ()

- (IBAction)buttonPressed:(id)sender;
- (IBAction)textEditingDone:(id)sender;

@property (nonatomic, strong) IBOutlet UIWebView* webview;
@property (nonatomic, strong) IBOutlet UIButton* button;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSURLRequest* req = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.google.com"]];
    [self.webview loadRequest:req];
}

- (IBAction)buttonPressed:(id)sender {
    if ([Acidify isTripping]) {
        [Acidify stop];
    } else {
        [Acidify start];
    }
    
    if ([Acidify isTripping]) {
        [self.button setTitle:@"Stop" forState:UIControlStateNormal];
    } else {
        [self.button setTitle:@"Start" forState:UIControlStateNormal];
    }
}

- (IBAction)textEditingDone:(id)sender {
    [sender resignFirstResponder];
}

@end
