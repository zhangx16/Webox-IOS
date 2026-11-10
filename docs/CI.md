# 用 GitHub Actions 编译 IPA

仓库：`git@github.com:zhangx16/Webox-IOS.git`
工作流：`.github/workflows/build.yml`（macOS 15 runner + Xcode 16）

## 产物

每次 push 到 `main` 或手动触发（Actions → Build iOS IPA → Run workflow）都会产出：

| 产物 | 说明 |
| --- | --- |
| `WeBox-unsigned.ipa` | 未签名包，需用 AltStore / Sideloadly / TrollStore 重签后安装 |
| `WeBox-unsigned.tipa` | 同上，扩展名适配 TrollStore |
| `xcodebuild.log` | 完整编译日志（失败时也会上传） |
| `WeBox-signed-*.ipa` | 仅在配置了签名 Secrets 时生成，可直接安装 |

在 Actions run 页面底部 **Artifacts** 下载。

## 未签名 IPA 怎么装

未签名 IPA 不能直接双击安装，需要在本机重签：

1. **AltStore / Sidekick**：把 IPA 加入 AltStore，用你的 Apple ID 免费签名（7 天有效）。
2. **Sideloadly**：Windows 上填 Apple ID 直接签。
3. **TrollStore**：仅支持特定 iOS 版本，用 `.tipa` 直接安装。
4. **Xcode**：`ios-deploy` / Xcode Devices 面板安装需要已签名的 .app。

## 配置签名（可选，生成可安装 IPA）

在仓库 Settings → Secrets and variables → Actions 中添加：

| Secret | 说明 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 导出的 `.p12` 证书，base64 编码：`base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | 导出 p12 时设置的密码 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `PROVISIONING_PROFILE_SPECIFIER` | Profile 名称（Xcode 里显示的名字） |
| `TEAM_ID` | 10 位 Team ID |
| `EXPORT_METHOD` | `development` / `ad-hoc` / `app-store` / `enterprise` |

未配置这些 Secrets 时，工作流只跑「未签名构建」，不会失败。

## Runner 成本

- 公开仓库：macOS runner 免费。
- 私有仓库：macOS 分钟数按 10 倍计入（每次构建约 5–10 分钟额度）。

## 本地复现

macOS 上等价命令：

```bash
xcodebuild -project WeBox.xcodeproj -scheme WeBox -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build

bash scripts/package_ipa.sh Release
# dist/WeBox-unsigned.ipa
```

## 常见编译失败

| 报错 | 处理 |
| --- | --- |
| `No such module 'JavaScriptCore'` | 确认 SDK 选择 iphoneos，而不是 macOS |
| `Signing for "WeBox" requires a development team` | 工作流已带 `CODE_SIGNING_ALLOWED=NO`；本地构建时同样加上 |
| `Asset catalog warning: AppIcon` | 单尺寸 1024 图标在 Xcode 16 下可用；如需上架请补齐各尺寸 |
| Swift 并发告警 | 项目为 Swift 5 模式，告警不影响构建 |
