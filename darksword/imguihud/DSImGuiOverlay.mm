//
//  DSImGuiOverlay.mm
//  DarkSpeed
//
//  Two renderers built on one ImGui core:
//    * an interactive overlay window inside the DarkSpeed app (Metal + touches)
//    * an offscreen panel renderer that draws the compact HUD panel with ImGui
//      into a Metal texture and hands the pixels back as PNG, so SpringBoard
//      only has to display an image and never runs ImGui itself.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <os/lock.h>
#import <os/log.h>

#include <cmath>
#include <cfloat>
#include <cstring>
#include <mutex>

#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_metal.h"

#include "HUDHelper.h"
#include "DSBridge.h"
#include "DSImGuiOverlay.h"
#include "DSImGuiHUDCore.hpp"

/// Window title is shared with DSImGuiHUDUi::BuildWindow; the overlay uses it
/// to decide whether a touch belongs to ImGui or to the app underneath.
static const char *const kDSImGuiWindowTitle = "DarkSpeed ImGui HUD##darkspeed-imgui";

/// Dear ImGui keeps its current context in a process-wide variable and is not
/// thread safe. The overlay renders on the main thread while the HUD panel
/// rasteriser runs on the DarkSpeed bridge queue, so every entry point takes
/// this recursive lock (outer lock is always this one).
static std::recursive_mutex g_imguiMutex;

#pragma mark - Shared error string

static os_unfair_lock g_errorLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_lastError = @"";

static void DSImGuiSetError(NSString *message) {
    os_unfair_lock_lock(&g_errorLock);
    g_lastError = [message copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    if (g_lastError.length > 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSImGui] %{public}@", g_lastError);
    }
}

NSString *DSImGuiLastError(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *copy = g_lastError;
    os_unfair_lock_unlock(&g_errorLock);
    return copy;
}

BOOL DSImGuiCompiledIn(void) { return YES; }

#pragma mark - Forward declarations

static BOOL DSImGuiPointCaptured(void);
static BOOL DSImGuiPointInsideWindow(CGPoint point);
static void DSImGuiFeedMouse(CGPoint point, bool down);
void DSImGuiOverlaySetVisible(BOOL visible);
BOOL DSImGuiOverlayIsVisible(void);

#pragma mark - Overlay view

/// Transparent view that owns the CAMetalLayer and only swallows touches that
/// land inside the ImGui window, so the rest of the app stays usable.
@interface DSImGuiOverlayView : UIView
@end

@implementation DSImGuiOverlayView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return DSImGuiPointCaptured() && DSImGuiPointInsideWindow(point);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (touch) DSImGuiFeedMouse([touch locationInView:self], true);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (touch) DSImGuiFeedMouse([touch locationInView:self], true);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (touch) DSImGuiFeedMouse([touch locationInView:self], false);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (touch) DSImGuiFeedMouse([touch locationInView:self], false);
}

@end

#pragma mark - Display link proxy

@interface DSImGuiDisplayLinkProxy : NSObject
@property (nonatomic, copy) void (^handler)(void);
+ (instancetype)proxyWithHandler:(void (^)(void))handler;
- (void)tick:(CADisplayLink *)link;
@end

@implementation DSImGuiDisplayLinkProxy

+ (instancetype)proxyWithHandler:(void (^)(void))handler {
    DSImGuiDisplayLinkProxy *proxy = [[DSImGuiDisplayLinkProxy alloc] init];
    proxy.handler = handler;
    return proxy;
}

- (void)tick:(CADisplayLink *)link {
    (void)link;
    if (self.handler) self.handler();
}

@end

#pragma mark - Renderer state

namespace {

struct DSImGuiCtx {
    ImGuiContext *ctx = nullptr;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    bool metalReady = false;
};

bool DSImGuiEnsureBackend(DSImGuiCtx &state) {
    if (!state.ctx || !state.device) return false;
    if (!state.metalReady) {
        if (!ImGui_ImplMetal_Init(state.device)) {
            DSImGuiSetError(@"ImGui Metal backend init failed");
            return false;
        }
        state.metalReady = true;
    }
    return true;
}

struct DSImGuiOverlayState {
    DSImGuiCtx ctx;
    UIWindow *window = nil;
    DSImGuiOverlayView *view = nil;
    CAMetalLayer *layer = nil;
    CADisplayLink *link = nil;
    DSImGuiDisplayLinkProxy *proxy = nil;
    double lastTimestamp = 0;
    bool visible = false;
    bool wantsVisible = false;
    bool retryScheduled = false;
    bool warmedUp = false;
    bool warmupFailed = false;
    float winMinX = 0;
    float winMinY = 0;
    float winMaxX = 0;
    float winMaxY = 0;
};

DSImGuiOverlayState &OverlayState(void) {
    static DSImGuiOverlayState state;
    return state;
}

UIWindowScene *DSImGuiActiveWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        return windowScene;
    }
    return nil;
}

