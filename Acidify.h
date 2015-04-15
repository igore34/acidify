//
//  Acidify.h
//  screenshotta
//
//  Created by Igor Gorelik on 1/17/15.
//  Copyright (c) 2015 Igor Gorelik. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface Acidify : NSObject

/*
*  Start trip
*/
+ (void)start;

/* 
*  End trip
*/
+ (void)stop;

/* 
*  Check if tripping
*/
+ (BOOL)isTripping;

@end
