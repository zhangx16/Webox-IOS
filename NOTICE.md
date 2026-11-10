# NOTICE

## 这是什么

WeBox for iOS —— 对 Android 应用 `dev.webox.app`（WeBox 0.1.64-beta）的互操作重写实现。
工程内不含 APK 的 Kotlin/DEX 代码，原生层为独立 Swift 实现。

## 第三方组件

| 组件 | 许可 | 位置 |
| --- | --- | --- |
| cheerio（服务端 HTML 解析） | MIT | `WeBox/Resources/runtime/cheerio.js` |
| crypto-js | MIT | `WeBox/Resources/runtime/cryptojs.js` |
| WeBox JS 运行时（widget/webox/xptv） | 随 APK 分发 | `WeBox/Resources/runtime/` |
| 应用图标 | 随 APK 分发 | `WeBox/Assets.xcassets/AppIcon.appiconset/` |

完整许可文本见 `WeBox/Resources/runtime/web-licenses.txt` 与应用内“设置 → 开源许可”。

## 免责声明

本项目仅用于技术研究与互操作性验证。内容源脚本、直播源与影视地址由用户自行添加，
与本项目无关；请遵守当地法律与网站服务条款。