bool DSImGuiReadPixels(id<MTLCommandQueue> queue, id<MTLTexture> texture, void *out,
                       size_t outLength, NSUInteger width, NSUInteger height) {
    NSUInteger bytesPerRow = width * 4;
    size_t needed = (size_t)bytesPerRow * height;
    if (!out || outLength < needed) return false;

    id<MTLBuffer> buffer = [queue.device newBufferWithLength:needed
                                                    options:MTLResourceStorageModeShared];
    if (!buffer) return false;

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) return false;
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:buffer
             destinationOffset:0
        destinationBytesPerRow:bytesPerRow
      destinationBytesPerImage:needed];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    if (commandBuffer.status == MTLCommandBufferStatusError) return false;
    memcpy(out, buffer.contents, needed);
    return true;
}

bool DSImGuiEnsureContextOverlay(DSImGuiCtx &state, float pointSize, float scale) {
    if (scale < 1.0f) scale = 1.0f;
    if (!state.ctx) {
        state.ctx = ImGui::CreateContext();
        if (!state.ctx) {
            DSImGuiSetError(@"ImGui context creation failed");
            return false;
        }
        ImGui::SetCurrentContext(state.ctx);
        DSImGuiHUDUi::ApplyDarkTheme();
        // Bake the atlas for the screen scale, then scale it back down so the
        // interactive window keeps working in points.
        DSImGuiHUDUi::SetupFontAtlas(pointSize * scale);
        ImGuiIO &io = ImGui::GetIO();
        io.FontGlobalScale = 1.0f / scale;
    }
    ImGui::SetCurrentContext(state.ctx);
    if (!state.device) {
        state.device = MTLCreateSystemDefaultDevice();
        if (!state.device) {
            DSImGuiSetError(@"This device exposes no Metal device");
            return false;
        }
        state.queue = [state.device newCommandQueue];
        if (!state.queue) {
            DSImGuiSetError(@"Metal command queue creation failed");
            return false;
        }
    }
    return DSImGuiEnsureBackend(state);
}

struct DSImGuiPanelRenderer {
    std::mutex lock;
    DSImGuiCtx state;
    id<MTLTexture> texture = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
    bool failed = false;
};

DSImGuiPanelRenderer &PanelRenderer(void) {
    static DSImGuiPanelRenderer renderer;
    return renderer;
}

bool DSImGuiEnsureContext(DSImGuiCtx &state, float fontSize, float scale) {
    if (scale < 1.0f) scale = 1.0f;
    const float pixelSize = fontSize * scale;
    if (!state.ctx) {
        state.ctx = ImGui::CreateContext();
        if (!state.ctx) {
            DSImGuiSetError(@"ImGui context creation failed");
            return false;
        }
        ImGui::SetCurrentContext(state.ctx);
        DSImGuiHUDUi::ApplyDarkTheme();
        DSImGuiHUDUi::SetupFontAtlas(pixelSize);

        // Panel renderer works purely in pixels: one ImGui unit is one device
        // pixel and the atlas carries a matching glyph size.
        ImGuiIO &io = ImGui::GetIO();
        io.FontGlobalScale = 1.0f;
        io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    }
    ImGui::SetCurrentContext(state.ctx);
    if (!state.device) {
        state.device = MTLCreateSystemDefaultDevice();
        if (!state.device) {
            DSImGuiSetError(@"This device exposes no Metal device");
            return false;
        }
        state.queue = [state.device newCommandQueue];
        if (!state.queue) {
            DSImGuiSetError(@"Metal command queue creation failed");
            return false;
        }
    }
    return DSImGuiEnsureBackend(state);
}

