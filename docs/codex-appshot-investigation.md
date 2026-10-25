# Codex Desktop AppShot：本机实现与复用边界

调查日期：2026-10-25。范围为官方文档、当前安装包中的静态代码、元数据、原生二进制符号和字符串。没有调用内部捕获入口，没有修改宿主、权限或设置，也没有读取账号、凭据或聊天历史。下文不是原生服务的完整源码审计。

## 结论

当前安装的 Codex Desktop 将 macOS AppShot 交给独立的原生 **Codex Computer Use** 服务；Electron 宿主负责触发、权限流程、异步结果接收和附件组装。原生服务具备 AX 文本、富文本转换和截图相关实现。

可以继续把用户通过正常 AppShot 入口取得的结果作为对照基准。没有找到官方公开、允许独立应用直接接入的 AppShot SDK 或 CLI 捕获命令。安装包中的 JS 窗口 API、Apple Event 协议及原生服务属于宿主集成机制，存在可信运行时与调用方认证边界，不能因为入口可读就将其当成 OneShot 的独立产品依赖。

OneShot 应优先独立实现采集核心，借鉴观察到的能力分层；后续如有公开稳定接口，再单独评估接入。

## 官方可确认的边界

[官方 Appshots 文档](https://learn.chatgpt.com/docs/appshots)说明：

- 捕获最前方窗口的图像，以及窗口可提供的文本，可能包括视口之外的文本。
- 某些应用可能只有截图，不能由此推断取得完整文档。
- macOS 使用屏幕录制和辅助功能权限。
- CLI 可以继续包含 AppShot 的历史会话，但不能创建新的 AppShot。

此次检索未找到面向独立应用的公开 AppShot 捕获 API。这里的“未找到”只描述已检查的文档，并非对所有未来或未公开接口作断言。

## 本机版本与证据位置

本机主程序实际位于 `/Applications/ChatGPT.app`，Bundle ID 仍为 `com.openai.codex`。

| 项目 | 检查结果 |
| --- | --- |
| 主程序版本 | `26.1021.31345`，build `21828` |
| 内置 `@oai/sky` 包 | `0.7.13` |
| 原生服务 Bundle ID | `com.openai.sky.CUAService` |
| 原生服务版本 | `26.1021.1001631` |
| 服务签名 | OpenAI OpCo, LLC，Developer ID，启用 Hardened Runtime |
| 调查环境 | macOS 14.8.5，arm64 |

主要文件：

- `/Applications/ChatGPT.app/Contents/Info.plist`
- `/Applications/ChatGPT.app/Contents/Resources/app.asar`
- ASAR 内 `.vite/build/main-0FVbxCQU.js`
- ASAR 内 `.vite/build/worker.js`
- `/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/package.json`
- `/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService`
- 同包 `docs/sky-window-api.md`
- 同包 `dist/project/cua/sky_js/src/targets/mac/native-pipe.js`
- 同包 `dist/project/cua/sky_js/src/targets/mac/client.d.ts`
- 同包 `dist/project/cua/sky_js/src/targets/mac/errors.js`

ASAR 内 JS 为压缩构建产物，适合用符号和字符串定位，不宜引用不稳定行号。以上路径和下述符号只对该已安装版本成立。

## 能够由静态实现确认的流程

1. 主进程注册 AppShot 快捷键，按设置向当前会话、新会话或浮动窗口发送捕获动作。
2. 主进程的 `computer-use-capture-handler` 用独立 `requestId` 跟踪采集，处理权限等待、取消、超时和最终状态。
3. `worker.js` 中的 `computer-use-capture-native-bridge` 通过 Apple Event 向原生服务传递采集请求。静态代码能定位到 `ComputerUseIPCAppStartCaptureRequest` 和 `ComputerUseIPCAppNextCaptureUpdateRequest` 类型；这里只记录其存在，没有构造或发送这些请求。
4. 返回结果按 `metadata`、`screenshot`、`axText`、`completed` 或 `failed` 分阶段到达。截图与 AX 文本并非同一段字符串的副产品，而是独立结果。
5. 宿主将应用信息、窗口标题、图片引用与 `axTree` 组装成聊天中的 `<appshot>` 上下文。

这说明截图、语义提取、结果保存／交付可以解耦。它没有证明截图与整个 AX 遍历在同一时刻原子冻结，也没有证明所有失败都以用户可见的完整性诊断输出。

## 富文本与上下文采集的线索

原生服务的动态链接包含 ApplicationServices、ScreenCaptureKit、CoreGraphics、AppKit 与 WebKit。二进制中存在以下语义相关类型和属性名称：

- `AXAttributedStringMarkdownWriter`
- `AXTextMarkerRangeForUIElement`
- `AXAttributedStringForTextMarkerRange`
- `AXAttributedStringForTextMarkerRangeWithOptions`
- `AXStringForTextMarkerRange`
- `AXSelectedTextMarkerRange`、`AXSelectedTextRange`
- `AXNumberOfCharacters`
- `AXManualAccessibility`、`AXEnhancedUserInterface`
- `AXTruncationDescriptor`、`textTruncationDescriptor`、`truncationRange`
- `[truncated to visible range]`

**已证实的是这些实现符号／属性名称存在于服务中。** 可合理推测其能力覆盖 AX 富文本读取、转为 Markdown、文本标记范围、Electron 辅助功能适配和长文本限制处理；仅凭符号不能确定哪个 AppShot 对哪个应用使用哪条分支。

用户提供的 OpenSurge 输出以 HTML 节点的大段富文本 `Value` 呈现，与富文本转换路径相符；但尚不能确认具体使用的是普通 `AXValue`、参数化 text-marker 属性，还是二者组合。应通过独立采集实验核实，而非预先复制某条路径。

用户提供的 Cursor 正文在句中结束。本次静态调查发现了截断相关实现，但没有确定那份样本的截断阶段、默认字符上限或是否在宿主传输前已被截短，不能宣称已解释该现象。

## 为什么不能直接作为独立库调用

随包 `docs/sky-window-api.md` 描述了 `sky.get_app_state`，返回截图与 accessibility text；类型定义还提供 `disableDiff`。这是一个真实存在的包内接口，值得用于理解宿主能力，但它不等于公开的独立 SDK 承诺。

静态传输实现能够确认：

- `native-pipe.js` 依赖宿主注入的 `globalThis.nodeRepl` 与原生管道能力；缺少时明确报告需要 trusted nodeRepl runtime。
- 连接阶段检查客户端与服务的 API 版本一致性。
- 错误定义包含调用方未认证、应用不允许、权限未授予、没有活动会话、客户端版本不兼容等情况。
- 原生服务包含调用方签名身份相关字段；内置辅助客户端另带父进程签名要求资源。

因此，不能将包内模块路径、服务进程或内部请求名视为普通应用可自由调用的接口。此次没有尝试伪造运行时、替换签名、改写认证逻辑、复用权限身份或绕过应用授权。

当前会话提供的 `capture_screen_context` 工具限定在活动语音会话中，本轮文字任务未调用。正常 Computer Use 工具可以按其公开给当前会话的接口和授权规则用于对照，但这不自动证明它与快捷键 AppShot 使用完全相同的参数和文本格式。

| 复用方式 | 当前判断 |
| --- | --- |
| 用户正常捕获 AppShot，提供给 OneShot 对照 | 可用；本任务已有三份样本 |
| 当前会话正常 Computer Use 接口取得原生窗口状态 | 可作为后续辅助对照，需遵守该工具的能力与授权范围；未验证与 AppShot 完全等价 |
| 官方独立 AppShot CLI／SDK | 此次未找到；官方文档明确 CLI 不能新建 AppShot |
| OneShot 直接调用包内 JS／私有 Apple Event／服务管道 | 不作为已支持方案；受宿主、认证、权限和版本约束，未做运行试验 |
| 将专有服务／库复制到 OneShot 分发 | 未建立可重分发依据，不采用 |
| 独立使用 macOS 采集 API 实现同类能力 | 当前主路线 |

## 对 OneShot 原型的具体启发

1. 将原图、AX 结构、长文本和焦点作为独立可保存的数据；避免焦点正文重复让覆盖率虚高。
2. 普通 `AXValue` 不应仅按“短文本控件”白名单处理；取得 attributed string 时应显式保留文本和可表达的语义来源。
3. 枚举应用实际暴露的属性和参数化属性，再按支持情况读取；对 WebView 的 text-marker／富文本路径做单独的、有来源标记的实验。
4. 将 Chromium／Electron 的辅助功能启用与普通只读遍历分开记录，避免把适配动作和被动采集混为一谈。
5. 所有自身截断都要记录节点、属性、原因与已保存范围；不把“读取成功”直接等同“全文完整”。
6. 不采用参考实现中未经验证的可见行裁剪、几何尺寸过滤或小字符串上限。先以三个实际样本的语义覆盖决定策略，再控制资源预算。

报告只保存调查结论和定位信息，没有将宿主专有实现复制进 OneShot。
