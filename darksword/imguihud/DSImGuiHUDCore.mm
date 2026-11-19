//
//  DSImGuiHUDCore.mm
//  DarkSpeed
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdio>
#include <cfloat>
#include <cstring>

#include "HUDHelper.h"
#include "HUDPresetPosition.h"
#include "DSImGuiHUDCore.hpp"

#include "imgui.h"
#include "imgui_internal.h"

extern "C" CFIndex CARenderServerGetDirtyFrameCount(void *);

#ifndef NOTIFY_LAUNCHED_HUD
#define NOTIFY_LAUNCHED_HUD "ch.xxtou.notification.hud.launched"
#endif

namespace {

bool DSImGuiBool(NSDictionary *dict, HUDUserDefaultsKey key, bool fallback) {
    NSNumber *value = dict[key];
    return value ? value.boolValue : fallback;
}

NSInteger DSImGuiInteger(NSDictionary *dict, HUDUserDefaultsKey key, NSInteger fallback) {
    NSNumber *value = dict[key];
    return value ? value.integerValue : fallback;
}

NSString *DSImGuiPrefsPath(void) {
    return JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH);
}

} // namespace

DSImGuiHUDUi &DSImGuiHUDUi::Shared() {
    static DSImGuiHUDUi instance;
    return instance;
}

DSImGuiHUDUi::DSImGuiHUDUi()
    : _prefsLoaded(false),
      _plotOffset(0),
      _plotCount(0),
      _down(0),
      _up(0),
      _fps(0),
      _lastSample(0),
      _lastFrameSample(0),
      _nowClock(0),
      _focusUntil(0),
      _prevIn(0),
      _prevOut(0),
      _prevFrameCounter(0),
      _needsFrameBaseline(true),
      _demoVisible(false),
      _styleEditorVisible(false),
      _showMetrics(false),
      _maximumFPS(60.0) {
    memset(&_prefs, 0, sizeof(_prefs));
    _prefs.useImGuiRenderer = false;
    _prefs.customFontSize = 13.0f;
    _prefs.modePortrait = HUDPresetPositionTopCenter;
    _prefs.modeLandscape = HUDPresetPositionTopCenter;
    memset(_plotDown, 0, sizeof(_plotDown));
    memset(_plotUp, 0, sizeof(_plotUp));
}

void DSImGuiHUDUi::LoadPrefs(bool force) {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    if (_prefsLoaded && !force) return;

    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:DSImGuiPrefsPath()];
    if (!stored) stored = @{};

    _prefs.displayMode = DSImGuiBool(stored, HUDUserDefaultsKeyDisplayMode, false);
    _prefs.passthroughMode = DSImGuiBool(stored, HUDUserDefaultsKeyPassthroughMode, false);
    _prefs.singleLineMode = DSImGuiBool(stored, HUDUserDefaultsKeySingleLineMode, false);
    _prefs.usesBitrate = DSImGuiBool(stored, HUDUserDefaultsKeyUsesBitrate, false);
    _prefs.usesArrowPrefixes = DSImGuiBool(stored, HUDUserDefaultsKeyUsesArrowPrefixes, false);
    _prefs.usesLargeFont = DSImGuiBool(stored, HUDUserDefaultsKeyUsesLargeFont, false);
    _prefs.usesRotation = DSImGuiBool(stored, HUDUserDefaultsKeyUsesRotation, false);
    _prefs.usesInvertedColor = DSImGuiBool(stored, HUDUserDefaultsKeyUsesInvertedColor, false);
    _prefs.hideAtSnapshot = DSImGuiBool(stored, HUDUserDefaultsKeyHideAtSnapshot, false);
    _prefs.keepInPlace = DSImGuiBool(stored, HUDUserDefaultsKeyKeepInPlace, false);
    _prefs.useImGuiRenderer = DSImGuiBool(stored, HUDUserDefaultsKeyUsesImGuiRenderer, true);
    _prefs.modePortrait = DSImGuiInteger(stored, HUDUserDefaultsKeySelectedMode,
                                         HUDPresetPositionTopCenter);
    _prefs.modeLandscape = DSImGuiInteger(stored, HUDUserDefaultsKeySelectedModeLandscape,
                                          HUDPresetPositionTopCenter);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id customFont = [defaults objectForKey:HUDUserDefaultsKeyUsesCustomFontSize];
    id customSize = [defaults objectForKey:HUDUserDefaultsKeyRealCustomFontSize];
    _prefs.usesCustomFontSize = customFont ? [customFont boolValue] : false;
    _prefs.customFontSize = customSize ? [customSize floatValue] : 13.0f;
    if (_prefs.customFontSize < 9.0f) _prefs.customFontSize = 9.0f;
    if (_prefs.customFontSize > 34.0f) _prefs.customFontSize = 34.0f;

    _prefsLoaded = true;
}