bool DSImGuiPanelRenderLocked(DSImGuiPanelRenderer &renderer, uint32_t widthPx,
                              uint32_t heightPx, float pixelsPerPoint, float fontSize,
                              void *outBGRA, size_t outLength) {
    if (widthPx == 0 || heightPx == 0 || !outBGRA) return false;
    if (pixelsPerPoint <= 0.0f) pixelsPerPoint = 1.0f;
    if (fontSize <= 0.0f) fontSize = 18.0f;

    const DSImGuiHUDPrefs &prefs = DSImGuiHUDUi::Shared().Prefs();
    if (!DSImGuiEnsureContext(renderer.state, fontSize, pixelsPerPoint)) return false;

    if (!renderer.texture || renderer.width != widthPx || renderer.height != heightPx) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:widthPx
                                                              height:heightPx
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        renderer.texture = [renderer.state.device newTextureWithDescriptor:descriptor];
        renderer.width = widthPx;
        renderer.height = heightPx;
        if (!renderer.texture) {
            DSImGuiSetError(@"Panel render target allocation failed");
            return false;
        }
    }

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)widthPx, (float)heightPx);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    io.DeltaTime = 1.0f / 30.0f;
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
    io.AddMouseButtonEvent(0, false);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = renderer.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    ImGui_ImplMetal_NewFrame(pass);
    ImGui::NewFrame();

    ImGui::SetWindowFontScale(1.0f);
    DSImGuiHUDUi::Shared().BuildCompactPanel(prefs.usesInvertedColor, fontSize, pixelsPerPoint);

    ImGui::Render();
    ImDrawData *drawData = ImGui::GetDrawData();

    id<MTLCommandBuffer> commandBuffer = [renderer.state.queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        DSImGuiSetError(@"Panel render encoder creation failed");
        return false;
    }
    ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, encoder);
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    if (!DSImGuiReadPixels(renderer.state.queue, renderer.texture, outBGRA, outLength,
                           widthPx, heightPx)) {
        DSImGuiSetError(@"Panel pixel readback failed");
        return false;
    }
    return true;
}

} // namespace

BOOL DSImGuiPanelRender(uint32_t widthPx, uint32_t heightPx, float pixelsPerPoint,
                        float fontSize, void *outBGRA, size_t outLength) {
    std::lock_guard<std::recursive_mutex> imguiGuard(g_imguiMutex);
    DSImGuiPanelRenderer &renderer = PanelRenderer();
    std::lock_guard<std::mutex> guard(renderer.lock);
    @autoreleasepool {
        if (renderer.failed) return NO;
        @try {
            if (!DSImGuiPanelRenderLocked(renderer, widthPx, heightPx, pixelsPerPoint,
                                          fontSize, outBGRA, outLength)) {
                if (DSImGuiLastError().length > 0) renderer.failed = true;
                return NO;
            }
        } @catch (NSException *exception) {
            renderer.failed = true;
            DSImGuiSetError([NSString stringWithFormat:
                @"ImGui panel render failed: %@", exception.reason]);
            return NO;
        } @catch (...) {
            renderer.failed = true;
            DSImGuiSetError(@"ImGui panel render failed: non-ObjC exception");
            return NO;
        }
    }
    return YES;
}

BOOL DSImGuiPanelMeasure(float fontSize, float scale, float *widthPx, float *heightPx) {
    std::lock_guard<std::recursive_mutex> imguiGuard(g_imguiMutex);
    DSImGuiPanelRenderer &renderer = PanelRenderer();
    std::lock_guard<std::mutex> guard(renderer.lock);
    @autoreleasepool {
        if (renderer.failed) return NO;
        @try {
            if (!DSImGuiEnsureContext(renderer.state, fontSize, scale)) return NO;
            DSImGuiHUDUi::Shared().PanelMeasure(fontSize, scale, widthPx, heightPx);
        } @catch (...) {
            renderer.failed = true;
            DSImGuiSetError(@"ImGui panel measure failed");
            return NO;
        }
    }
    return YES;
}

