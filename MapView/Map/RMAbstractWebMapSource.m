//
// RMAbstractWebMapSource.m
//
// Copyright (c) 2008-2012, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "RMAbstractWebMapSource.h"
#import "RMTileCache.h"
#import "RMTileDownloadOperation.h"

@implementation RMAbstractWebMapSource
{
    NSOperationQueue *fetchQueue;
    NSUInteger staticCount;
}

@synthesize retryCount, waitSeconds;
@synthesize maxConcurrentOperationCount, executingOperationCount, totalOperationCount;

- (id)init
{
    if (!(self = [super init]))
        return nil;

    self.retryCount = RMAbstractWebMapSourceDefaultRetryCount;
    self.waitSeconds = RMAbstractWebMapSourceDefaultWaitSeconds;

    fetchQueue = [[NSOperationQueue alloc] init];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mapScrollChanged:) name:kRMMapScrollChangeNotification object:nil];
    
    staticCount = 0;
    
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kRMMapScrollChangeNotification object:nil];
 
    [fetchQueue cancelAllOperations];
    [fetchQueue release]; fetchQueue = nil;
    [super dealloc];
}

- (void)setMaxConcurrentOperationCount:(NSUInteger)count
{
    fetchQueue.maxConcurrentOperationCount = count;
}

- (NSUInteger)maxConcurrentOperationCount
{
    return fetchQueue.maxConcurrentOperationCount;
}

- (NSUInteger)executingOperationCount
{
    return [[[fetchQueue operations] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isExecuting = YES"]] count] + staticCount;
}

- (NSUInteger)totalOperationCount
{
    return [[fetchQueue operations] count] + staticCount;
}

- (void)mapScrollChanged:(NSNotification *)notification
{
    if ([fetchQueue operationCount])
    {
        [fetchQueue cancelAllOperations];
        
        int count = fetchQueue.maxConcurrentOperationCount;
        
        [fetchQueue release];
        
        fetchQueue = [[NSOperationQueue alloc] init];
        fetchQueue.maxConcurrentOperationCount = count;
    }
}

- (NSURL *)URLForTile:(RMTile)tile
{
    @throw [NSException exceptionWithName:@"RMAbstractMethodInvocation"
                                   reason:@"URLForTile: invoked on RMAbstractWebMapSource. Override this method when instantiating an abstract class."
                                 userInfo:nil];
}

- (NSArray *)URLsForTile:(RMTile)tile
{
    return [NSArray arrayWithObjects:[self URLForTile:tile], nil];
}

- (UIImage *)imageForTile:(RMTile)tile inCache:(RMTileCache *)tileCache
{
    return [self imageForTile:tile inCache:tileCache asynchronously:NO];
}

- (UIImage *)imageForTile:(RMTile)tile inCache:(RMTileCache *)tileCache asynchronously:(BOOL)async
{
    __block UIImage *image = nil;

	tile = [[self mercatorToTileProjection] normaliseTile:tile];
    image = [tileCache cachedImage:tile withCacheKey:[self uniqueTilecacheKey]];

    if (image)
        return image;

    if ( ! async)
    {
        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            [[NSNotificationCenter defaultCenter] postNotificationName:RMTileRequested object:[NSNumber numberWithUnsignedLongLong:RMTileKey(tile)]];
        });
    }

    [tileCache retain];

    NSArray *URLs = [self URLsForTile:tile];

    if ([URLs count] > 1)
    {
        // fill up collection array with placeholders
        //
        NSMutableArray *tilesData = [NSMutableArray arrayWithCapacity:[URLs count]];

        for (NSUInteger p = 0; p < [URLs count]; ++p)
            [tilesData addObject:[NSNull null]];

        dispatch_group_t fetchGroup = dispatch_group_create();

        for (NSUInteger u = 0; u < [URLs count]; ++u)
        {
            NSURL *currentURL = [URLs objectAtIndex:u];

            dispatch_group_async(fetchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void)
            {
                NSData *tileData = nil;

                for (NSUInteger try = 0; tileData == nil && try < self.retryCount; ++try)
                {
                    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:currentURL];
                    [request setTimeoutInterval:(self.waitSeconds / (CGFloat)self.retryCount)];
                    tileData = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
                }

                if (tileData)
                {
                    @synchronized(self)
                    {
                        // safely put into collection array in proper order
                        //
                        [tilesData replaceObjectAtIndex:u withObject:tileData];
                    };
                }
            });
        }

        // wait for whole group of fetches (with retries) to finish, then clean up
        //
        dispatch_group_wait(fetchGroup, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * self.waitSeconds));
        dispatch_release(fetchGroup);

        // composite the collected images together
        //
        for (NSData *tileData in tilesData)
        {
            if (tileData && [tileData isKindOfClass:[NSData class]] && [tileData length])
            {
                if (image != nil)
                {
                    UIGraphicsBeginImageContext(image.size);
                    [image drawAtPoint:CGPointMake(0,0)];
                    [[UIImage imageWithData:tileData] drawAtPoint:CGPointMake(0,0)];

                    image = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                }
                else
                {
                    image = [UIImage imageWithData:tileData];
                }
            }
        }
    }
    else
    {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[URLs objectAtIndex:0]];
        [request setTimeoutInterval:self.waitSeconds];
        
        if (async)
        {
            RMTileDownloadOperation *op = [[[RMTileDownloadOperation alloc] init] autorelease];
            
            op.downloadURL = request.URL;
            
            op.completionBlock = ^(void)
            {
                dispatch_async(dispatch_get_main_queue(), ^(void)
                {
                    [tileCache addImage:[UIImage imageWithData:op.downloadData] forTile:tile withCacheKey:[self uniqueTilecacheKey]];
                });
            };
            
            [fetchQueue addOperation:op];
            
            [tileCache release];
            
            return nil;
        }
        
        staticCount++;
        
        NSData *tileData = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
        
        image = [UIImage imageWithData:tileData];
        
        staticCount--;
    }
    
    if (image)
        [tileCache addImage:image forTile:tile withCacheKey:[self uniqueTilecacheKey]];

    [tileCache release];

    dispatch_async(dispatch_get_main_queue(), ^(void)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:RMTileRetrieved object:[NSNumber numberWithUnsignedLongLong:RMTileKey(tile)]];
    });

    return image;
}

@end
