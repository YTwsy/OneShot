# 原生采集实测：2026-10-25

本轮验证独立 Swift 采集核心。macOS 14.8.5、Apple Silicon、Swift 6.0.3；OneShot 不调用 Codex 私有捕获服务，没有安装浏览器扩展，CLI 不主动滚动、点击或激活目标窗口。后续对照使用了当前 Codex 会话正常提供的 CUA `getApp` 读取，见下方前置条件说明。实际窗口内容与用户最初提供的 AppShot 已有变化，因此本报告验证能力与语义范围，不给出历史样本逐字一致率。

## 首批快照

以下快照由提交 `7cb7296` 的构建取得。每份都有原图、截图元数据、OCR 与 manifest；成功的 AX 另有结构化 JSON 和可读文本。原始文件仅存本机 `Captures/`，不进入 Git。

| 应用与版本 | 本地快照 | 截图像素 | AX 结果 | OCR 文本块 |
| --- | --- | --- | --- | --- |
| 音乐 1.4.6 | `music-full-002` | 2430 × 1424 | 119 节点，部分属性读取错误 | 34 |
| OpenSurge 0.3.2 | `opensurge-full-001` | 2878 × 1796 | 469 节点，部分属性读取错误 | 124 |
| Cursor 3.27.12 | `cursor-full-001` | 3736 × 2110 | AX 窗口匹配失败，未替换为其他窗口 | 106 |

采集时间分别为 UTC 05:06:56–05:06:58、05:06:16–05:06:19、05:07:24–05:07:26。三份原图都已实际打开核验为对应窗口，OCR 坐标全部落在标准化图像范围内。三个 manifest 都记录窗口身份在前后检查中稳定；这不证明不同来源的内容原子一致。

## 覆盖情况

**音乐：**保留原生侧栏、专辑／音轨、控件角色、选中关系与焦点。音量 `AXValue` 为 `float`、值为 1，专辑／音轨评级为整数 0，焦点引用专辑标题节点 `n71`。参数化 `AXAttributedStringForRange` 取得 15 份富文本结果。没有用这次静止窗口推断搜索词、播放进度或完整音乐资料库。

**OpenSurge：**保留 `wails://localhost/policies`，取得 229 个独立 `AXCheckBox` 节点。通过 `AXTextMarkerRangeForUIElement` → `AXAttributedStringForTextMarkerRange` 取得 WebView 富文本，最长一份 11,384 字符。核验包含全部 13 个策略组名称、协议／UDP 标记、当前出口、延迟与检测范围说明；截图上方未显示的页面标题也在富文本中。这证明读取范围超过当前视口，不代表未加载内容也已取得。

**Cursor：**明确指定 Team Cross 窗口；另一个项目窗口未用于替代。该窗口在 CoreGraphics 标记为不在屏幕上时仍成功取得截图与 OCR，但旧构建两次未匹配到 AX 窗口。用户最初提供的 Cursor 样本证明该应用可以暴露丰富内容，但不能据此把此次失败标成成功，也不能将失败直接归因于 Electron 辅助功能未启用。新增诊断用于区分空窗口列表、窗口元数据超时、权限与辅助功能暴露问题。

## 失败与限制的处理

- 音乐第一次完整捕获 `music-full-001` 的截图与 OCR 成功、AX 窗口匹配失败；随后新建 `music-full-002` 成功。旧快照保留，没有原地修写为成功。新版对空枚举／临时读取失败仅在原预算内重试一次。
- 音乐成功快照仍有 27 个 `AXError.failure`：`AXGrowArea` 1、`AXMakeScreenRectVisible` 2、`AXValueDescription` 1、`AXIdentifier` 7、`AXScrollToVisible` 16。它们使状态保持 `partial_read_errors`，不能等同于所有正文丢失。
- OpenSurge 成功快照实际读取错误包括 `AXGrowArea`；旧版还将 text-marker 不透明句柄报告为未知类型。新版将已知进程内句柄单独标为 `nonserializable`，只保留其存在性，真正的读取失败仍保留。不能把诊断数量减少解释为多读到了内容。
- 两个成功 AX 快照没有触发节点、深度、总时限或文本预算截断。这仍不证明应用暴露了完整文档。
- OpenSurge 原始 AX JSON 约 8.8 MB，包含重叠的父子富文本及属性。字数与节点数只作检查线索；后续可在不修改原始证据的前提下提供更紧凑的导出视图。

## 启动与授权实测

直接从终端运行 bundle 内二进制与通过 LaunchServices 正常启动 App，在本机观察到不同的授权结果。`scripts/run-probe.sh` 采用后者，并通过 CLI 的原子完成回执获得实际退出码；已验证正常 `doctor` 返回 0、无效命令返回 1。`open -W` 对短命进程曾返回 GetProcessPID 错误，不能用该返回值推断 CLI 结果。

开发版使用 ad-hoc 签名。第一次授权允许原构建取得上述快照；重新构建后，系统设置开关仍可显示开启，但 TCC 日志明确报出 `Failed to match existing code requirement`，旧、新 cdhash 不同。普通切换开关及退出授权进程未修复。随后使用系统 `tccutil` 仅重置 `dev.oneshot.capture-probe` 的 Accessibility / ScreenCapture 记录，重新触发系统请求；不修改 TCC 数据库、不复用 Codex 的权限身份。最终固定构建 cdhash 为 `c462a9cf15913f777866aa0c301478db6b2c9db9`，后续真实采集使用这一构建，不为文档更新重新签名。

