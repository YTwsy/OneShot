# OneShot

独立的应用截图与上下文分享工具。macOS 采集核心以用户提供的三份 Codex 原生 AppShot 为信息覆盖参考；当前支持全局快捷键采集前台应用窗口，完成后进入原生标注编辑器，添加图形标注和绑定冻结 AX 节点的控件说明。通用 MCP 交付继续后置。

状态：独立 Swift 采集原型和原生标注编辑器已构建，40 项 Swift 测试通过。更新日期：2026-10-26。真实按键已验证快捷键采集并自动打开编辑器；本次触发至采集回执约 7 秒，用户反馈打开较慢，尚未完成性能优化。编辑器已实测图形编辑、AX 控件点选／树选择、中文说明、撤销／重做、保存重开及原始分辨率 PNG 导出。音乐、OpenSurge、Cursor 均已完成一轮前台可见窗口的截图／AX／OCR 采集，并与用户提供的历史 Codex AppShot 核对主要语义锚点；同一轮原生 AppShot 对照尚待补齐，部分读取和序列化限制仍保留。后台窗口支持与编辑器全文扩展后置。原型以 macOS 14+、Swift 6 工具链构建；这不是最终产品的平台承诺。

## 当前阶段

- [快捷键采集](docs/shortcut-capture.md)：按 ⌃⌥⌘S 固定当前前台应用的窗口，委托已授权 Probe 采集，完成后打开标注界面。
- [标注编辑器](docs/annotation-editor.md)：打开已有采集，在截图或控件树上选择对象并添加说明；保存可继续编辑的项目、导出标注图片。
- [采集完整度基准](docs/capture-baseline.md)：三份样本实际证明的信息范围、未验证能力与逐项验收方法。
- [Codex Desktop AppShot 调查](docs/codex-appshot-investigation.md)：本机原生服务、富文本提取线索、公开与内部接口的复用边界。
- [原生采集实测](docs/capture-validation-2026-10-25.md)：音乐、OpenSurge、Cursor 的实际产物、覆盖情况与尚未通过的门槛。
- [前台场景对照](docs/foreground-comparison-2026-10-25.md)：以可见目标窗口为前提，对照截图、文本、角色、状态和焦点；动态内容与采样时间差单独记录。
- 独立实现 CoreGraphics 窗口定位、ScreenCaptureKit 截图、AX 结构与参数化富文本读取、可选 Vision 中文／英文 OCR。
- 不按视口或元素尺寸剪裁语义遍历；保留来源、类型、选择／焦点、预算、读取失败和截断诊断。
- 每次捕获保存到新的本地目录。读取已有捕获不重新访问应用；AX 失败也可独立保留成功取得的截图。

## 标注与编辑

```sh
zsh scripts/build-editor.sh
open '.build/OneShot Editor.app'
```

编辑器使用独立 bundle `dev.oneshot.editor`，编辑时只读取已保存的快照，快捷键采集则委托已授权的 Probe。构建脚本仅更新 `.build/OneShot Editor.app`，不替换已授权的 Probe；辅助功能和屏幕录制仍由 Probe 的权限身份承担。

保持编辑器运行，切到要采集的应用，按 **Control + Option + Command + S（⌃⌥⌘S）**。程序选择该应用最前面的可见普通窗口，采集截图、AX 和 OCR 后自动打开；多个窗口时不会抓取整个应用的全部窗口。关闭编辑窗口仍保留菜单栏入口和快捷键，⌘Q 完全退出。也可使用“3 秒后采集”给自己留出切换窗口的时间。

打开含 `manifest.json` 的采集文件夹后，可使用编号、箭头、方框、文字工具；“控件”工具通过截图上的位置选中 AX 节点，“控件树”可搜索并选择屏幕外或重叠对象，再添加节点说明。截图坐标以原始像素保存，缩放不改变标注位置。控件说明绑定当前捕获 ID 和节点 ID，不操作原应用。

保存为 `.oneshot` 项目，包含完整原始采集副本和独立 `annotations.json`，可移动后重开；导出 PNG 生成图形与可见控件编号的合成图片。控件说明正文和原始上下文保留在项目中，PNG 不代替可编辑项目。首次保存选择新的项目名，导出选择新的 PNG 文件名。`Edits/` 可存放个人项目，默认不纳入 Git。

