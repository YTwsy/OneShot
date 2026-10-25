# OneShot

独立的应用截图与上下文分享工具。当前先验证 macOS 采集核心，以用户提供的三份 Codex 原生 AppShot 为信息覆盖参考。截图交互、标注编辑、评论和通用 MCP 交付在采集验证之后推进。

状态：已开始实现独立 Swift 采集原型。基准日期：2026-10-25。原型以 macOS 14+、Swift 6 工具链构建；这不是最终产品的平台承诺。

## 当前阶段

- [采集完整度基准](docs/capture-baseline.md)：三份样本实际证明的信息范围、未验证能力与逐项验收方法。
- [Codex Desktop AppShot 调查](docs/codex-appshot-investigation.md)：本机原生服务、富文本提取线索、公开与内部接口的复用边界。
- 独立实现 CoreGraphics 窗口定位、ScreenCaptureKit 截图、AX 结构与参数化富文本读取、可选 Vision 中文／英文 OCR。
- 不按视口或元素尺寸剪裁语义遍历；保留来源、类型、选择／焦点、预算、读取失败和截断诊断。
- 每次捕获保存到新的本地目录。读取已有捕获不重新访问应用；AX 失败也可独立保留成功取得的截图。

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

```sh
zsh scripts/run-probe.sh windows --app com.apple.Music
zsh scripts/run-probe.sh capture --app com.apple.Music --output Captures/music-001 --ocr
zsh scripts/run-probe.sh read --capture Captures/music-001
python3 scripts/summarize_capture.py Captures/music-001
```

多个窗口时必须显式指定 `--window-id`。输出目录必须不存在，程序拒绝覆盖。`--no-image` 可单独实验 AX；`--timeout`、`--max-nodes`、`--max-depth`、`--max-text-characters` 控制采集预算。截图与 AX 分别记录时间，窗口身份检查不能证明内容原子一致。`Ref/` 原始参考图与 `Captures/`、`LocalEvidence/` 实际捕获留在本机，Git 不收录这些数据。

`diagnose --app … --window-id …` 只读检查 AX 窗口候选、读取错误和应用声明的辅助功能开关，不读取候选窗口正文。被动读取不会更改焦点、滚动位置或应用设置。对于 Electron 应用，可显式使用 `capture … --enable-electron-ax` 请求其运行中进程暴露 AX 树：只使用 [Electron 官方记录的 AXManualAccessibility 接口](https://www.electronjs.org/docs/latest/tutorial/accessibility)，结果另存 `accessibility-preparation.json`。这一选项可能触发目标应用的辅助功能界面，不是系统权限替代，也不保证它会暴露完整文档；不会自动关闭共享的辅助功能状态。

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
