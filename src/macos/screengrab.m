#include "../screengrab.h"
#include "../endian.h"
#include <stdlib.h> /* malloc() */

#include <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

/*
 * macOS screen capture, ScreenCaptureKit edition.
 *
 * The previous implementation used `CGDisplayCreateImageForRect`, which Apple
 * marked unavailable in the macOS 15 SDK. ScreenCaptureKit
 * (`SCScreenshotManager`) is the supported replacement, available since
 * macOS 12.3. We expose the same synchronous interface to the rest of
 * libnut (the JS bindings call this on whatever thread N-API gives them and
 * expect a finished MMBitmap back) by wrapping SCK's async APIs with a
 * dispatch_semaphore round-trip.
 *
 * Two SCK calls run per screenshot:
 *   1. `+[SCShareableContent getShareableContentWithCompletionHandler:]` —
 *      enumerate displays and pick the main one. Mirrors the original
 *      `CGMainDisplayID()` selection.
 *   2. `+[SCScreenshotManager captureImageWithFilter:configuration:
 *      completionHandler:]` — synchronous-from-our-caller's-perspective
 *      bitmap capture against a filter scoped to the main display.
 *
 * Permissions:
 *   The first call after install triggers macOS's "Screen Recording" TCC
 *   prompt. CGDisplayCreateImageForRect required the same TCC grant on
 *   recent macOS, so the user experience is unchanged. A denied/undetermined
 *   permission state returns NULL from this function, which the caller (the
 *   JS binding) surfaces as a thrown error in JavaScript.
 *
 * Threading:
 *   Both SCK callbacks dispatch on a private SCStream queue, not the main
 *   thread. We block the calling thread via `dispatch_semaphore_wait`. The
 *   calling thread is whichever N-API binding context invoked us — never
 *   the main thread for stdio-based MCP servers, so there's no main-queue
 *   deadlock to worry about.
 *
 * Pixel format:
 *   SCK returns a CGImage, same as the old CG path. The downstream packing
 *   into MMBitmap is identical, byte-for-byte, to the original code (modulo
 *   the source of the CGImage).
 */

static double getPixelDensity() {
    @autoreleasepool {
        NSScreen *mainScreen = [NSScreen mainScreen];
        return mainScreen ? mainScreen.backingScaleFactor : 1.0;
    }
}

/*
 * Capture a CGImage for a rect on the main display via ScreenCaptureKit.
 * Returns NULL on any failure (permission denial, no displays, capture
 * error). Caller takes ownership of the returned CGImage.
 */
static CGImageRef captureImageForRect(MMRect rect) {
    if (@available(macOS 12.3, *)) {
        __block CGImageRef result = NULL;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (error != nil || content == nil || content.displays.count == 0) {
                dispatch_semaphore_signal(sem);
                return;
            }

            /* Pick the main display. SCShareableContent.displays is ordered
             * with displayID matching CGMainDisplayID() at index 0 in
             * practice, but match explicitly to be safe across multi-monitor
             * setups where the order can shift. */
            CGDirectDisplayID mainID = CGMainDisplayID();
            SCDisplay *target = nil;
            for (SCDisplay *display in content.displays) {
                if (display.displayID == mainID) {
                    target = display;
                    break;
                }
            }
            if (target == nil) {
                target = content.displays.firstObject;
            }

            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];

            SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
            /* sourceRect is in display points (origin top-left). config.width
             * / config.height define the OUTPUT pixel dimensions; setting
             * them to rect.size * scale keeps the resulting CGImage at the
             * same pixel count the CG path produced for a Retina display. */
            double scale = getPixelDensity();
            config.sourceRect = CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
            config.width = (size_t)(rect.size.width * scale);
            config.height = (size_t)(rect.size.height * scale);
            config.capturesAudio = NO;
            /* Match the prior CG behavior: cursor not baked into the capture. */
            config.showsCursor = NO;
            /* Ask for BGRA8 — same pixel format CGDisplayCreateImageForRect
             * returned, so the downstream MMBitmap packer doesn't need to
             * branch on channel order. */
            config.pixelFormat = kCVPixelFormatType_32BGRA;

            [SCScreenshotManager captureImageWithFilter:filter
                                          configuration:config
                                      completionHandler:^(CGImageRef captured, NSError *err) {
                if (captured != NULL && err == nil) {
                    CGImageRetain(captured);
                    result = captured;
                }
                dispatch_semaphore_signal(sem);
            }];
        }];

        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return result;
    } else {
        /* macOS 12.0 - 12.2: SCK isn't available. We deliberately don't fall
         * back to CGDisplayCreateImageForRect because the macOS 15 SDK
         * removes the function entirely — calling it on those older OSes
         * would still work at runtime, but the SDK we compile against on
         * modern CI runners no longer declares it. Returning NULL surfaces
         * a clean "screenshot unavailable" error at the JS layer rather
         * than a link failure at build. Users on 12.0-12.2 (well under 1%
         * of installed macOS by 2026) need to upgrade or use a different
         * tool for screen capture. */
        return NULL;
    }
}

MMBitmapRef copyMMBitmapFromDisplayInRect(MMRect rect) {
    CGImageRef image = captureImageForRect(rect);
    if (image == NULL) { return NULL; }

    CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (imageData == NULL) {
        CGImageRelease(image);
        return NULL;
    }

    long bufferSize = CFDataGetLength(imageData);
    size_t bytesPerPixel = (size_t) (CGImageGetBitsPerPixel(image) / 8);
    double pixelDensity = getPixelDensity();
    long expectedBufferSize = rect.size.width * pixelDensity * rect.size.height * pixelDensity * bytesPerPixel;

    if (expectedBufferSize < bufferSize) {
        size_t reportedByteWidth = CGImageGetBytesPerRow(image);
        size_t expectedByteWidth = expectedBufferSize / (rect.size.height * pixelDensity);

        uint8_t *buffer = malloc(expectedBufferSize);

        const uint8_t *dataPointer = CFDataGetBytePtr(imageData);
        size_t parts = bufferSize / reportedByteWidth;

        for (size_t idx = 0; idx < parts - 1; ++idx) {
            memcpy(buffer + (idx * expectedByteWidth),
                   dataPointer + (idx * reportedByteWidth),
                   expectedByteWidth
            );
        }

        MMBitmapRef bitmap = createMMBitmap(buffer,
                                            rect.size.width * pixelDensity,
                                            rect.size.height * pixelDensity,
                                            expectedByteWidth,
                                            CGImageGetBitsPerPixel(image),
                                            CGImageGetBitsPerPixel(image) / 8);

        CFRelease(imageData);
        CGImageRelease(image);
        return bitmap;
    } else {
        uint8_t *buffer = malloc(bufferSize);
        CFDataGetBytes(imageData, CFRangeMake(0, bufferSize), buffer);
        MMBitmapRef bitmap = createMMBitmap(buffer,
                                            CGImageGetWidth(image),
                                            CGImageGetHeight(image),
                                            CGImageGetBytesPerRow(image),
                                            CGImageGetBitsPerPixel(image),
                                            CGImageGetBitsPerPixel(image) / 8);

        CFRelease(imageData);
        CGImageRelease(image);
        return bitmap;
    }
}