## 构建与采集

```sh
swift build --disable-sandbox
zsh scripts/test.sh
zsh scripts/build-probe.sh
```

本机开发版位于 `.build/OneShot Probe.app`，仅做 ad-hoc 签名，未公证。辅助功能授权与屏幕录制授权属于实际执行的应用身份；Codex 自身已获授权不代表 OneShot 已获授权。使用启动脚本经 LaunchServices 正常打开 App：直接在终端执行 bundle 内二进制可能归属不同的权限身份。

```sh
zsh scripts/run-probe.sh doctor
zsh scripts/run-probe.sh authorize
```

`authorize` 是唯一主动显示 macOS 系统授权入口的命令，需要用户在系统设置中批准。开发版的 ad-hoc 签名与构建内容有关，重新构建后应再次检查授权，系统可能要求重新批准。启动脚本保留调用者工作目录，通过 CLI 原子写出的完成回执取得真实退出码；不把 `open` 的返回值当成采集结果。超时只停止等待，保留私有日志目录，不杀死进程或自动重采。

本机实测发现，旧 ad-hoc 构建的系统开关即使仍显示开启，签名要求也可能不再匹配新版；仅切换开关不一定修复。遇到此情况应先确认 `doctor` 与系统 TCC 日志，再由用户重新添加当前 App 或仅重置该 bundle 的失效授权后重新批准。不要反复重建已获授权的实验构建。已有有效开发签名身份时，可显式指定 `ONESHOT_SIGN_IDENTITY` 运行构建脚本；脚本不会创建证书或修改系统授权，默认仍为 ad-hoc。

```sh
zsh scripts/run-probe.sh windows --app com.apple.Music
zsh scripts/run-probe.sh capture --app com.apple.Music --output Captures/music-001 --ocr
zsh scripts/run-probe.sh read --capture Captures/music-001
python3 scripts/summarize_capture.py Captures/music-001
```

多个窗口时必须显式指定 `--window-id`。输出目录必须不存在，程序拒绝覆盖。`--no-image` 可单独实验 AX；`--timeout`、`--max-nodes`、`--max-depth`、`--max-text-characters` 控制采集预算。截图与 AX 分别记录时间，窗口身份检查不能证明内容原子一致。`Ref/` 原始参考图与 `Captures/`、`LocalEvidence/` 实际捕获留在本机，Git 不收录这些数据。