NSData *DSImGuiPanelRenderPNG(float widthPoints, float heightPoints, float scale,
                              float fontSize) {
    std::lock_guard<std::recursive_mutex> imguiGuard(g_imguiMutex);
    if (widthPoints < 8.0f) widthPoints = 8.0f;
    if (heightPoints < 8.0f) heightPoints = 8.0f;
    if (scale <= 0.0f) scale = 2.0f;

    uint32_t widthPx = (uint32_t)ceilf(widthPoints * scale);
    uint32_t heightPx = (uint32_t)ceilf(heightPoints * scale);
    size_t length = (size_t)widthPx * (size_t)heightPx * 4;
    if (length == 0) {
        DSImGuiSetError(@"Panel render requested a zero-sized surface");
        return nil;
    }

    NSMutableData *pixels = [NSMutableData dataWithLength:length];
    if (!DSImGuiPanelRender(widthPx, heightPx, scale, fontSize, pixels.mutableBytes, length)) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    const CGBitmapInfo bitmapInfo =
        (CGBitmapInfo)(kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    CGImageRef image = CGImageCreate(widthPx, heightPx, 8, 32, (size_t)widthPx * 4,
                                     colorSpace, bitmapInfo,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    NSData *png = nil;
    if (image) {
        UIImage *uiImage = [UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp];
        png = UIImagePNGRepresentation(uiImage);
        CGImageRelease(image);
    }
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);

    if (!png) DSImGuiSetError(@"Panel PNG encoding failed");
    return png;
}

#pragma mark - Interactive overlay frame

namespace {

void DSImGuiOverlayRenderFrame(DSImGuiOverlayState &state) {
    std::lock_guard<std::recursive_mutex> imguiGuard(g_imguiMutex);
    if (!state.layer || !state.ctx.ctx) return;
    ImGui::SetCurrentContext(state.ctx.ctx);
    if (!DSImGuiEnsureBackend(state.ctx)) return;

    id<CAMetalDrawable> drawable = [state.layer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    ImGui_ImplMetal_NewFrame(pass);
    ImGui::NewFrame();

    DSImGuiHUDStatus status;
    memset(&status, 0, sizeof(status));
    status.compiledIn = DSBridgeCompiledIn() == YES;
    status.bridgeReady = DSBridgeIsReady() == YES;
    status.hudActive = DSBridgeHUDEnabled() == YES;
    status.hudRunning = DSBridgeIsRunning() == YES;
    status.progress = DSBridgeProgress();
    NSString *stage = DSBridgeStage();
    NSString *error = DSBridgeLastError();
    strncpy(status.stage, stage.UTF8String ?: "", sizeof(status.stage) - 1);
    strncpy(status.error, error.UTF8String ?: "", sizeof(status.error) - 1);

    DSImGuiHUDActions actions;
    memset(&actions, 0, sizeof(actions));
    DSImGuiHUDUi::Shared().BuildWindow(status, &actions);

    ImGui::Render();
    ImDrawData *drawData = ImGui::GetDrawData();

    ImGuiWindow *root = ImGui::FindWindowByName(kDSImGuiWindowTitle);
    if (root) {
        state.winMinX = root->Pos.x;
        state.winMinY = root->Pos.y;
        state.winMaxX = root->Pos.x + root->Size.x;
        state.winMaxY = root->Pos.y + root->Size.y;
    }

    id<MTLCommandBuffer> commandBuffer = [state.ctx.queue commandBuffer];
    if (!commandBuffer) return;

    if (drawData && drawData->CmdListsCount > 0) {
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder) {
            ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, encoder);
            [encoder endEncoding];
        }
    }
    // Present even with nothing to draw, so the transparent frame still flips
    // and the layer does not stall waiting for a drawable.
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    if (actions.applyRequested) {
        DSImGuiHUDUi::Shared().SavePrefs();
    }
    if (actions.startHUDRequested) {
        SetHUDEnabled(YES);
    }
    if (actions.stopHUDRequested) {
        SetHUDEnabled(NO);
    }
    if (actions.closeRequested) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DSImGuiOverlaySetVisible(NO);
        });
    }
}

} // namespace

static BOOL DSImGuiPointCaptured(void) {
    return OverlayState().visible ? YES : NO;
}

static BOOL DSImGuiPointInsideWindow(CGPoint point) {
    DSImGuiOverlayState &state = OverlayState();
    if (!state.visible) return NO;
    if (state.winMaxX <= state.winMinX || state.winMaxY <= state.winMinY) return YES;
    return point.x >= state.winMinX && point.x <= state.winMaxX &&
           point.y >= state.winMinY && point.y <= state.winMaxY;
}

static void DSImGuiFeedMouse(CGPoint point, bool down) {
    std::lock_guard<std::recursive_mutex> imguiGuard(g_imguiMutex);
    DSImGuiOverlayState &state = OverlayState();
    if (!state.ctx.ctx) return;
    ImGui::SetCurrentContext(state.ctx.ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)point.x, (float)point.y);
    io.AddMouseButtonEvent(0, down);
}

#pragma mark - Lifecycle

