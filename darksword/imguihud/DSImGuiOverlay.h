//
//  DSImGuiOverlay.h
//  DarkSpeed
//
//  In-app ImGui overlay (Metal) and the offscreen ImGui panel renderer whose
//  pixels the SpringBoard HUD shows through RemoteCall.
//

#ifndef DSIMGUI_OVERLAY_H
#define DSIMGUI_OVERLAY_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when this build linked the ImGui core and the Metal backend.
OBJC_EXTERN BOOL DSImGuiCompiledIn(void);

/// Shows or hides the interactive ImGui overlay inside the DarkSpeed app.
OBJC_EXTERN void DSImGuiOverlaySetVisible(BOOL visible);
OBJC_EXTERN BOOL DSImGuiOverlayIsVisible(void);

/// Renders the compact HUD panel with ImGui + Metal at the requested point
/// size and returns it as PNG data (RGBA, premultiplied alpha). Returns nil and
/// fills DSImGuiLastError() when the renderer is unavailable.
OBJC_EXTERN NSData * _Nullable DSImGuiPanelRenderPNG(float widthPoints,
                                                     float heightPoints,
                                                     float scale);

/// Point size the compact panel wants for the requested font size.
OBJC_EXTERN BOOL DSImGuiPanelMeasure(float fontSize, float *width, float *height);

/// Last renderer error, empty while the renderers are healthy.
OBJC_EXTERN NSString *DSImGuiLastError(void);

NS_ASSUME_NONNULL_END

#endif /* DSIMGUI_OVERLAY_H */