`diagnose --app … --window-id …` 只读检查 AX 窗口候选、读取错误和应用声明的辅助功能开关，不读取候选窗口正文。被动读取不会更改焦点、滚动位置或应用设置。对于 Electron 应用，可显式使用 `capture … --enable-electron-ax` 请求其运行中进程暴露 AX 树：只使用 [Electron 官方记录的 AXManualAccessibility 接口](https://www.electronjs.org/docs/latest/tutorial/accessibility)，结果另存 `accessibility-preparation.json`。这一选项可能触发目标应用的辅助功能界面，不是系统权限替代，也不保证它会暴露完整文档；不会自动关闭共享的辅助功能状态。

已授权构建的窗口匹配可单独做有界复测，不需要重新构建：

```sh
python3 scripts/probe_ax_stability.py --app com.apple.Music --window-id 172 \
  --rounds 3 --output LocalEvidence/music-stability-NEW
```

窗口 ID 须先用 `windows` 查询。脚本每轮保存窗口元数据、前后 AX 诊断及最多一个根节点；最多 10 轮，超时或完成状态不明即停止。它不改变应用焦点或辅助功能开关，只验证窗口匹配，不能证明整棵树或全文完整。当前源码还新增隐藏／前台状态、焦点／主窗口的元数据诊断与结构化失败原因；这些新增字段通过单元测试，尚未装入已授权的固定 App 做实机验证。

前台验收使用下面的门槛脚本，目标应用必须已经置前：

```sh
python3 scripts/capture_frontmost.py --app com.apple.Music --window-id 172 \
  --output LocalEvidence/music-foreground-NEW
```

脚本只读核对前台应用身份、目标窗口 PID 与可见性，执行一次截图／AX／OCR，随后记录前台状态与固定构建摘要。条件不满足时保留诊断并拒绝采集；不会自行切换窗口、授权、滚动或更改编辑器模式。每个阶段是独立观测，不保证内容原子一致。`capture` 内各组件状态须分别检查，前台检查通过不等于采集完整。

## 当前推进边界

当前流程为用户或后续程序将目标窗口打开并带到前台，再采集该窗口。先验证此前提下的截图、应用暴露的 AX 文本与控件状态；后台窗口读不到 AX 作为使用前提不足记录，不再列为本阶段的主要缺陷。匹配不确定、读取超时与窗口变化仍需明确记录，不能为了取得结果改选另一窗口。

“编辑器文本范围”是另一层问题。即使取得完整 AX 树，编辑器也可能只对辅助功能接口提供文件的一部分。实测一次 Cursor 提供了 6,268 字符，而明确对应的保存文件有 29,692 字符；这次差距通过额外离线对照确认，不能仅由 AX 自行推断。目前记录应用报告的长度、实际返回范围及 OneShot 自身的截断／错误；没有全文对照时，全文覆盖状态保持未知。自动读取磁盘文件、翻页或滚动以拼接正文暂不纳入当前工作。

## 核心需求

- **原生应用体验**：支持窗口／选区截图、预览与编辑，交互参考 Pinpoint。
- **标注体验**：支持编号标记、箭头、方框和文字说明，标注后可以交给 Agent 使用。
- **丰富的界面上下文**：并以接近 Codex 原生 Appshots 的信息完整度为采集目标。除截图外，尽可能取得应用暴露的完整界面文本、AX 层级、控件角色和值、焦点／选择／展开状态，以及窗口标题和 URL。
- **上下文独立于标注**：没有放置标记时，也能保存和导出整次捕获的上下文；不只返回标记命中的元素。
- **通用 MCP 接口**：其他 Agent 可以请求捕获、读取用户已经捕获或标注的内容；不绑定特定 Agent，MCP 之外仍可独立使用 App。
- **捕获一致性**：截图与上下文对应同一窗口及同一次捕获；原始快照和标注层分开保存，后续编辑不重新读取已经变化的界面。

“完整”指尽可能保留应用实际暴露的信息，不承诺取得所有应用的完整文档。应用未暴露、读取失败、采集截断等情况需要明确说明；AX、OCR 和其他适配来源应可区分。

## 优先验证

先验证采集能力，再决定完整产品的实现投入。以已有的三份 Codex 原生 Appshots 为参考，后续需要在相同窗口状态下做实际对照：

| 应用 | 重点 |
| --- | --- |
| 音乐 | 专辑／音轨、侧栏层级、控件角色与数值类型、选择／展开、音量、焦点；搜索词与播放进度另行补测 |
| OpenSurge | 内嵌 WebView 的节点、延迟、协议、检测时间、策略状态及已暴露的视口外文本 |
| Cursor | 文件与工作台 URL、编辑器长文本、多区域层级、控件选择与焦点；精确文本选区、AX 失败与中文 OCR 另行补测 |

## 实现与复用方向（待验证）

- 独立建立采集核心，以实际信息覆盖决定方案；开源 Appshots／Peekaboo 是潜在实现参考，不预设为底座。Pinpoint／Remarc 的交互、标注与评论在后续阶段评估。
- GUI 与 MCP 共享捕获核心和快照存储，保留完整结果，按需向 Agent 返回。
- 根据实测补充 WebView、浏览器、编辑器适配及中文 OCR；浏览器扩展不能直接覆盖任意 App 的内嵌 WebView。
- 本机调查未找到面向独立应用的公开 Codex AppShot SDK／CLI；其内置服务依赖宿主认证与运行时。参考原生样本与提取思路，不复制专有实现或调用内部认证通道。
- 最低 macOS 版本、具体技术栈、开源与分发方式尚未确定。

## 参考

- [Pinpoint](https://github.com/croustibat/Pinpoint)：交互、标注与现有 MCP 流程。
- [开源 Appshots](https://github.com/Shahfarzane/appshots)：独立的截图、AX、存储和 MCP 实现，非 OpenAI 项目。
- [Remarc](https://github.com/metedata/Remarc)：优先评估的现成标注与 Agent 协作应用。
- [Peekaboo](https://github.com/openclaw/Peekaboo)：采集与 Accessibility 实现参考。
- [原生 Appshots 文档](https://learn.chatgpt.com/docs/appshots)：能力与限制参考。
