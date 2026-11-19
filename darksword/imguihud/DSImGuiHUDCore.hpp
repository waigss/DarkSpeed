//
//  DSImGuiHUDCore.hpp
//  DarkSpeed
//
//  Shared ImGui UI core. Builds the interactive overlay window (app process)
//  and the compact remote panel (SpringBoard surface renderer). All state that
//  both renderers need lives here so the two paths cannot drift apart.
//

#ifndef DSIMGUI_HUD_CORE_HPP
#define DSIMGUI_HUD_CORE_HPP

#include <stdbool.h>
#include <stddef.h>

#include <mutex>

#define DSIMGUI_PLOT_SAMPLES 180

struct DSImGuiHUDPrefs {
    bool displayMode;        // FPS instead of speed
    bool passthroughMode;
    bool singleLineMode;     // incoming only
    bool usesBitrate;        // bits instead of bytes
    bool usesArrowPrefixes;  // thin arrows instead of solid triangles
    bool usesLargeFont;
    bool usesRotation;
    bool usesInvertedColor;
    bool hideAtSnapshot;
    bool keepInPlace;
    bool useImGuiRenderer;   // draw the SpringBoard HUD with ImGui + IOSurface
    bool usesCustomFontSize;
    float customFontSize;
    int modePortrait;        // HUDPresetPosition
    int modeLandscape;       // HUDPresetPosition
};

struct DSImGuiHUDStatus {
    bool compiledIn;
    bool bridgeReady;
    bool hudActive;
    bool hudRunning;
    double progress;
    char stage[256];
    char error[768];
};

struct DSImGuiHUDActions {
    bool closeRequested;
    bool applyRequested;
    bool startHUDRequested;
    bool stopHUDRequested;
    bool clearCacheRequested;
    bool openDemoRequested;
    bool prefsDirty;
};

class DSImGuiHUDUi {
public:
    static DSImGuiHUDUi &Shared();
    /// Reads ch.xxtou.hudapp.plist plus the advanced keys from NSUserDefaults.
    void LoadPrefs(bool force);
    /// Writes the plist back and posts the HUD reload notification.
    bool SavePrefs();

    /// Samples interface counters / frame counter and feeds the plot ring.
    void Tick(double now);

    /// Builds the interactive window. Needs an ImGui context that is current.
    void BuildWindow(const DSImGuiHUDStatus &status, DSImGuiHUDActions *actions);

    /// Builds the compact one/two line panel used by the remote renderer.
    /// The panel ImGui context works in pixels: DisplaySize must be the pixel
    /// size and the atlas must be loaded at fontSize * scale.
    void BuildCompactPanel(bool inverted, float fontSize, float scale);

    const DSImGuiHUDPrefs &Prefs() const { return _prefs; }
    DSImGuiHUDPrefs &MutablePrefs() { return _prefs; }

    double DownBytesPerSecond() const { return _down; }
    double UpBytesPerSecond() const { return _up; }
    double FramesPerSecond() const { return _fps; }
    bool Focused() const { return _focusUntil > _nowClock; }

    /// Formats a rate with the current unit preferences.
    static void FormatRate(char *out, size_t outSize, double bytes,
                           bool bitrate, bool focused);

    /// True when the loaded atlas carries the solid triangle/arrow glyphs.
    static bool GlyphsAvailable();

    /// Pixel size the compact panel needs for the given font size and scale.
    void PanelMeasure(float fontSize, float scale, float *widthPx, float *heightPx);

    /// DarkSpeed dark theme, applied to the current ImGui context.
    static void ApplyDarkTheme();

    /// Builds the atlas with Latin + arrows/triangles + CJK subset ranges.
    /// Safe to call once per context before the first NewFrame().
    static void SetupFontAtlas(float pixelSize);

private:
    DSImGuiHUDUi();
    void SampleNetwork();
    void SampleFrameRate();

    std::recursive_mutex _lock;
    DSImGuiHUDPrefs _prefs;
    bool _prefsLoaded;
    float _plotDown[DSIMGUI_PLOT_SAMPLES];
    float _plotUp[DSIMGUI_PLOT_SAMPLES];
    int _plotOffset;
    int _plotCount;
    double _down;
    double _up;
    double _fps;
    double _lastSample;
    double _lastFrameSample;
    double _nowClock;
    double _focusUntil;
    unsigned long long _prevIn;
    unsigned long long _prevOut;
    long long _prevFrameCounter;
    bool _needsFrameBaseline;
    bool _demoVisible;
    bool _styleEditorVisible;
    bool _showMetrics;
    double _maximumFPS;
};

#endif /* DSIMGUI_HUD_CORE_HPP */
