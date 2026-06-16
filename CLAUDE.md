# auto-cue 项目配置

macOS Notch 智能提词器，fork 自 [Textream](https://github.com/f/textream)。

## 技术栈

- **语言**: Swift 5.9+
- **框架**: SwiftUI + AppKit（混合架构）
- **最低系统**: macOS 15 Sequoia
- **硬件**: Apple Silicon & Intel
- **Xcode**: 16.0+

## 架构

MVVM (Swift `@Observable`)，核心组件：

| 文件 | 职责 |
|------|------|
| `TextreamApp.swift` | App 入口、菜单栏、深链接 |
| `ContentView.swift` | 主编辑器 UI + About 页面 |
| `TextreamService.swift` | 服务层、URL Scheme 处理、文件操作 |
| `SpeechRecognizer.swift` | 语音识别引擎（系统 Speech + 本地 SenseVoice 模型） |
| `NotchOverlayController.swift` | 刘海叠加层 + 浮动窗口 |
| `ExternalDisplayController.swift` | Sidecar / 外接显示器输出 |
| `SettingsView.swift` | 设置页（中英双语） |
| `Localizable.xcstrings` | 字符串目录（中文源 + 英文翻译） |
| `MarqueeTextView.swift` | 文字流布局与高亮 |
| `BrowserServer.swift` | 远程连接的 HTTP + WebSocket 服务 |
| `DirectorServer.swift` | 导演模式 HTTP + WebSocket 服务 |
| `UpdateChecker.swift` | GitHub Release 更新检查 |

## 构建

```bash
xcodebuild -project Textream/Textream.xcodeproj -scheme Textream build
```

或在 Xcode 中打开 `Textream/Textream.xcodeproj` 按 `⌘R`。

## 命名规范

- 遵循 Apple Swift 惯例：camelCase 变量/函数，PascalCase 类型
- 文件命名与主类型一致
- Info.plist 中 `CFBundleDisplayName` = `auto-cue`
- URL Scheme 保留 `textream://` 向后兼容
- 用户可见字符串：中文硬编码，英文通过 Localizable.xcstrings 映射（sourceLanguage = zh-Hans）
- 支持中英双语，根据系统语言自动切换

## Fork 定位

基于 Textream 进行功能扩展，不局限于提词 —— 覆盖所有对屏幕讲话的场景（直播、采访、演讲、会议、录制）。
