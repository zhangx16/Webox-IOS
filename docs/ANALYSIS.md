# WeBox 0.1.64 (Android) 逆向分析报告

分析对象：`WeBox-0.1.64-beta.apk`（17,344,415 字节，SHA-256
`3471efd5adf82ade673532f82f5d024cbc76a611a9f20fcc3bcb82be33e7891b`）。
目标：在 iOS 上复现同一套产品能力，而不是移植 DEX 代码。

## 1. 工具与方法

| 工具 | 版本 | 用途 |
| --- | --- | --- |
| REA（`rea-agents` CLI） | 6.8.0 | `doctor`、`capabilities`、`inspect-artifact`、`analyze-javascript-application` |
| androguard | 4.1.4 | 解析 AXML 清单、DEX 类/方法、字符串、字符串交叉引用 |
| Node.js vm | 24.18.0 | 复现原生桥接协议，跑通 Script 1.0 / XPTV 样例 |
| PowerShell / Python | — | 解包、取证、工程生成与校验 |

REA 环境结论（`rea doctor`）：本机缺少 Hopper / Ghidra / IDA / jadx-headless-mcp，
且 Node 24.18.0 低于 REA 推荐版本，因此 **REA 的 Android 专用检查（inspect-android-package /
inspect-android-class / inspect-android-method / decode-android-resources）不可用**；
这些操作统一返回 `capability_unavailable`，提示设置 `REA_JADX_MCP_JAR`。

实际可用的 REA 能力与结果：

1. `rea inspect-artifact WeBox-0.1.64-beta.apk --json` → 成功，产生 147 KB 证据
   （工件清单、子项、哈希），保存为 `docs/evidence/rea-inspect-apk.json`。
2. `rea analyze-javascript-application .../runtime --json` → 返回 `execution_failure`，
   但带 `partial_observation`：统计到 5 个 JS 文件、269,684 字节，
   `parsed_javascript_files: 0`、`skipped_javascript_files: 5`，
   限制说明为 “`cheerio.js: Provider javascript-static-analysis adapter failed`”。
   即 REA 完成工件清点（sha256 + 路径）但未能解析 IIFE 打包的 JS。
   证据：`docs/evidence/rea-javascript-analysis.json`。

因此主体逆向改用 androguard 做静态解析，并用 Node 复现运行时协议做行为验证。
这不是 REA 的替代品，而是 REA 在本机能力边界内的补足；结论均带证据路径。

## 2. 应用构成

```
assets/             mpv-cacert.pem、licenses
lib/arm64-v8a/      libmpv.so 8.0MB、libavcodec.so 11.8MB、libavfilter/avformat/avutil/swscale…
                    libquickjs.so 903KB、libplayer.so 21KB
runtime/            cheerio.js 155KB、cryptojs.js 72KB、webox.js 19.7KB、xptv.js 9.6KB、
                    widget.js 7.7KB、web-licenses.txt
modules/            demo.js（示例脚本）
classes.dex         3.1MB，2818 个类，17,279 条字符串
resources.arsc      244KB
```

结论：**原生层只是宿主，业务在 JS 运行时里**。`runtime/webox.js` 顶部注释直接写明
“WeBox Script 1.0 native host. Site algorithms never belong in this file.”。

原生职责：

- QuickJS 引擎（`com.dokar.quickjs`，108 个类）执行脚本；
- 用 libmpv/FFmpeg 播放（`is.xyz.mpv` 包）；
- OkHttp 网络、TMDB 客户端、下载服务、WebView 网站验证；
- Android UI（Compose）与播放器手势。

## 3. 清单与权限

```
package           dev.webox.app
versionName       0.1.64      versionCode 67
minSdk 23         targetSdk 36
application       dev.webox.app.WeBoxApplication
                  allowBackup=false, usesCleartextTraffic=true, extractNativeLibs=true
activities        MainActivity（launcher，竖屏）
                  PlayerActivity（configChanges 0x4A0）
                  ReleaseNoticeActivity / ArtworkActivity / ScriptViewerActivity
service           DownloadService（foregroundServiceType=dataSync）
permissions       INTERNET, ACCESS_NETWORK_STATE, MODIFY_AUDIO_SETTINGS,
                  FOREGROUND_SERVICE, FOREGROUND_SERVICE_DATA_SYNC,
                  POST_NOTIFICATIONS, WAKE_LOCK
```

证据：`docs/evidence/AndroidManifest.xml`、`docs/evidence/apk-info.json`。
`usesCleartextTraffic=true` 对应 iOS 的 `NSAllowsArbitraryLoads`；
`DownloadService` 是前台数据同步服务，iOS 端以“下载管理 + 后台任务窗口”对应。

## 4. 脚本接口（最重要的发现）

`runtime/widget.js` 定义了公共 Widget 契约，`runtime/webox.js` 在其上实现 Script 1.0。
原生方法表可以从 `Lm71;`（同步桥接分发器）的字符串常量完整还原：

| 方法 | 参数（节选） | 语义 |
| --- | --- | --- |
| `request` | url, method, headers, params, timeout, data, httpsOnly, base64Data, decodable, zlibMode | HTTP 请求 |
| `crypto.aes` | text, key, iv, mode(CBC/ECB/CTR/GCM), padding, *Encoding, decrypt | AES |
| `crypto.hash` / `crypto.hmac` | algorithm, text, key, encodings | 摘要 / HMAC |
| `crypto.encode` | text, from, to（utf8/base64/hex/latin1） | 编码转换 |
| `crypto.random` | size | 安全随机 |
| `crypto.rsa` | text, key, decrypt | JSEncrypt 兼容 RSA |
| `url.validate` / `url.resolve` / `url.origin` | url, base, allowHttp | URL 处理 |
| `storage.*` / `native.store.*` | key, value | 脚本私有 KV |
| `sharedCache.*` | namespace, key, value | 跨脚本共享缓存 |
| `binary.size/read/slice/write/patch/concat` | handle, offset, length, data(base64) | 媒体二进制处理 |
| `native.cache.generation` / `native.cache.seconds` | seconds | 缓存代数与时效 |
| `native.cancelled` | — | 取消标记 |
| `i18n` | value | 本地化 |
| `tmdb` | api, params | 影视资料 |
| `runtime.capabilities` | — | 能力声明（compute/html/crypto/…） |

