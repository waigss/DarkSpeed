# DarkSpeed

[English](README.md) · [原版 TrollSpeed](README_TrollSpeed.md) · [项目仓库](https://github.com/huami1314/DarkSpeed)

当前版本：**1.0-1**

DarkSpeed 是一个仅通过 IPA 安装、直接显示在 SpringBoard 上的网速悬浮窗。它保留 TrollSpeed 熟悉的显示和设置，同时提供独立的签名应用运行时与 SpringBoard 渲染器。

悬浮窗支持实时上传/下载速度、左中右位置、尺寸与单位调整、锁屏显示、横竖屏适配、FPS 文本以及可选的截图隐藏。影响显示的设置会在悬浮窗运行时实时更新。

> [!WARNING]
> DarkSpeed 使用实验性的底层技术，兼容性取决于具体设备和 iOS 构建版本。测试前请备份重要数据。DarkSpeed 不会自动重启设备。

DarkSpeed 必须使用有效证书和描述文件签名后安装。悬浮窗启用成功后，可以回到桌面并正常使用其他应用，DarkSpeed 会在后台保持存活。悬浮窗启用期间，请勿从多任务界面上划或强制关闭 DarkSpeed。

## 支持范围

| iOS 版本 | 支持状态 |
|---|---|
| iOS 16.x | 可能支持 ¹ |
| iOS 16.7.2 | 已测试，仍需更多测试 |
| iOS 17.0 – iOS 18.7.1 | 支持 |
| iOS 18.7.2+ | 不支持 |
| iOS 26.0 – iOS 26.0.1 | 支持 |
| iOS 26.1+ | 不支持 |

¹ iOS 16.x 在原理上可能可用，但尚未覆盖所有设备与构建组合。

iOS 18.7 与 18.7.1 仍可能出现兼容性问题。“支持”表示对应路径已经实现，不代表每一种设备与构建组合都完成了实机验证。

DarkSpeed 支持 DarkSword 所支持的全部设备。由于 MTE，DarkSpeed 无法在 M5、A19 和 A19 Pro 设备上工作。上述 iOS 支持范围仅适用于兼容硬件。

## 首次启动

- CH/A 设备弹出提示时，需要允许网络权限。
- DarkSpeed HUD 启动成功后，请勿关闭或强制结束应用。


## ImGui 渲染层

本仓库在原始 DarkSpeed 基础上加了一层 Dear ImGui 渲染管线，两条路径共用同一套 UI 核心：

| 路径 | 位置 | 说明 |
|---|---|---|
| 应用内控制台 | `darksword/imguihud/DSImGuiOverlay.mm` | 独立 `UIWindow` + `CAMetalLayer`，`CADisplayLink` 驱动，触摸事件转成 ImGui 鼠标事件，改设置立即写入 `ch.xxtou.hudapp.plist` 并广播 `NOTIFY_RELOAD_HUD` |
| SpringBoard 悬浮窗 | `darksword/DSImGuiHUDCore.mm` + `DSBridge.mm` | 本进程用 ImGui + Metal 离屏渲染紧凑面板，读回像素编码成 PNG，再由 `RemoteCall` 写入 SpringBoard 内的 `NSData` / `UIImage`，经 `UIImageView` 显示，复用原有的截图隐藏容器 |

UI 核心在 `darksword/imguihud/DSImGuiHUDCore.mm`：偏好读取、接口计数采样、帧率采样、设置窗口、紧凑面板排版都在这里，两条路径共用，不会出现两套数值。

### 打开方式

- 摇一摇 → 「Developer Area」→ **ImGui Console**
- URL scheme：`darkspeed://imgui`（切换显示/隐藏）
- 悬浮窗设置里的 **Render the HUD with ImGui** 开关控制 SpringBoard 侧走 ImGui 面板还是原来的 `UILabel`；ImGui 渲染失败时自动回退到 `UILabel`

### 渲染参数

- 面板上下文以设备像素为单位：`DisplaySize` = 像素尺寸，字体图集按 `fontSize * scale` 生成，`DisplayFramebufferScale` 固定 1:1，所以 18pt 的字体在 3x 屏上是 54px 字模，不是放大后的位图
- 应用内窗口上下文按点工作：图集按 `15pt * scale` 生成，`FontGlobalScale = 1 / scale` 折回点坐标
- 字体图集包含 Latin + 常用简体中文 + `▼▲↓↑·—…`，找不到 `SFUI.ttf` 时依次回退到 `Core/SFUI.ttf`、`PingFang.ttc`

### 线程约束

Dear ImGui 的当前上下文是进程级全局变量，不是线程安全的。应用内窗口在 main thread 渲染，悬浮窗面板在本进程的 `com.huami.darkspeed.darksword` 串行队列渲染，两者都先取 `g_imguiMutex`（`std::recursive_mutex`，最外层锁固定顺序），再取各自的上下文锁，不会互相踩 `ImGui::SetCurrentContext`。

## 云端编译

`.github/workflows/build-cloud.yml`：`macos-15` + 默认 Xcode，`DARKSPEED_UNSIGNED=1 ./build-darkspeed.sh` 产出未签名 IPA，同时上传完整构建日志与 IPA 的 SHA-256。

```sh
# 触发
gh workflow run build-cloud.yml -R <owner>/DarkSpeed
# 或者 push 到 main 自动触发
```

产物：`packages/DarkSpeed_1.0-1.ipa`（未签名，需要 TrollStore 或自签后安装）、`packages/DarkSpeed_1.0-1.ipa.sha256`、`packages/DarkSpeed_1.0-1_build.log`。

本地等价命令：

```sh
chmod +x build-darkspeed.sh get-version.sh
DARKSPEED_UNSIGNED=1 ./build-darkspeed.sh
```

## 构建

本仓库只构建 IPA，不包含越狱插件或 PreferenceBundle 构建目标。

仓库自带两套 CI：`build-cloud.yml`（本改动新增，产未签名 IPA + 日志）与 `build-release.yml`（上游原有，打 tag 时发 release）。本机没有 macOS 时用前者。

在 Xcode 中配置好签名后构建已签名 IPA：

```sh
./build-darkspeed.sh
```

生成待后续签名的未签名 IPA：

```sh
DARKSPEED_UNSIGNED=1 ./build-darkspeed.sh
```

安装包输出为 `packages/DarkSpeed_1.0-1.ipa`。版本 `1.0-1` 对应版本号 `1.0`、构建号 `1`。

## 致谢

- [Lara](https://github.com/rooootdev/lara)：提供底层实现与 RemoteCall 参考。
- [i_82 / Lessica](https://github.com/Lessica)：原始 [TrollSpeed](https://github.com/Lessica/TrollSpeed) 项目。
- opa334：kernel exploit PoC。
- ChOma 与 XPF。
- AppInstaller iOS：协助处理 offsets。
- AlfieCG：libgrabkernel2。
- [Lara 的所有贡献者](https://github.com/rooootdev/lara/graphs/contributors)。

项目保留原仓库历史，以继续保留原作者与贡献者记录。

## 许可

参见 [LICENSE](LICENSE)。仓库内第三方组件仍分别适用其自身的许可与声明。