bool DSImGuiHUDUi::SavePrefs() {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    NSMutableDictionary *stored = [[NSDictionary dictionaryWithContentsOfFile:DSImGuiPrefsPath()]
        mutableCopy] ?: [NSMutableDictionary dictionary];

    stored[HUDUserDefaultsKeyDisplayMode] = @(_prefs.displayMode);
    stored[HUDUserDefaultsKeyPassthroughMode] = @(_prefs.passthroughMode);
    stored[HUDUserDefaultsKeySingleLineMode] = @(_prefs.singleLineMode);
    stored[HUDUserDefaultsKeyUsesBitrate] = @(_prefs.usesBitrate);
    stored[HUDUserDefaultsKeyUsesArrowPrefixes] = @(_prefs.usesArrowPrefixes);
    stored[HUDUserDefaultsKeyUsesLargeFont] = @(_prefs.usesLargeFont);
    stored[HUDUserDefaultsKeyUsesRotation] = @(_prefs.usesRotation);
    stored[HUDUserDefaultsKeyUsesInvertedColor] = @(_prefs.usesInvertedColor);
    stored[HUDUserDefaultsKeyHideAtSnapshot] = @(_prefs.hideAtSnapshot);
    stored[HUDUserDefaultsKeyKeepInPlace] = @(_prefs.keepInPlace);
    stored[HUDUserDefaultsKeyUsesImGuiRenderer] = @(_prefs.useImGuiRenderer);
    stored[HUDUserDefaultsKeySelectedMode] = @(_prefs.modePortrait);
    stored[HUDUserDefaultsKeySelectedModeLandscape] = @(_prefs.modeLandscape);

    BOOL saved = [stored writeToFile:DSImGuiPrefsPath() atomically:YES];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:@(_prefs.usesCustomFontSize) forKey:HUDUserDefaultsKeyUsesCustomFontSize];
    [defaults setObject:@((double)_prefs.customFontSize) forKey:HUDUserDefaultsKeyRealCustomFontSize];
    [defaults synchronize];

    if (saved) notify_post(NOTIFY_RELOAD_HUD);
    return saved == YES;
}

void DSImGuiHUDUi::SampleNetwork() {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    unsigned long long inBytes = 0;
    unsigned long long outBytes = 0;

    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_name || !ifa->ifa_addr || !ifa->ifa_data) continue;
            if (ifa->ifa_addr->sa_family != AF_LINK) continue;
            if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING)) continue;
            if (strncmp(ifa->ifa_name, "en", 2) && strncmp(ifa->ifa_name, "pdp_ip", 6)) continue;
            struct if_data *data = (struct if_data *)ifa->ifa_data;
            inBytes += data->ifi_ibytes;
            outBytes += data->ifi_obytes;
        }
        freeifaddrs(list);
    }

    double now = _nowClock;
    double interval = _lastSample > 0 ? now - _lastSample : 0.0;
    if (_lastSample > 0 && interval > 0.05) {
        double down = inBytes >= _prevIn ? (double)(inBytes - _prevIn) / interval : 0.0;
        double up = outBytes >= _prevOut ? (double)(outBytes - _prevOut) / interval : 0.0;
        if (down < 0) down = 0;
        if (up < 0) up = 0;
        _down = down;
        _up = up;
        _plotDown[_plotOffset] = (float)down;
        _plotUp[_plotOffset] = (float)up;
        _plotOffset = (_plotOffset + 1) % DSIMGUI_PLOT_SAMPLES;
        if (_plotCount < DSIMGUI_PLOT_SAMPLES) _plotCount++;
        _lastSample = now;
    } else if (_lastSample <= 0) {
        _lastSample = now;
    }

    _prevIn = inBytes;
    _prevOut = outBytes;
}