// Set before the overlay is first touched at launch and cleared once the app
// UI has appeared. A leftover marker therefore means the previous launch died
// while ImGui was initialising, and this launch skips ImGui entirely (safe
// mode) until the user explicitly retries from the main screen.
static NSString *DSImGuiCrashMarkerPath(void) {
    NSString *library = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [library stringByAppendingPathComponent:@"DSImGui.launching"];
}

BOOL DSImGuiInSafeMode(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:DSImGuiCrashMarkerPath()];
}

void DSImGuiSetLaunching(BOOL launching) {
    NSString *path = DSImGuiCrashMarkerPath();
    if (launching) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

static void DSImGuiBreadcrumb(const char *stage) {
    // Appended before each risky step so a hard crash still leaves the last
    // reached stage on disk for the next launch to report.
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *library = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        if (library.length) {
            path = [library stringByAppendingPathComponent:@"DSImGui.stage"];
        }
    });
    if (!path) return;
    NSString *line = [NSString stringWithFormat:@"%s\n", stage ? stage : "?"];
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void DSImGuiOverlayTick(CADisplayLink *link) {
    @try {
    std::lock_guard<std::recursive_mutex> imguiGuard(g_imguiMutex);
    DSImGuiOverlayState &state = OverlayState();
    if (!state.ctx.ctx) return;
    ImGui::SetCurrentContext(state.ctx.ctx);
    ImGuiIO &io = ImGui::GetIO();
    double now = link.timestamp;
    if (state.lastTimestamp > 0 && now > state.lastTimestamp) {
        double delta = now - state.lastTimestamp;
        if (delta < 1.0 / 240.0) delta = 1.0 / 240.0;
        io.DeltaTime = (float)delta;
    } else {
        io.DeltaTime = 1.0f / 60.0f;
    }
    state.lastTimestamp = now;
    DSImGuiHUDUi::Shared().Tick(now);
    DSImGuiOverlayRenderFrame(state);
    } @catch (NSException *exception) {
        // Stop the loop rather than repeating a failing frame forever.
        DSImGuiBreadcrumb([[NSString stringWithFormat:@"tick: %@", exception.reason] UTF8String]);
        DSImGuiSetError([NSString stringWithFormat:@"ImGui frame failed: %@", exception.reason]);
        DSImGuiOverlayState &failed = OverlayState();
        [failed.link invalidate];
        failed.link = nil;
        failed.proxy = nil;
        failed.visible = false;
        failed.wantsVisible = false;
        if (failed.window) failed.window.hidden = YES;
    } @catch (...) {
        DSImGuiBreadcrumb("tick: unknown");
        DSImGuiSetError(@"ImGui frame failed: non-ObjC exception");
        DSImGuiOverlayState &failed = OverlayState();
        [failed.link invalidate];
        failed.link = nil;
        failed.proxy = nil;
        failed.visible = false;
        failed.wantsVisible = false;
        if (failed.window) failed.window.hidden = YES;
    }
}

static void DSImGuiOverlaySetVisibleUnsafe(BOOL visible);

void DSImGuiOverlaySetVisible(BOOL visible) {
    if (visible && DSImGuiInSafeMode()) {
        DSImGuiSetError(@"ImGui is in safe mode after a crash. Press \"Retry ImGui\" on the main screen.");
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DSImGuiOverlaySetVisible(visible);
        });
        return;
    }

    // Any exception here (Metal, ImGui, layout) must not terminate the app.
    @try {
        DSImGuiOverlaySetVisibleUnsafe(visible);
    } @catch (NSException *exception) {
        DSImGuiBreadcrumb([[NSString stringWithFormat:@"exception: %@", exception.reason] UTF8String]);
        DSImGuiSetError([NSString stringWithFormat:@"ImGui overlay failed: %@", exception.reason]);
        OverlayState().visible = false;
        OverlayState().wantsVisible = false;
        if (OverlayState().window) OverlayState().window.hidden = YES;
    } @catch (...) {
        DSImGuiBreadcrumb("unknown exception");
        DSImGuiSetError(@"ImGui overlay failed: non-ObjC exception while showing the console");
        OverlayState().visible = false;
        OverlayState().wantsVisible = false;
        if (OverlayState().window) OverlayState().window.hidden = YES;
    }
}

