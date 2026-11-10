# WeBox for iOS

WeBox（Android 版 `dev.webox.app` 0.1.64 / versionCode 67）的原生 iOS 重写版本：
用 SwiftUI + JavaScriptCore + AVPlayer 复现同一套「内容源脚本 + 影视浏览 + 播放器 + 离线下载」产品。

Android 端的内核是 **QuickJS + 一组共享 JS 运行时**（`runtime/widget.js`、`runtime/webox.js`、
`runtime/xptv.js`、cheerio、crypto-js），原生层只提供桥接。本项目把原生层换成 iOS 实现，
**JS 运行时文件与 Android 版逐字节一致**，因此面向 WeBox 编写的脚本无需修改即可在 iOS 上运行。

## 功能

| 模块 | 说明 |
| --- | --- |
| 发现 | 内容源切换、栏目入口、最近浏览、收藏预览 |
| 分类浏览 | 筛选器（select/多级依赖）、分页、下拉刷新、列表内搜索 |
| 搜索 | 跨内容源搜索，结果按来源分组，可选参与搜索的来源 |
| 详情 | 海报/简介/评分、分组选集、收藏、续播进度 |
| 播放 | AVPlayer + HLS/MP4、请求头、内存 HLS 清单、线路切换、选集连播 |
| 手势 | 左右滑动快进、左侧纵滑亮度、右侧纵滑音量、长按倍速、双击暂停、锁定 |
| 播放设置 | 倍速、画面比例（适应/裁切/拉伸）、缓冲、默认引擎 |
| 下载 | 直链与 HLS 分片下载、断点续传、暂停/继续、本地离线播放 |
| 内容源 | JS 脚本（Script 1.0）、XPTV 脚本、M3U 直播、AppleCMS VOD、链接/文件/文本导入 |
| 存储 | SQLite 持久化脚本私有存储、共享缓存、收藏、进度、下载记录 |
| 备份 | `WeBox-backup.json` 导出/恢复（设置 + 内容源 + 收藏） |
| 诊断 | 诊断日志、接口缓存与图片缓存清理 |

## 构建

需要 Xcode 15 或更新版本（iOS 16.0+），无任何第三方依赖。

```bash
open WeBox.xcodeproj
# 选择 Team（Signing & Capabilities），连接设备或模拟器后运行
```

工程文件由 `scripts/gen_xcodeproj.py` 生成，新增源文件后重新执行即可：

```bash
python3 scripts/gen_xcodeproj.py     # 重新生成 WeBox.xcodeproj
python3 scripts/validate_project.py  # 校验 pbxproj 引用与文件是否存在
python3 scripts/check_swift.py       # Swift 结构检查（括号配平/截断）
```

也可以改用 XcodeGen：`xcodegen generate`（见 `project.yml`）。

## 冒烟测试

1. 运行 App → 设置 → 导入内容源 → 本地文件 → 选择 `samples/demo-source.js`。
2. 发现页应出现「公开示例」，进入栏目可见 2 个条目（Blender 开放电影 + Apple HLS 测试流）。
3. 进入详情 → 立即播放，可验证 MP4 与 HLS 两条链路。
4. 详情 → 下载，验证 `收藏 → 下载` 中的进度与离线播放。

其它示例：

- `samples/xptv-sample.js`：XPTV 兼容脚本（getConfig/getCards/getTracks/getPlayinfo）。
- `samples/live-sample.m3u`：直播/点播混合的 M3U 列表。
- `samples/vod-sample.json`：AppleCMS v10 接口配置（需替换为可用地址）。

## 目录

```
WeBox/
  App/          应用入口、Tab 根视图
  Core/         数据模型、设置、日志
  Storage/      SQLite 存储与 App 级状态（Library）
  Net/          HTTP 客户端、TMDB 客户端
  Crypto/       Widget.crypto 原生实现（AES/HMAC/RSA/编码）
  Script/       JavaScriptCore 宿主与 Widget 桥接
  Sources/      内容源管理（脚本/M3U/VOD）与 Provider
  Playback/     AVPlayer 播放会话、播放器界面、播放地址解析
  Download/     下载管理（直链 + HLS 分片）
  UI/           发现、浏览、搜索、详情、收藏、下载、设置
  Resources/runtime/  Android 版同款 JS 运行时
WeBox-Info.plist   Info.plist（允许明文 HTTP、横屏、后台音频）
samples/           可直接导入的示例内容源
docs/              逆向分析报告与功能对照
```

## 脚本引擎

脚本在独立的串行队列上执行，每个内容源一个 `JSContext`。桥接协议与 Android 一致：

- 入口：`Widget.callSync(method, params)` / `Widget.callAsync(method, params)`
- 原生方法：`request`、`crypto.*`、`url.*`、`storage.*`、`sharedCache.*`、`binary.*`、
  `native.cache.*`、`native.cancelled`、`i18n`、`tmdb`、`runtime.capabilities`
- 返回值约定：原生层返回 `{"ok":true,"result":"<json>"}` 信封，JS 包装层解包后抛错或返回 JSON 文本，
  与 Android 端 `__nativeSync` / `__nativeAsync` 的语义一致。

关键实现点：

- `ScriptEngine` 负责生命周期、超时、取消与 Promise 驱动（`__wbHostAwait` + 微任务泵）。
- 脚本的标准接口由 `runtime/webox.js` 提供（`__wbList`/`__wbSearch`/`__wbDetail`/`__wbPlay`），
  XPTV 兼容层由 `runtime/xptv.js` 提供（`compatBrowse`/`loadDetail`/`loadResource`）。
- 媒体处理器（`mediaProcessor`）通过 `__wbMediaRequest` / `__wbMediaResponse` 支持请求改写。

## 已知限制

见 [docs/PARITY.md](docs/PARITY.md)。要点：

- Android 使用 libmpv（含 FFmpeg），iOS 使用 AVPlayer；MKV/AVI 等容器与部分字幕需要接入
  VLCKit（`PlaybackEngine.vlc` 已留出集成点，`VLCBridge` 自动探测）。
- JSON 网页 XPath 规则、REXENC 加密脚本、独立计算（`compute`）未在首版实现，导入时会明确报错。
- 下载在前台会话中运行（配合后台任务窗口），未使用 background URLSession。

## 许可与来源

- 本工程为互操作用途的独立实现，不含 Android APK 的 Kotlin/DEX 代码。
- `WeBox/Resources/runtime/` 来自 WeBox APK 的 JS 运行时（cheerio、crypto-js 为 MIT，
  mpv/FFmpeg 许可说明见 `runtime/web-licenses.txt`）。
- 应用图标沿用 APK 的 `res/XD.png` 资源，仅用于本移植版本。
