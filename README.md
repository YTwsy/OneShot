# OneShot

把应用截图、控件说明和界面上下文一起交给 Agent。

OneShot 是面向 macOS 的本地采集与标注工具。按快捷键固定当前应用窗口，在截图上点选控件并写下意见，再导出一份包含截图、标注、冻结 AX 节点和完整上下文的材料。Agent 可以直接读取本地文件，也可以通过只读 MCP 按需读取。

首发支持 **macOS 14+、Apple Silicon（arm64）**。当前为 **Pre-release**：使用 ad-hoc 签名，**没有 Developer ID 签名、未经 Apple 公证**。当前版本采用手动下载替换更新，自动更新后续加入。

## 安装与权限

下载发布的 DMG，将 `OneShot.app` 拖到 Applications，再从 Applications 打开。一个 App 内包含采集组件与 MCP，不需要另行安装 Probe 或 Swift 工具链。

此测试版未经公证，macOS 可能阻止首次打开。请先确认下载来源和 SHA-256，再按系统提示决定是否允许；不要为了运行应用关闭整机安全检查。参见 [Apple 的应用打开说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)。

采集需要屏幕录制和辅助功能权限。在“采集设置”中检查权限，并通过明确的授权入口打开 macOS 提示；最终批准仍由用户在系统设置中完成。权限属于实际采集的 **OneShot Capture** 组件，签名与公证不能代替这些权限。由于当前使用 ad-hoc 签名，升级后可能需要重新确认组件授权。

发布包不包含个人采集、日志、标注项目或参考样本。正式发布流程见[构建与发布](docs/releasing.md)。

## 一轮使用

1. 保持 OneShot 运行，切到目标应用，按 **Control + Option + Command + S（⌃⌥⌘S）**。也可使用“3 秒后采集”留出切换窗口的时间。
2. 等待采集完成，编辑器会打开截图。截图、AX 和 OCR 的读取状态分别保留；失败不会被解释为完整采集。
3. 用编号、箭头、方框或文字标注重点。“控件”工具可直接点选截图上的 AX 元素，控件树可选择重叠或截图外的对象。
4. 在右侧填写说明，例如“这里的提示不清楚”。控件标注绑定到本次冻结快照中的节点，不操作原应用。
5. 点击 **“交给 Agent”**，选择新的导出文件夹。读取说明会复制到剪贴板，可粘贴给能读取本机文件的 Agent。
6. 保存 `.oneshot` 项目后可以继续编辑。最近采集保留最近 30 份快照或项目，重开应用后可找回。

没有标注时也能交付整次采集。当前未保存的标注会进入导出快照；导出不代替保存项目。后续修改后需要重新导出。

## 交付内容与只读 MCP

```text
example-agent/
  AGENT.md                 用户标注重点、采集身份和完整材料入口
  handoff.json             结构化标注和完整目标 AX 节点
  annotated.png            原始像素尺寸的标注图
  source.oneshot/          可继续编辑的项目与完整原始采集
```

完整上下文不因标注范围而裁剪，包含截图、AX、OCR、组件错误与截断诊断。分享材料前请检查整次采集的内容。OneShot 本身不上传材料；粘贴给其他 Agent 或分享文件夹是单独的用户操作。

安装后，MCP 可执行文件位于：

```text
/Applications/OneShot.app/Contents/Helpers/oneshot-mcp
```

以支持 stdio 的 Agent 为例：

```json
{
  "mcpServers": {
    "oneshot-material": {
      "command": "/Applications/OneShot.app/Contents/Helpers/oneshot-mcp",
      "args": ["--handoff", "/absolute/path/to/example-agent"]
    }
  }
}
```

每个 MCP 进程只读取启动参数明确选定的一份材料，提供摘要、标注索引、单条标注、完整上下文分页和图片。它没有采集、点击、写入或网络接口。安装 App 不会自动修改 Agent 配置。详见[交付与 MCP](docs/agent-handoff.md)。

## 能力边界

- 当前采集目标为前台应用最靠前的可见普通窗口，不是整个屏幕或整个应用的所有窗口。窗口／选区自由选择、裁切和模糊遮挡尚未实现。
- 截图、AX 和 OCR 是不同时间的独立读取。窗口身份稳定不代表内容原子一致。
- 只保留应用实际暴露的信息；不承诺所有应用的完整文档。AX 失败、预算限制与序列化截断明确记录，OCR 不当作控件状态。
- 采集不自动滚动、点击或切换目标应用的辅助功能模式。CLI 的 Electron AX 启用是单独的显式选项。
- 关闭编辑窗口后菜单栏与快捷键继续运行，⌘Q 完全退出。采集忙碌时不重复启动；超时不终止组件或自动重试，完成结果可以恢复。
- ad-hoc 签名身份稳定性、真实快捷键连续性、HUD 焦点和各应用兼容性仍需持续实机验证。开发测试通过不等于所有机器的安装／授权验收通过。

## 从源码开发

需要 macOS 14+ 和 Swift 6 工具链。项目使用 SwiftPM，没有第三方 Swift 包依赖。

```sh
zsh scripts/test.sh
zsh scripts/build-probe.sh
zsh scripts/build-editor.sh
open '.build/OneShot Editor.app'
```

开发版 Editor 和 Probe 使用独立开发身份，仍可分开构建。`build-editor.sh` 不替换已授权的开发 Probe；重建 Probe 后应重新检查系统授权。

```sh
zsh scripts/run-probe.sh doctor
zsh scripts/run-probe.sh authorize
zsh scripts/run-probe.sh capture --app com.apple.Music --output Captures/example --ocr
```

多个窗口时需先用 `windows --app …` 查询，再显式指定 `--window-id`。`authorize` 是主动请求系统权限的入口；`capture` 和 `doctor` 不自动显示授权提示。读取已有捕获不重新访问原应用。

从干净提交构建可分发包：

```sh
zsh scripts/build-release.sh --version 0.1.0-alpha.1 --build-number 1 --ref HEAD
```

脚本生成单个 App、DMG、校验和、源码归档和版本／提交清单。产物保存到 Git 忽略的 `artifacts/`，不会覆盖已有产物，也不会上传或发布。发布步骤、验收边界和组件身份见[构建与发布](docs/releasing.md)。

## 开发记录

- [快捷键采集与计时](docs/shortcut-capture.md)
- [原生标注编辑器](docs/annotation-editor.md)
- [采集完整度基准](docs/capture-baseline.md)
- [原生采集实测](docs/capture-validation-2026-10-25.md)
- [前台场景对照](docs/foreground-comparison-2026-10-25.md)
- [历史 AppShot 调查与实现边界](docs/codex-appshot-investigation.md)

历史报告描述对应日期、版本与样本的观察，不是当前机器或未来版本的保证。原始参考图、实际捕获及本地验收证据留在本机，不纳入 Git。

## 许可证与参考

OneShot 使用 [MIT License](LICENSE)，版权所有 2026 YTwsy。

实现独立使用 macOS 的 CoreGraphics、ScreenCaptureKit、Accessibility 与 Vision。交互和能力参考包括 [Pinpoint](https://github.com/croustibat/Pinpoint)、[开源 Appshots](https://github.com/Shahfarzane/appshots)、[Remarc](https://github.com/metedata/Remarc) 和 [Peekaboo](https://github.com/openclaw/Peekaboo)。这些链接不表示代码或资源被打包进 OneShot。OneShot 不包含或调用 Codex 的专有 AppShot 服务。