static void DSImGuiOverlaySetVisibleUnsafe(BOOL visible) {
    DSImGuiBreadcrumb(visible ? "enter" : "enter-hide");

    DSImGuiOverlayState &state = OverlayState();

    state.wantsVisible = visible;

    if (!visible) {
        [state.link invalidate];
        state.link = nil;
        state.proxy = nil;
        state.lastTimestamp = 0;
        state.visible = false;
        state.window.hidden = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES
                                              forKey:@"darkspeed.imgui.console.closed"];
        return;
    }

    if (state.visible) return;

    [NSUserDefaults.standardUserDefaults setBool:NO
                                          forKey:@"darkspeed.imgui.console.closed"];

    DSImGuiBreadcrumb("warmup-check");
    if (!state.warmedUp) {
        // Context + Metal + atlas are built off the main thread; the window
        // itself is assembled below without them and renders once warm-up
        // completes. The app UI is therefore never blocked or killed by this.
        state.wantsVisible = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @try {
                DSImGuiBreadcrumb("warmup-begin");
                DSImGuiCtx warm;
                if (!DSImGuiEnsureContextOverlay(warm, 15.0f,
                                                 (float)UIScreen.mainScreen.scale)) {
                    DSImGuiBreadcrumb("warmup-failed");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        OverlayState().warmupFailed = YES;
                        DSImGuiSetError(DSImGuiLastError());
                    });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    OverlayState().ctx = warm;
                    OverlayState().warmedUp = YES;
                    DSImGuiBreadcrumb("warmup-done");
                    if (OverlayState().wantsVisible) DSImGuiOverlaySetVisible(YES);
                });
            } @catch (...) {
                DSImGuiBreadcrumb("warmup-exception");
                dispatch_async(dispatch_get_main_queue(), ^{
                    OverlayState().warmupFailed = YES;
                });
            }
        });
        return;
    }
    if (state.warmupFailed) {
        DSImGuiBreadcrumb("warmup-dead");
        return;
    }

    DSImGuiBreadcrumb("scene");
    UIWindowScene *scene = DSImGuiActiveWindowScene();
    if (!scene) {
        DSImGuiSetError(@"No active UIWindowScene for the ImGui overlay");
        DSImGuiBreadcrumb("no-scene");
        return;
    }

    CGRect bounds = scene.coordinateSpace.bounds;
    CGFloat scale = UIScreen.mainScreen.scale;
    if (scale < 1.0) scale = 1.0;

    // A zero drawable size makes CAMetalLayer create an invalid drawable and
    // Metal aborts on the next commit. Retry on the next runloop instead.
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        if (!state.retryScheduled) {
            state.retryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                OverlayState().retryScheduled = NO;
                if (OverlayState().wantsVisible) DSImGuiOverlaySetVisible(YES);
            });
        }
        return;
    }

    if (!state.window) {
        state.window = [[UIWindow alloc] initWithWindowScene:scene];
        state.window.backgroundColor = [UIColor clearColor];
        state.window.opaque = NO;
        state.window.windowLevel = UIWindowLevelNormal + 10.0;

        UIViewController *controller = [[UIViewController alloc] init];
        controller.view.backgroundColor = [UIColor clearColor];
        state.window.rootViewController = controller;

        state.view = [[DSImGuiOverlayView alloc] initWithFrame:bounds];
        state.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        state.view.backgroundColor = [UIColor clearColor];
        state.view.opaque = NO;
        state.view.multipleTouchEnabled = YES;
        [controller.view addSubview:state.view];

        state.layer = (CAMetalLayer *)state.view.layer;
        state.layer.device = state.ctx.device;
        state.layer.opaque = NO;
        state.layer.backgroundColor = [UIColor clearColor].CGColor;
        state.layer.contentsGravity = kCAGravityResize;
        state.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        state.layer.framebufferOnly = YES;
        state.layer.maximumDrawableCount = 3;
    }

    state.window.frame = bounds;
    state.view.frame = state.window.bounds;
    state.layer.drawableSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)bounds.size.width, (float)bounds.size.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);

    DSImGuiBreadcrumb("show");
    [state.window setHidden:NO];
    state.visible = true;
    DSImGuiBreadcrumb("visible");

    if (!state.link) {
        state.proxy = [DSImGuiDisplayLinkProxy proxyWithHandler:^{
            DSImGuiOverlayState &state = OverlayState();
            if (!state.link) return;
            DSImGuiOverlayTick(state.link);
        }];
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:state.proxy
                                                          selector:@selector(tick:)];
        link.preferredFramesPerSecond = 30;
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        state.link = link;
        state.lastTimestamp = 0;
    }
}

BOOL DSImGuiOverlayIsVisible(void) {
    return OverlayState().visible;
}