## 工程验证与后续门槛

提交 `0fb294c` 的原型通过 14 项 Swift Testing 检查、构建与代码签名校验。覆盖类型保真、Unicode／富文本范围、显式截断预算、不可覆盖快照、目录边界、窗口选择、完成回执及 AX 诊断。构建输出中的 SwiftPM 用户缓存不可写提示不影响本轮编译与测试成功。

后续审阅补齐了多窗口元数据不完整的歧义处理：其他候选若无法由可靠字段明确排除，就不选择看似唯一的窗口。新增 3 项测试，总计 **17 项通过**；最终固定构建与签名校验通过。离线读取与原 `context.txt` 一致，三份快照的 SHA-256 均未变化。

## 固定构建复验结果

重置失效记录并由用户批准后，`doctor` 已确认 Accessibility 与 Screen Recording 均为 `granted`。本段全部使用上文的固定 cdhash，没有再重建 App。

| 应用 | 本地快照 | UTC 时间 | AX 节点 | 最长富文本 | OCR 文本块 |
| --- | --- | --- | --- | --- | --- |
| 音乐 | `music-full-003` | 05:25:05–05:25:06 | 119 | 15 份参数化富文本；主要信息来自普通属性 | 34 |
| OpenSurge | `opensurge-full-004` | 05:30:38–05:30:41 | 469 | 11,384 字符 | 124 |
| Cursor | `cursor-full-004` | 05:28:23–05:28:31 | 1,864 | 28,670 字符 | 169 |

三份均取得截图、AX 和 OCR，窗口身份前后稳定；AX 状态仍准确标为 `partial_read_errors`。音乐保留原来的 27 个属性失败；后两者真正的属性读取错误均为 `AXGrowArea` 一项。OpenSurge 的 1,378 个、Cursor 的 5,553 个已知 text-marker 句柄被明确记为 `nonserializable`；这只是消除误分类，不是新增内容。

Cursor 成功快照保留文件 URL、workbench URL、文件树、编辑器、标签及聊天区域；焦点引用 `n1379`。两个文本区域的 `AXSelectedTextRange` 均为长度 0，因此本次没有证明非空文字选区。最长富文本属于整个 WebArea，并非编辑器文件全文。

**前置条件和稳定性仍有限制。** Cursor 的正常 CUA 参考读取发生在成功快照之前；OpenSurge 的后续复验也在 CUA 参考读取之后恢复。没有执行 CUA 的 Raise、点击或滚动动作，但不能排除正常参考读取影响应用 AX 初始化或可见性。成功快照时两者 `isOnScreen=true`。之前的空窗口数组、模式切换、后台状态未做严格单变量对照，不能宣称已实现完全独立且稳定的首次唤起。

`cursor-full-003` 在读图与 AX 之间遇到文档标题变化：程序保留截图，但拒绝将新标题窗口的 AX 合并，并记录 `window_changed_or_disappeared`。随后新建的 `cursor-full-004` 成功。OpenSurge 的 `full-002/003` 曾返回空 AX 窗口列表；失败快照均保留，没有用成功样本覆盖它们。

### 编辑器暴露范围与真实文件的差距

在 Cursor 成功快照中，编辑器节点 `n744` 的 `AXValue` 与 `AXAttributedStringForRange` 均为 **6,268 字符**，`AXNumberOfCharacters` 也报告 6,268。OneShot 的截断标记为 false。

随后只为验证而读取这一明确文档的已保存文件：29,692 字符；AX 文本恰好等于它开头的 6,268 字符。外部文件没有回填到捕获里，也没有作为应用 AX 结果保存。此对照表明，“完成应用声明的读取范围”不能当成“取得保存文件全文”，而整个 WebArea 的 28,670 字符也包含其他区域，不能用来代替文件覆盖率。离线检查记录在本机 `LocalEvidence/cursor-editor-comparison.json`。

### Electron 适配的取证边界

`cursor-full-002/accessibility-preparation.json` 记录了显式调用：`AXManualAccessibility=true` 返回成功，但即时读回 false，捕获也没有取得 AX 窗口；因此结果保留为 `write_succeeded_unconfirmed`。不能从这次单独调用声称修复成功。

本机 Electron Framework 版本为 42.11.16；[同版本上游实现](https://github.com/electron/electron/blob/v42.11.16/shell/browser/mac/electron_application.mm#L218) 对该 setter 有约 2 秒 debounce，getter 比较当前完整 AX mode，而非回显最后写入值。仅凭立即 false 无法判定设置失败。同步诊断也曾返回空窗口，因此当前证据不支持将问题归因于 Swift async 执行线程。后续需要固定窗口／Space、记录启用后的延迟读取，并做同一进程的受控对照。

## 下一阶段采集门槛

1. 独立处理 AX 首次暴露与后台窗口状态：固定 PID、窗口、Space 和文档，消除先运行 CUA 参考读取这一条件，并记录明确的可读／不可读原因。
2. 区分系统采集预算与应用自身的文本范围。重点研究编辑器能否通过公开范围／文本标记取得更完整正文；若引入明确文件引用适配，必须作为独立来源，不能伪装成 AX。
3. 在同一轮窗口状态下对照原生 AppShot 与 OneShot，补测非空文字选区、长文档边界和各区域覆盖；保持原图与原始结构不变，为重复富文本提供紧凑的派生导出。

原生截图交互、标注、评论和 MCP 交付仍在采集核心验证之后推进。
