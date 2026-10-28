# OneShot

把应用截图、控件说明和界面上下文一起交给 Agent。

OneShot 是面向 macOS 的本地采集与标注工具。按快捷键固定当前应用窗口，在截图上点选控件并写下意见，再将截图、标注、冻结 AX 节点和完整上下文交给 Agent。一次配置本地 MCP 后，每次交付只需粘贴材料编号；也可导出本地文件。

首发支持 **macOS 14+、Apple Silicon（arm64）**。当前为 **Pre-release**，已有 build 4 安装包使用 ad-hoc 签名，**没有 Developer ID 签名、未经 Apple 公证**。源码已支持[固定证书与 GitHub Actions 构建](docs/releasing.md)，需要配置签名身份并完成实机升级验收。当前采用手动下载替换更新，自动更新后续加入。

## 安装与权限

下载发布的 DMG，将 `OneShot.app` 拖到 Applications，再从 Applications 打开。一个 App 内包含采集组件与 MCP，不需要另行安装 Probe 或 Swift 工具链。

此测试版未经公证，macOS 可能阻止首次打开。请先确认下载来源和 SHA-256，再按系统提示决定是否允许；不要为了运行应用关闭整机安全检查。参见 [Apple 的应用打开说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)。

发布版首次启动展示[权限引导](docs/permissions.md)，分别说明并请求屏幕录制和辅助功能。检查状态不会自动申请权限；点击每项的“开启”按钮才发起对应请求，最终批准仍由用户完成。新版应用和内置采集组件的显示名称统一为 OneShot；系统可能保留旧版 OneShot Capture 条目，请按引导中的当前组件路径核对。返回应用后会重新检查；也可稍后设置，先编辑已有项目。从旧 ad-hoc 安装包迁移到证书签名版本时，可能需要首次重新授权。

发布包不包含个人采集、日志、标注项目或参考样本。正式发布流程见[构建与发布](docs/releasing.md)。

## 一轮使用

1. 保持 OneShot 运行，切到目标应用，按 **Control + Option + Command + S（⌃⌥⌘S）**。也可使用“3 秒后采集”留出切换窗口的时间。
2. 等待采集完成，编辑器会打开截图。截图、AX 和 OCR 的读取状态分别保留；失败不会被解释为完整采集。
3. 点击“写反馈”，在固定右栏描述想修改的地方。点击“引用控件”后在截图中点选，或输入 `@` 搜索控件；同一段描述可以引用多个对象，例如“[保存按钮] 能改成 [发布按钮] 的样式吗？”。引用使用 `R1`、`R2` 编号，与截图双向定位。
4. 编号、箭头、方框、文字和原有控件标注继续使用；在“标注”页签编辑样式与说明，控件树可选择重叠或截图外的对象。反馈引用与控件标注均绑定到本次冻结快照，不操作原应用。
5. 首次在 **OneShot → Agent 连接与材料** 中复制 MCP 配置并添加到 Agent。点击 **“交给 Agent”** 自动创建固定版本，材料引用复制到剪贴板，直接粘贴给 Agent。无需选择目录或逐次更改配置。
6. 保存 `.oneshot` 项目后可以继续编辑。最近采集保留最近 30 份快照或项目，重开应用后可找回。

没有反馈或标注时也能交付整次采集。当前未保存的描述、引用和标注会进入导出快照；导出不代替保存项目。后续修改后再次交付会生成新版本，旧引用仍指向旧内容。

## 交付内容与只读 MCP

默认交付存放在应用管理的本地材料库中。引用形如 `OS-0123456789AB@1`，绑定明确版本。只有用户点击“交给 Agent”的内容进入材料库；未交付的采集和草稿不会自动暴露。

在 **OneShot → Agent 连接与材料** 中可复制 Codex TOML 或通用 JSON 配置、检查本地服务、查看交付历史及撤销后续读取。Codex 配置示例（合并到现有 `config.toml`，保存后重启 MCP 连接）：

```toml
[mcp_servers.oneshot]
command = "/Applications/OneShot.app/Contents/Helpers/oneshot-mcp"
args = ["--library"]
```

Agent 从 `read_handoff(reference)` 开始，一次获得用户反馈、有序控件引用、相关 AX 控件摘要、标注图片、采集状态和继续读取入口。`read_details` 展开完整节点、反馈、AX/OCR 与诊断；`read_image` 可读取原图或按原图像素指定局部。新增材料无需重连，关闭编辑器后已有材料仍可读取。服务只读，不采集、点击、写入或访问网络。

材料保留完整原始上下文，分享前请检查内容。撤销保留本地文件并阻止后续 MCP 读取，无法收回 Agent 已读取的内容。材料引用是定位信息，不是针对不同客户端的独立权限令牌；使用同一本地材料库的 Agent 可按引用读取尚未撤销的材料。

没有 MCP 的 Agent 仍可通过 **文件 → 导出 Agent 文件夹** 获取兼容材料：

```text
example-agent/
  AGENT.md                 用户反馈、标注重点与材料入口
  handoff.json             结构化反馈、标注和冻结 AX 节点
  annotated.png            原始像素尺寸的标注图
  source.oneshot/          可继续编辑的项目与完整原始采集
```

旧 `oneshot-mcp --handoff /absolute/path/to/example-agent` 模式继续保留。OneShot 不自动修改 Agent 配置，不会自行上传材料；Agent 读取之后如何使用内容由该客户端决定。详见[交付与 MCP](docs/agent-handoff.md)。

## 能力边界

- 当前采集目标为前台应用最靠前的可见普通窗口，不是整个屏幕或整个应用的所有窗口。窗口／选区自由选择、裁切和模糊遮挡尚未实现。
- 截图、AX 和 OCR 是不同时间的独立读取。窗口身份稳定不代表内容原子一致。
- 只保留应用实际暴露的信息；不承诺所有应用的完整文档。AX 失败、预算限制与序列化截断明确记录，OCR 不当作控件状态。
- 采集不自动滚动、点击或切换目标应用的辅助功能模式。CLI 的 Electron AX 启用是单独的显式选项。
- 关闭编辑窗口后菜单栏与快捷键继续运行，⌘Q 完全退出。采集忙碌时不重复启动；超时不终止组件或自动重试，完成结果可以恢复。
- 证书签名版本的升级权限保持、真实快捷键连续性、HUD 焦点和各应用兼容性仍需持续实机验证。开发测试通过不等于所有机器的安装／授权验收通过。

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

OneShot 使用 [MIT License](LICENSE)

实现独立使用 macOS 的 CoreGraphics、ScreenCaptureKit、Accessibility 与 Vision。交互和能力参考包括 [Pinpoint](https://github.com/croustibat/Pinpoint)、[开源 Appshots](https://github.com/Shahfarzane/appshots)、[Remarc](https://github.com/metedata/Remarc) 和 [Peekaboo](https://github.com/openclaw/Peekaboo)。这些链接不表示代码或资源被打包进 OneShot。OneShot 不包含或调用 Codex 的专有 AppShot 服务。
