<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Textream 图标">
</p>

<h1 align="center">Textream</h1>

<p align="center">
  <a href="README.md">English</a>
</p>

<p align="center">
  <strong>一款免费的 macOS 提词器，支持实时逐词跟读、经典自动滚动和声控滚动。</strong>
</p>

<p align="center">
  为主播、采访者、演讲者和播客创作者打造。
</p>

<p align="center">
  <a href="#下载">下载</a> · <a href="#功能特性">功能特性</a> · <a href="#工作原理">工作原理</a> · <a href="#从源码构建">构建</a>
</p>

<p align="center">
  <img src="docs/video.gif" width="600" alt="Textream 演示">
</p>

---

## Textream 是什么？

Textream 是一款免费、开源的 macOS 应用，提供三种提词模式：**逐词跟读**（你说到哪就高亮到哪）、**经典模式**（固定速度自动滚动）和 **声控模式**（说话时滚动，安静时暂停）。它可以把文本显示在屏幕顶部优雅的 **灵动岛风格覆盖层**、**可拖拽悬浮窗口**，或者 **Sidecar iPad 全屏显示** 中。内容只对你可见，对观众不可见。

粘贴脚本，点击播放，然后开始说话。结束后，覆盖层会自动关闭。

## 下载

**[在 Releases 下载最新 .dmg](https://github.com/f/textream/releases/latest)**

或者通过 Homebrew 安装：

```bash
brew install f/textream/textream
```

> 需要 **macOS 15 Sequoia** 或更高版本。支持 Apple Silicon 和 Intel。

### 首次启动

由于 Textream 并非通过 Mac App Store 分发，macOS 在首次打开时可能会阻止运行。请在终端执行一次：

```bash
xattr -cr /Applications/Textream.app
```

然后右键应用，选择 **打开**。完成首次启动后，macOS 会记住你的选择。

## 功能特性

### 提词模式

| 模式 | 说明 | 麦克风 |
|---|---|---|
| **逐词跟读**（默认） | 设备端语音识别会在你说出每个词时同步高亮。不上云、低延迟、可离线使用。支持数十种语言。 | 必需 |
| **经典模式** | 以固定速度自动滚动。 | 不需要 |
| **声控模式** | 说话时滚动，静音或停顿时暂停。非常适合自然语速。 | 必需 |

- **滚动速度** — 经典模式和声控模式下可调 0.5–8 词/秒。
- **语音语言** — 可为逐词跟读模式选择语音识别语言。
- **鼠标滚轮追进度** — 在经典模式和声控模式下，可用鼠标滚动快速前后跳转。滚动时计时器暂停，松手后从新位置继续。

### 覆盖层模式

| 模式 | 说明 |
|---|---|
| **固定在刘海下方** | 灵动岛形态覆盖层，锚定在 MacBook 刘海下方，始终位于所有应用之上。 |
| **悬浮窗口** | 可拖拽到屏幕任意位置，始终置顶。 |
| **全屏** | 在任意显示器上全屏显示提词器。按 **Esc** 停止。 |

#### 固定在刘海下方选项

- **跟随鼠标** — 光标在哪块屏幕，刘海提词器就出现在哪块屏幕。
- **固定显示器** — 将刘海提词器固定到指定屏幕。

#### 悬浮窗口选项

- **跟随光标** — 窗口会跟随鼠标移动，提供一个悬浮停止按钮供你关闭。
- **玻璃效果** — 半透明毛玻璃背景，透明度可调（0–60%）。

#### 全屏选项

- **显示器选择** — 选择在哪块屏幕显示全屏提词器。
- **Esc 停止** — 按 Escape 键关闭全屏覆盖层。

### 尺寸

- **宽度** — 覆盖层宽度可调（280–500 px）。
- **高度** — 文本区域高度可调（100–400 px）。

### 字体与颜色

| 设置项 | 可选项 |
|---|---|
| **字体族** | Sans、Serif、Mono、OpenDyslexic（阅读障碍友好） |
| **字号** | XS（14 pt）、SM（16 pt）、LG（20 pt）、XL（24 pt） |
| **高亮颜色** | White、Yellow、Green、Blue、Pink、Orange |

### 外接显示器与 Sidecar

| 模式 | 说明 |
|---|---|
| **关闭** | 不输出到外接显示器。 |
| **提词器** | 在选定的外接显示器或 Sidecar iPad 上全屏显示提词器。 |
| **镜像** | 为专业提词镜系统输出翻转画面。 |

- **镜像轴** — Horizontal（常见提词镜方案）、Vertical，或 Both（180° 旋转）。
- **目标显示器** — 从已连接的外接显示器和 Sidecar iPad 中选择。
- **不出现在共享画面中** — 在录屏和视频会议中隐藏覆盖层。

### 远程连接

通过本地网络浏览器连接，你可以在**任意设备**上查看提词器，包括手机、平板或另一台电脑。

- **在 设置 → Remote 中启用** — 在你的 Mac 上启动一个轻量级 HTTP + WebSocket 服务。
- **二维码** — 用手机或平板扫描生成的二维码，立即打开提词器。
- **实时同步** — 单词高亮、波形动画和阅读进度都通过 WebSocket 实时更新。
- **无需安装 App** — 任意现代浏览器均可使用，远端设备无需安装任何软件。
- **端口可配置** — 默认端口 7373，可在高级设置中修改。
- **完全本地** — 所有流量都停留在本地网络内，不会离开你的 Wi‑Fi。

### 导播模式

让其他人远程控制你的提词器。导播可以在任意浏览器中实时编写、编辑并推送脚本到你的提词器。

- **在 设置 → Director 中启用** — 启动专用 HTTP + WebSocket 服务（默认端口 7575）。
- **远程网页 UI** — 导播可打开一个适配移动端的网页编辑器。
- **实时文本编辑** — 导播输入或粘贴脚本后点击 Go，你的提词器会立即以逐词跟读模式启动。
- **已读区锁定高亮** — 网页编辑器中，已读文本会被高亮并锁定，仅未读部分可继续编辑。
- **实时同步** — 阅读进度、波形、麦克风状态和音量等级以 10 Hz 的频率同步到导播浏览器。
- **单页模式** — 导播模式只使用单页文本，不使用多页脚本。
- **编辑器禁用** — 导播模式启用后，macOS 本地编辑器会被二维码覆盖层替代，由导播全权控制内容。
- **二维码** — 可从设置页或编辑器覆盖层扫码或分享二维码，快速连接导播端。

### 文件支持

- **导入 PowerPoint 备注** — 拖入 `.pptx` 文件即可提取演讲备注并按页导入。若使用 Keynote 或 Google Slides，请先导出为 PowerPoint。
- **保存为 `.textream` 文件** — 可将脚本保存为 `.textream` 文件，方便随时复用与归档。
- **多页支持** — 支持多页导航和自动翻页。在跟随光标模式下，翻页前会有 3 秒倒计时。

### 其他

- **实时波形** — 语音活动可视化，随时确认麦克风是否正常拾音。
- **点击跳转** — 点击覆盖层中的任意词，跟读位置即可跳转到那里。
- **暂停与继续** — 偏稿、休息、临时插话都没问题，回来后可从原处继续。
- **静音 / 取消静音** — 任意模式下都可在覆盖层中切换麦克风状态。
- **完全私密** — 所有处理都在本机完成。无需账号、无追踪、无数据离开你的 Mac。
- **自动更新检查** — 启动时和 Textream 菜单中都会检查 GitHub Releases 新版本。
- **开源** — 使用 MIT 协议，欢迎贡献。

## 适用人群

| 使用场景 | Textream 如何帮助你 |
|---|---|
| **主播** | 在不移开镜头视线的情况下阅读赞助口播、公告和提纲。 |
| **采访者** | 在保持自然眼神交流的同时，让问题始终可见。 |
| **演讲者** | 更从容地完成 keynote、演示和公开分享，不再丢失节奏。 |
| **播客创作者** | 录制时免手操作查看 show notes、广告口播和话题提纲。 |

## 工作原理

1. **粘贴脚本** — 将提纲、采访问题或完整稿件放入文本编辑器。
2. **点击播放** — 灵动岛覆盖层会从屏幕顶部滑下。
3. **开始说话** — 你读到哪，高亮就跟到哪。读完后覆盖层自动关闭。

## 从源码构建

### 环境要求

- macOS 15+
- Xcode 16+
- Swift 5.0+

### 构建

```bash
git clone https://github.com/f/textream.git
cd textream/Textream
open Textream.xcodeproj
```

在 Xcode 中使用 ⌘R 构建并运行。

### 项目结构

```
Textream/
├── Textream.xcodeproj
├── Info.plist
└── Textream/
    ├── TextreamApp.swift              # 应用入口，处理深链接
    ├── ContentView.swift              # 主文本编辑 UI + About 页面
    ├── TextreamService.swift          # 服务层，处理 URL scheme
    ├── SpeechRecognizer.swift         # 本地语音识别引擎
    ├── NotchOverlayController.swift   # 灵动岛 + 悬浮覆盖层
    ├── ExternalDisplayController.swift # Sidecar / 外接显示器输出
    ├── NotchSettings.swift            # 用户偏好与预设
    ├── SettingsView.swift             # 标签页式设置界面
    ├── MarqueeTextView.swift          # 单词流布局与高亮
    ├── BrowserServer.swift            # Remote 模式 HTTP + WebSocket 服务
    ├── DirectorServer.swift           # Director 模式 HTTP + WebSocket 服务
    ├── PresentationNotesExtractor.swift # PPTX 演讲备注提取
    ├── UpdateChecker.swift            # GitHub Releases 更新检查
    └── Assets.xcassets/               # 应用图标与颜色资源
```

## URL Scheme

Textream 支持 `textream://` URL scheme，可直接启动提词覆盖层：

```
textream://read?text=Hello%20world
```

它还会注册为 macOS Service，因此你可以在任意应用中选中文本，然后通过 Services 菜单发送到 Textream。

## 导播模式 API

导播模式会在本地网络中暴露一个 HTTP 服务和一个 WebSocket 服务。你可以基于下面的协议自己实现导播客户端。

### 端口

| 服务 | 默认端口 | 可配置位置 |
|---|---|---|
| **HTTP**（内置 Web UI） | `7575` | Settings → Director → Advanced |
| **WebSocket**（双向通信） | `7576`（HTTP 端口 + 1） | 自动 |

### 连接方式

1. 连接到 `ws://<mac-ip>:<ws-port>`（例如 `ws://192.168.1.42:7576`）。
2. 只要脚本处于激活状态，服务端就会立即以约 10 Hz 的频率推送 **state frame** JSON。
3. 客户端发送 **command frame** JSON 即可控制提词器。

### 命令（Client → App）

通过 WebSocket 发送 JSON 消息：

#### `setText` — 开始读取一份新脚本

```json
{
  "type": "setText",
  "text": "Welcome everyone to today's live stream..."
}
```

替换当前文本，启动逐词跟读，并打开提词覆盖层。这等价于内置网页 UI 中点击 **Go**。

#### `updateText` — 在提词进行中编辑未读文本

```json
{
  "type": "updateText",
  "text": "Welcome everyone to today's live stream We changed the rest of the script...",
  "readCharCount": 42
}
```

更新整段脚本文本，同时保留当前阅读进度。`readCharCount` 表示已读并锁定的字符数；只有这个偏移之后的内容会被替换。适合直播或演讲过程中实时改稿。

#### `stop` — 停止提词器

```json
{
  "type": "stop"
}
```

停止逐词跟读并关闭覆盖层。

### 状态（App → Client）

服务端会在每个 tick（约每 100 ms）广播一个 JSON 对象：

```json
{
  "words": ["Welcome", "everyone", "to", "today's", "live", "stream"],
  "highlightedCharCount": 24,
  "totalCharCount": 120,
  "isActive": true,
  "isDone": false,
  "isListening": true,
  "fontColor": "#F5F5F7",
  "lastSpokenText": "Welcome everyone to today's",
  "audioLevels": [0.12, 0.34, 0.08, ...]
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `words` | `string[]` | 按显示顺序拆分后的单词数组。 |
| `highlightedCharCount` | `int` | 当前已识别字符数，可用来确定已读边界。 |
| `totalCharCount` | `int` | 整段脚本的总字符数。 |
| `isActive` | `bool` | 为 `true` 时表示提词覆盖层可见，且已加载脚本。 |
| `isDone` | `bool` | 当 `highlightedCharCount >= totalCharCount` 时为 `true`。 |
| `isListening` | `bool` | 为 `true` 时表示麦克风处于监听状态。 |
| `fontColor` | `string` | 覆盖层文本的 CSS 颜色值（来自用户偏好）。 |
| `lastSpokenText` | `string` | 最近一次识别到的语音片段。 |
| `audioLevels` | `double[]` | 音频电平采样数组（0.0–1.0），用于绘制波形。 |

当覆盖层未激活时，服务端会发送 `isActive: false` 且数组为空的状态帧。

### 示例：最小 Python 客户端

```python
import asyncio, json, websockets

async def director():
    async with websockets.connect("ws://192.168.1.42:7576") as ws:
        # Send a script
        await ws.send(json.dumps({
            "type": "setText",
            "text": "Hello everyone, welcome to the show."
        }))

        # Listen for state updates
        async for msg in ws:
            state = json.loads(msg)
            pct = 0
            if state["totalCharCount"] > 0:
                pct = state["highlightedCharCount"] / state["totalCharCount"] * 100
            print(f"Progress: {pct:.0f}%  Done: {state['isDone']}")
            if state["isDone"]:
                break

        # Stop
        await ws.send(json.dumps({"type": "stop"}))

asyncio.run(director())
```

## 许可证

MIT

---

<p align="center">
  最初创意来自 <a href="https://x.com/semihdev">Semih Kışlar</a>，感谢他的启发！<br>
  由 <a href="https://fka.dev">Fatih Kadir Akin</a> 制作
</p>