void DSImGuiHUDUi::SampleFrameRate() {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    if (_nowClock - _lastFrameSample < 0.5) return;
    _lastFrameSample = _nowClock;

    CFIndex current = CARenderServerGetDirtyFrameCount(NULL);
    if (_needsFrameBaseline || _prevFrameCounter <= 0) {
        _prevFrameCounter = current;
        _needsFrameBaseline = false;
        _fps = 0;
        return;
    }
    CFIndex diff = current - _prevFrameCounter;
    _prevFrameCounter = current;
    if (diff < 0) diff = 0;
    if (_maximumFPS <= 0.0) {
        // UIScreen must be touched on the main thread; the bridge queue samples
        // the panel, so read it once asynchronously and keep the cached value.
        dispatch_async(dispatch_get_main_queue(), ^{
            DSImGuiHUDUi::Shared()._maximumFPS = (double)UIScreen.mainScreen.maximumFramesPerSecond;
        });
        _maximumFPS = 60.0;
    }
    double scaled = (double)diff * 2.0;
    if (scaled > _maximumFPS) scaled = _maximumFPS;
    _fps = scaled;
}

void DSImGuiHUDUi::Tick(double now) {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    _nowClock = now;
    SampleNetwork();
    SampleFrameRate();
}

void DSImGuiHUDUi::FormatRate(char *out, size_t outSize, double bytes,
                              bool bitrate, bool focused) {
    double value = bitrate ? bytes * 8.0 : bytes;
    double kilo = bitrate ? 1000.0 : 1024.0;
    double mega = kilo * kilo;
    double giga = mega * kilo;
    const char *suffix = focused ? "" : "/s";
    const char *kiloUnit = bitrate ? "Kb" : "KB";
    const char *megaUnit = bitrate ? "Mb" : "MB";
    const char *gigaUnit = bitrate ? "Gb" : "GB";

    if (value < kilo) {
        snprintf(out, outSize, "0 %s%s", kiloUnit, suffix);
    } else if (value < mega) {
        snprintf(out, outSize, "%.0f %s%s", value / kilo, kiloUnit, suffix);
    } else if (value < giga) {
        snprintf(out, outSize, "%.2f %s%s", value / mega, megaUnit, suffix);
    } else {
        snprintf(out, outSize, "%.2f %s%s", value / giga, gigaUnit, suffix);
    }
}

