# 证据文件

由分析流程直接产出，未手工编辑：

| 文件 | 产出方式 |
| --- | --- |
| `AndroidManifest.xml` | androguard `APK.get_android_manifest_xml()` |
| `apk-info.json` | androguard：包名、版本、权限、组件、签名 |
| `bridge-and-player-strings.txt` | DEX 字符串 + 方法交叉引用，按类 `Lm71;`（桥接）、`Lv6;`（TMDB）、`Lun0;`（mpv）、`Ldm0;`（链接）导出 |
| `ui-strings-sample.txt` | 中文 UI 文案前 140 条（功能面证据） |
| `rea-inspect-apk.json` | `rea inspect-artifact WeBox-0.1.64-beta.apk --json` |
| `rea-javascript-analysis.json` | `rea analyze-javascript-application runtime --json`（partial_observation） |

复现命令（工作目录为分析机上的 `webox-analysis`）：

```bash
python scripts/analyze.py WeBox-0.1.64-beta.apk out        # 清单 + 字符串
python scripts/xref.py                                     # 字符串 → 方法映射
python scripts/class_strings.py "Lm71;" "Lv6;" "Lun0;" "Ldm0;"
node node_modules/rea-agents/scripts/rea.mjs inspect-artifact WeBox-0.1.64-beta.apk --json
node node_modules/rea-agents/scripts/rea.mjs analyze-javascript-application apk/runtime --json
```
