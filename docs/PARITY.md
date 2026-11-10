# Android → iOS 功能对照

图例：✅ 已实现　🟡 部分实现　⛔ 未实现（有明确提示）

| 能力 | Android 0.1.64 | iOS 版 | 备注 |
| --- | --- | --- | --- |
| WeBox Script 1.0（`WeBox.define`） | ✅ QuickJS | ✅ JavaScriptCore | `runtime/webox.js` 原样复用 |
| XPTV 兼容脚本 | ✅ | ✅ | `runtime/xptv.js` + `__weboxXptvAttach` |
| 脚本 bridge（request/crypto/url/storage/sharedCache/binary/cache/i18n/tmdb） | ✅ | ✅ | 方法名与参数一致 |
| 媒体处理器 mediaProcessor | ✅ | 🟡 | 支持 request 改写与 response 处理，未覆盖全部分片链路 |
| 内存 HLS 清单（memoryHls） | ✅ | ✅ | 相对地址重写后写本地 m3u8 |
| 独立计算 compute | ✅ | ⛔ | 能力位关闭，调用时报“当前运行环境未提供独立计算能力” |
| M3U 直播 | ✅ | ✅ | 分组、搜索、直播标识 |
| AppleCMS VOD 接口 | ✅ | ✅ | `ac=list / ac=videolist` |
| JSON 网页 XPath 规则 | ✅ | ⛔ | 导入时提示改用 JS/VOD |
| 来源合集 / 订阅更新 | ✅ | 🟡 | 支持链接导入与“检查并更新”，合集未实现 |
| REXENC 加密脚本 | ✅ | ⛔ | 未实现取钥与解密 |
| 网站验证（WebView） | ✅ | ⛔ | 首版无验证窗口 |
| 发现页 / 首页分区 | ✅ | 🟡 | 内容源、栏目、最近浏览、收藏；无自定义分区编辑 |
| 分类浏览 + 筛选器 | ✅ | ✅ | select + 依赖字段（展示层简化） |
| 跨源搜索 | ✅ | ✅ | 顺序搜索并分组展示 |
| 详情 / 分组选集 | ✅ | ✅ | 分组切换、集数网格 |
| 收藏 | ✅ | ✅ | 收藏/取消，收藏页 |
| 播放进度 / 续播 | ✅ | ✅ | 每 5 秒落库，进入详情显示续播位置 |
| 浏览记录 | ✅ | ✅ | 最多 200 条，可关闭 |
| 播放器 | libmpv + Media3 | AVPlayer | HLS/MP4/H.264/H.265 |
| 线路切换 | ✅ | ✅ | 播放器内切换 |
| 选集连播 / 自动下一集 | ✅ | ✅ | 可关闭 |
| 倍速 / 长按倍速 | ✅ | ✅ | 0.5–2.0x + 长按 |
| 画面比例 | ✅ | ✅ | 适应/裁切/拉伸（crop/stretch 简化） |
| 亮度/音量手势、快进、锁定 | ✅ | ✅ | 手势区域与 Android 一致 |
| 字幕 | ✅ mpv | ⛔ | AVPlayer 不外挂 SRT/ASS；需 VLCKit |
| MKV/AVI 等容器 | ✅ mpv | 🟡 | 默认失败提示切换引擎；VLCKit 可补 |
| 下载（直链 + HLS） | ✅ 前台服务 | ✅ | 并发 2、断点续传、暂停/继续 |
| 后台下载 | ✅ | 🟡 | 使用后台任务窗口，未用 background URLSession |
| 下载选集 / 多选 | ✅ | ✅ | |
| 备份 / 恢复 | ✅ | ✅ | `WeBox-backup.json`，拒绝含 Cookie 的源 |
| 诊断日志导出 | ✅ | ✅ | 分享 `WeBox-diagnostics.txt` |
| 图片缓存 / 接口缓存 | ✅ | ✅ | 磁盘 + 内存图片缓存 |
| 外观（浅色/深色） | ✅ | ✅ | 跟随系统/明亮/黑暗 |
| 海报密度 3/4/5 列 | ✅ | ✅ | |
| TMDB 服务与 API Key | ✅ | ✅ | 官方 + 内置镜像候选 |
| 多语言 | ✅ | 🟡 | 界面为中文；脚本 `i18n` 直通 |
| 通知（下载/释放提醒） | ✅ | ⛔ | 首版无通知 |