void DSImGuiHUDUi::ApplyDarkTheme(void) {
    ImGuiStyle &style = ImGui::GetStyle();
    ImGui::StyleColorsDark(&style);
    style.WindowRounding = 10.0f;
    style.ChildRounding = 8.0f;
    style.FrameRounding = 6.0f;
    style.PopupRounding = 6.0f;
    style.GrabRounding = 6.0f;
    style.TabRounding = 6.0f;
    style.ScrollbarRounding = 6.0f;
    style.WindowBorderSize = 1.0f;
    style.WindowPadding = ImVec2(10.0f, 8.0f);
    style.FramePadding = ImVec2(8.0f, 4.0f);
    style.ItemSpacing = ImVec2(8.0f, 6.0f);

    ImVec4 *colors = style.Colors;
    colors[ImGuiCol_Text] = ImVec4(0.96f, 0.98f, 0.98f, 1.00f);
    colors[ImGuiCol_TextDisabled] = ImVec4(0.62f, 0.70f, 0.70f, 1.00f);
    colors[ImGuiCol_WindowBg] = ImVec4(0.07f, 0.13f, 0.15f, 0.96f);
    colors[ImGuiCol_ChildBg] = ImVec4(0.09f, 0.16f, 0.18f, 0.96f);
    colors[ImGuiCol_PopupBg] = ImVec4(0.07f, 0.13f, 0.15f, 0.98f);
    colors[ImGuiCol_Border] = ImVec4(0.18f, 0.36f, 0.34f, 0.85f);
    colors[ImGuiCol_FrameBg] = ImVec4(0.12f, 0.22f, 0.24f, 1.00f);
    colors[ImGuiCol_FrameBgHovered] = ImVec4(0.15f, 0.30f, 0.31f, 1.00f);
    colors[ImGuiCol_FrameBgActive] = ImVec4(0.17f, 0.35f, 0.35f, 1.00f);
    colors[ImGuiCol_TitleBg] = ImVec4(0.06f, 0.12f, 0.14f, 1.00f);
    colors[ImGuiCol_TitleBgActive] = ImVec4(0.10f, 0.20f, 0.22f, 1.00f);
    colors[ImGuiCol_CheckMark] = ImVec4(0.10f, 0.74f, 0.61f, 1.00f);
    colors[ImGuiCol_SliderGrab] = ImVec4(0.10f, 0.74f, 0.61f, 1.00f);
    colors[ImGuiCol_SliderGrabActive] = ImVec4(0.16f, 0.86f, 0.71f, 1.00f);
    colors[ImGuiCol_Button] = ImVec4(0.10f, 0.42f, 0.37f, 1.00f);
    colors[ImGuiCol_ButtonHovered] = ImVec4(0.13f, 0.53f, 0.46f, 1.00f);
    colors[ImGuiCol_ButtonActive] = ImVec4(0.16f, 0.62f, 0.53f, 1.00f);
    colors[ImGuiCol_Header] = ImVec4(0.10f, 0.34f, 0.32f, 1.00f);
    colors[ImGuiCol_HeaderHovered] = ImVec4(0.13f, 0.45f, 0.41f, 1.00f);
    colors[ImGuiCol_HeaderActive] = ImVec4(0.16f, 0.55f, 0.49f, 1.00f);
    colors[ImGuiCol_Separator] = ImVec4(0.20f, 0.42f, 0.39f, 1.00f);
    colors[ImGuiCol_PlotLines] = ImVec4(0.10f, 0.80f, 0.66f, 1.00f);
    colors[ImGuiCol_PlotHistogram] = ImVec4(0.95f, 0.62f, 0.20f, 1.00f);
    colors[ImGuiCol_TextSelectedBg] = ImVec4(0.10f, 0.56f, 0.48f, 0.55f);
}

void DSImGuiHUDUi::SetupFontAtlas(float pixelSize) {
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.LogFilename = NULL;

    if (pixelSize < 9.0f) pixelSize = 9.0f;
    if (pixelSize > 64.0f) pixelSize = 64.0f;

    ImFontConfig base;
    base.OversampleH = 2;
    base.OversampleV = 1;
    base.PixelSnapH = true;
    base.SizePixels = 13.0f;

    static ImVector<ImWchar> ranges;
    ranges.clear();
    ImFontGlyphRangesBuilder builder;
    builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
    builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
    // Solid triangles, thin arrows, middle dot and the punctuation used by
    // the HUD strings.
    builder.AddText("\xE2\x96\xBC\xE2\x96\xB2\xE2\x86\x93\xE2\x86\x91\xC2\xB7\xE2\x80\x94\xE2\x80\xA6");
    builder.BuildRanges(&ranges);

    ImFontConfig scaled = base;
    scaled.SizePixels = pixelSize;

    io.Fonts->Clear();
    io.Fonts->AddFontDefault(&base);
    ImFont *font = io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/CoreUI/SFUI.ttf",
                                                pixelSize, &scaled,
                                                ranges.Data ? ranges.Data
                                                            : io.Fonts->GetGlyphRangesDefault());
    if (!font) {
        font = io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/Core/SFUI.ttf",
                                            pixelSize, &scaled,
                                            ranges.Data ? ranges.Data
                                                        : io.Fonts->GetGlyphRangesDefault());
    }
    if (!font) {
        font = io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/LanguageSupport/PingFang.ttc",
                                            pixelSize, &scaled,
                                            ranges.Data ? ranges.Data
                                                        : io.Fonts->GetGlyphRangesDefault());
    }
    io.Fonts->Build();

    ImFont *primary = io.Fonts->Fonts.Size > 1 ? io.Fonts->Fonts[1] : nullptr;
    if (primary) io.FontDefault = primary;
}