脚本契约（`WeBox.define`）：`api`(1.0/1.1)、`id`、`name`、`version`、
`settings.fields`、`filters`、`list`、`detail`、`play`、`search`、`cache`、`requires`、`media`、`icon`、`allowHttp`。
返回值被 JS 层强校验（`assert` + `fail(code)`），错误码固定为
CONFIG_REQUIRED / AUTH_REQUIRED / NETWORK / RATE_LIMITED / NOT_FOUND / UNSUPPORTED /
INVALID_RESPONSE / CANCELLED / TIMEOUT。

`runtime/xptv.js` 是 XPTV（getConfig / getCards / getTracks / getPlayinfo）兼容层，
通过 `__weboxXptvAttach(id, app)` 挂载，并暴露 `compatBrowse` / `compatSearch` /
`loadDetail` / `loadResource`。

链接协议：`webox:content:<id>`、`webox:episode:<urlencoded json>`；
xptv 播放链接为 `compat-play:<ext json>`。

证据：`docs/evidence/bridge-and-player-strings.txt`（`Lm71;` 的完整字符串表）。

## 5. 播放器

`Lun0;` 是 PlayerActivity 的 mpv 初始化单元，字符串常量给出播放配置：

```
vo=gpu  gpu-context=android  hwdec  (mediacodec-copy)
demuxer-max-bytes / demuxer-max-back-bytes / demuxer-cache-time / video_buffer_mb / video_buffer_seconds
tls-ca-file=assets/mpv-cacert.pem   network-timeout   keep-open
http-header-fields（线路自定义请求头）  speed  panscan  video-params/aspect
```

UI 字符串同时给出引擎选项：`系统解码与 Media3 播放`、`MPV / FFmpeg 与源码说明`、
`硬件解码`、`画面比例`、`播放速度`、`长按倍速`、`左侧纵滑调亮度，右侧纵滑调音量`、
`锁定播放器`。iOS 端据此实现 AVPlayer 引擎 + 手势 + 倍速/画面比例/锁定。

## 6. 存储与数据

字符串证据表明 Android 端以 JSON 文件持久化：

- `sources.json`、`m3u/sources.json`、`vod/sources.json`（内容源）
- `browse-history.json`（浏览记录，最多 200 条）
- `favorites`、`playback_history`（收藏与播放进度）
- `WeBox-backup.json`（备份）、`WeBox-diagnostics.txt`（诊断日志）
- 脚本私有键前缀 `__webox.config.`，共享缓存前缀 `shared-`

iOS 端改为 SQLite 单表 `objects(kind,id,json,num,expires)`，
kind 分别承载 sources / favorites / browse / progress / download / kv.<source> / shared.<ns> / meta。

## 7. 其他被复现的行为

- **TMDB 影视资料**：`Lv6;` 中出现 `https://api.themoviedb.org/`、
  `https://tmdb.quswer.com/`、`https://recommend.feifeiduck.com/tmdb/`，
  UA `WeBox/0.3.0`，路径 `search/multi`、`movie`、`tv/`、`discover/`、`genre/`，
  `append_to_response=credits,recommendations`、`include_image_language=zh,en,null`。
- **网站验证**：`不依赖 WebView 也可用` 的检测串 `cf-chl-` / `SafeLineChallenge` /
  `Just a moment`，以及“完成网站验证”流程；iOS 首版未实现验证窗口。
- **REXENC 加密脚本**：取钥协议 + 头部校验（`REXENC 取钥响应…` 等 20 余条错误串）。
- **独立计算**：`https://webox.invalid/compute/index.html` + `compute` 能力位，
  脚本 `requires:['compute']` 时需宿主支持。
- 脚本文件标记：`/* WEBOX_USER_SCRIPT_BEGIN */` / `END`，用于从网页/文件中抽取脚本。

## 8. 未复现项与原因

| 项目 | 原因 |
| --- | --- |
| libmpv 播放内核 | iOS 无法直接复用 Android .so；用 AVPlayer 覆盖 HLS/MP4，VLCKit 作为可选扩展点 |
| JSON 网页 XPath 规则 | 规则 DSL 未在 APK 中以可读形式暴露，强行猜测会与 Android 版不兼容 |
| REXENC 加密脚本 | 取钥协议依赖服务端，且属于可选分发机制 |
| 独立计算 compute | 契约（输入/输出/二进制模块）未在 JS 侧完整暴露，首版关闭能力位并明确报错 |
| 网站验证窗口 | 需要 WKWebView + Cookie 同步，属后续迭代 |

## 9. 证据索引

| 文件 | 内容 |
| --- | --- |
| `docs/evidence/AndroidManifest.xml` | androguard 解码的清单 |
| `docs/evidence/apk-info.json` | 包名、版本、权限、组件 |
| `docs/evidence/rea-inspect-apk.json` | REA 工件清点证据（147 KB） |
| `docs/evidence/rea-javascript-analysis.json` | REA JS 分析的部分观测与限制 |
| `docs/evidence/bridge-and-player-strings.txt` | 桥接分发器与播放器类的字符串表 |
| `docs/evidence/ui-strings-sample.txt` | 中文 UI 文案样本（功能面证据） |