bool DSImGuiHUDUi::GlyphsAvailable() {
    ImGuiIO &io = ImGui::GetIO();
    ImFontAtlas *atlas = io.Fonts;
    if (!atlas || io.Fonts->Fonts.Size == 0) return false;
    ImFont *font = io.Fonts->Fonts[0];
    if (!font) return false;
    return font->FindGlyphNoFallback((ImWchar)0x25BC) != NULL &&
           font->FindGlyphNoFallback((ImWchar)0x25B2) != NULL &&
           font->FindGlyphNoFallback((ImWchar)0x2193) != NULL &&
           font->FindGlyphNoFallback((ImWchar)0x2191) != NULL &&
           font->FindGlyphNoFallback((ImWchar)0x00B7) != NULL;
}

void DSImGuiHUDUi::BuildWindow(const DSImGuiHUDStatus &status, DSImGuiHUDActions *actions) {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    LoadPrefs(false);
    Tick(CFAbsoluteTimeGetCurrent());

    const ImGuiViewport *viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(ImVec2(viewport->WorkPos.x + viewport->WorkSize.x - 24.0f,
                                   viewport->WorkPos.y + 24.0f),
                            ImGuiCond_FirstUseEver, ImVec2(1.0f, 0.0f));
    ImGui::SetNextWindowSize(ImVec2(372.0f, 520.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowBgAlpha(0.94f);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoCollapse;
    char title[96];
    snprintf(title, sizeof(title), "DarkSpeed ImGui HUD##darkspeed-imgui");

    if (!ImGui::Begin(title, NULL, flags)) {
        ImGui::End();
        return;
    }

    ImGui::TextUnformatted("DarkSpeed · ImGui overlay");
    ImGui::SameLine();
    ImGui::TextDisabled("v%s", [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] ?: "1.0");
    ImGui::Separator();

    if (_prefs.displayMode) {
        ImGui::Text("FPS  %.0f", _fps);
    } else {
        char downText[48];
        char upText[48];
        FormatRate(downText, sizeof(downText), _down, _prefs.usesBitrate, false);
        FormatRate(upText, sizeof(upText), _up, _prefs.usesBitrate, false);
        ImGui::Text("▼ %s", downText);
        ImGui::SameLine(180.0f);
        ImGui::Text("▲ %s", upText);
    }

    if (_plotCount > 1) {
        float plotHeight = 58.0f;
        ImVec2 area(ImGui::GetContentRegionAvail().x, plotHeight);
        float peak = 1.0f;
        for (int i = 0; i < DSIMGUI_PLOT_SAMPLES; i++) {
            if (_plotDown[i] > peak) peak = _plotDown[i];
            if (_plotUp[i] > peak) peak = _plotUp[i];
        }
        ImGui::TextDisabled("rate history (auto-scaled %.0f B/s)", peak);
        ImGui::PlotLines("##down", _plotDown, DSIMGUI_PLOT_SAMPLES, 0, "download", 0.0f, peak,
                         area, sizeof(float));
        ImGui::PlotLines("##up", _plotUp, DSIMGUI_PLOT_SAMPLES, 0, "upload", 0.0f, peak,
                         area, sizeof(float));
    }

    ImGui::Separator();
    if (ImGui::CollapsingHeader("Surface HUD", ImGuiTreeNodeFlags_DefaultOpen)) {
        bool changed = false;
        changed |= ImGui::Checkbox("Render with ImGui + IOSurface", &_prefs.useImGuiRenderer);
        ImGui::SameLine();
        ImGui::TextDisabled("(?)");
        if (ImGui::IsItemHovered()) {
            ImGui::SetTooltip("SpringBoard side: RemoteCall builds a CAMetalLayer, renders the panel\n"
                              "headlessly into an IOSurface and shows it through a UIImageView.");
        }
        changed |= ImGui::Checkbox("Pass-through", &_prefs.passthroughMode);
        changed |= ImGui::Checkbox("Incoming only", &_prefs.singleLineMode);
        changed |= ImGui::Checkbox("Bitrate units", &_prefs.usesBitrate);
        changed |= ImGui::Checkbox("Thin arrows", &_prefs.usesArrowPrefixes);
        changed |= ImGui::Checkbox("Inverted colors", &_prefs.usesInvertedColor);
        changed |= ImGui::Checkbox("Follow rotation", &_prefs.usesRotation);
        changed |= ImGui::Checkbox("Hide at snapshot", &_prefs.hideAtSnapshot);
        changed |= ImGui::Checkbox("FPS mode", &_prefs.displayMode);
        changed |= ImGui::Checkbox("Large font", &_prefs.usesLargeFont);
        if (ImGui::Checkbox("Custom font size", &_prefs.usesCustomFontSize)) changed = true;
        if (_prefs.usesCustomFontSize) {
            ImGui::SetNextItemWidth(220.0f);
            changed |= ImGui::SliderFloat("##fontsize", &_prefs.customFontSize, 9.0f, 34.0f, "%.0f pt");
        }
        int mode = _prefs.modePortrait;
        const char *modes[] = {"Top left", "Top center", "Top right", "Center (Dynamic Island)"};
        ImGui::SetNextItemWidth(240.0f);
        if (ImGui::Combo("Position", &mode, modes, 4)) {
            _prefs.modePortrait = mode;
            changed = true;
        }
        if (changed) {
            actions->prefsDirty = true;
            actions->applyRequested = true;
        }
    }

    if (ImGui::CollapsingHeader("HUD lifecycle")) {
        ImGui::Text("compiled in : %s", status.compiledIn ? "yes" : "no");
        ImGui::Text("bridge ready: %s", status.bridgeReady ? "yes" : "no");
        ImGui::Text("hud active  : %s", status.hudActive ? "yes" : "no");
        ImGui::Text("hud running : %s", status.hudRunning ? "yes" : "no");
        ImGui::ProgressBar((float)status.progress, ImVec2(-1.0f, 0.0f));
        ImGui::TextWrapped("stage: %s", status.stage);
        if (status.error[0]) {
            ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(255, 120, 120, 255));
            ImGui::TextWrapped("%s", status.error);
            ImGui::PopStyleColor();
        }
        if (!status.hudActive) {
            if (ImGui::Button("Start SpringBoard HUD", ImVec2(210.0f, 0.0f))) {
                actions->startHUDRequested = true;
            }
        } else {
            if (ImGui::Button("Stop SpringBoard HUD", ImVec2(210.0f, 0.0f))) {
                actions->stopHUDRequested = true;
            }
        }
        ImGui::SameLine();
        if (ImGui::Button("Close overlay")) actions->closeRequested = true;
    }

    if (ImGui::CollapsingHeader("Tools")) {
        ImGui::Checkbox("ImGui demo", &_demoVisible);
        ImGui::Checkbox("Style editor", &_styleEditorVisible);
        ImGui::Checkbox("Metrics", &_showMetrics);
        ImGui::TextDisabled("IO: %s", ImGui::GetIO().BackendRendererName ?: "unknown");
    }

    ImGui::Separator();
    ImGui::TextDisabled("Drag the title bar to move · tap the HUD chip to re-focus");

    ImGui::End();

    if (_demoVisible) ImGui::ShowDemoWindow(&_demoVisible);
    if (_styleEditorVisible) ImGui::ShowStyleEditor();
    if (_showMetrics) ImGui::ShowMetricsWindow(&_showMetrics);
}

void DSImGuiHUDUi::PanelMeasure(float fontSize, float scale, float *outWidthPx,
                                 float *outHeightPx) {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    LoadPrefs(false);

    if (fontSize < 9.0f) fontSize = 9.0f;
    if (fontSize > 34.0f) fontSize = 34.0f;
    if (scale < 1.0f) scale = 1.0f;

    const float pixelSize = fontSize * scale;
    const float padX = 7.0f * scale;
    const float padY = 4.0f * scale;
    const float spacing = 2.0f * scale;

    ImGuiIO &io = ImGui::GetIO();
    ImFont *font = io.Fonts->Fonts.Size > 0 ? io.Fonts->Fonts[0] : nullptr;
    if (!font || font->FontSize <= 0.0f) {
        if (outWidthPx) *outWidthPx = 132.0f * scale;
        if (outHeightPx) *outHeightPx = 44.0f * scale;
        return;
    }

    char line1[96];
    char line2[96];
    const char *downMark = _prefs.usesArrowPrefixes ? "↓" : "▼";
    const char *upMark = _prefs.usesArrowPrefixes ? "↑" : "▲";

    if (_prefs.displayMode) {
        snprintf(line1, sizeof(line1), "%.0f FPS", _fps);
        line2[0] = '\0';
    } else {
        char downText[48];
        char upText[48];
        FormatRate(downText, sizeof(downText), _down, _prefs.usesBitrate, false);
        FormatRate(upText, sizeof(upText), _up, _prefs.usesBitrate, false);
        if (_prefs.singleLineMode) {
            snprintf(line1, sizeof(line1), "%s %s", downMark, downText);
            line2[0] = '\0';
        } else {
            snprintf(line1, sizeof(line1), "%s %s", upMark, upText);
            snprintf(line2, sizeof(line2), "%s %s", downMark, downText);
        }
    }

    ImVec2 size1 = font->CalcTextSizeA(pixelSize, FLT_MAX, 0.0f, line1);
    ImVec2 size2 = line2[0] ? font->CalcTextSizeA(pixelSize, FLT_MAX, 0.0f, line2) : ImVec2(0.0f, 0.0f);
    bool twoLines = line2[0] != '\0';

    float width = (size1.x > size2.x ? size1.x : size2.x) + padX * 2.0f;
    float height = size1.y + (twoLines ? size2.y + spacing : 0.0f) + padY * 2.0f;

    if (width < 64.0f * scale) width = 64.0f * scale;
    if (height < 22.0f * scale) height = 22.0f * scale;

    if (outWidthPx) *outWidthPx = ceilf(width);
    if (outHeightPx) *outHeightPx = ceilf(height);
}

void DSImGuiHUDUi::BuildCompactPanel(bool inverted, float fontSize, float scale) {
    std::lock_guard<std::recursive_mutex> guard(_lock);
    LoadPrefs(false);
    Tick(CFAbsoluteTimeGetCurrent());

    if (fontSize < 9.0f) fontSize = 9.0f;
    if (fontSize > 34.0f) fontSize = 34.0f;
    if (scale < 1.0f) scale = 1.0f;

    float panelWidth = 0.0f;
    float panelHeight = 0.0f;
    PanelMeasure(fontSize, scale, &panelWidth, &panelHeight);

    ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f));
    ImGui::SetNextWindowSize(ImVec2(panelWidth, panelHeight));
    ImGui::SetNextWindowBgAlpha(0.0f);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus |
                             ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav |
                             ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse |
                             ImGuiWindowFlags_NoResize;

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(7.0f * scale, 4.0f * scale));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0.0f, 2.0f * scale));
    if (!ImGui::Begin("##darkspeed-panel", NULL, flags)) {
        ImGui::End();
        ImGui::PopStyleVar(3);
        return;
    }

    ImDrawList *drawList = ImGui::GetWindowDrawList();
    ImVec2 min = ImGui::GetWindowPos();
    ImVec2 max = ImVec2(min.x + ImGui::GetWindowWidth(), min.y + ImGui::GetWindowHeight());
    const float rounding = 6.0f * scale;
    ImU32 background = inverted ? IM_COL32(255, 255, 255, 214) : IM_COL32(20, 24, 26, 170);
    drawList->AddRectFilled(min, max, background, rounding);

    ImGui::PushStyleColor(ImGuiCol_Text, inverted ? IM_COL32(12, 14, 16, 255)
                                                  : IM_COL32(255, 255, 255, 255));

    char downText[48];
    char upText[48];
    FormatRate(downText, sizeof(downText), _down, _prefs.usesBitrate, false);
    FormatRate(upText, sizeof(upText), _up, _prefs.usesBitrate, false);

    const char *downMark = _prefs.usesArrowPrefixes ? "↓" : "▼";
    const char *upMark = _prefs.usesArrowPrefixes ? "↑" : "▲";

    if (_prefs.displayMode) {
        ImGui::Text("%.0f FPS", _fps);
    } else if (_prefs.singleLineMode) {
        ImGui::Text("%s %s", downMark, downText);
    } else {
        ImGui::Text("%s %s", upMark, upText);
        ImGui::Text("%s %s", downMark, downText);
    }

    ImGui::PopStyleColor();
    ImGui::End();
    ImGui::PopStyleVar(3);
}
