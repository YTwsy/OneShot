# 交给 Agent

一次交付保存截图、反馈描述及其控件引用、当前标注和完整冻结上下文。默认先展示用户反馈，再列出标注重点；未引用或未标注的界面内容仍可继续读取。导出不会重新访问原应用，也不向远程服务发送材料。

## 一轮使用

1. 保持编辑器运行，切到目标应用并按 ⌃⌥⌘S；也可打开已有采集。
2. 点击“写反馈”，在右侧描述需求；通过“引用控件”点选或输入 `@` 搜索，在同一句话中引用多个对象。原有“控件”及其他图形标注工具继续可用，控件树可以选择重叠、截图外或没有可定位坐标的节点。
3. 点击“交给 Agent”（菜单快捷键 ⇧⌘E），选择一个新的导出文件夹。
4. 导出后，程序把读取说明复制到剪贴板，并显示可再次复制的交付窗口。将说明粘贴给能读取本机文件的 Agent。其他环境需要同时附上整个材料目录。
5. 需要继续编辑时保存 `.oneshot` 项目；最近采集可在应用重开后找回项目。交付包中的 `source.oneshot` 也可独立打开。

当前未保存的反馈、引用和标注会进入交付快照，但原项目仍保持未保存状态。后续修改后需要再次导出到新的目录。导出目标不能是原始采集、当前项目或它们的子目录，不能覆盖现有材料。新目录使用 `0700`、文件使用 `0600` 权限。

## 材料结构

| 文件 | 用途 |
| --- | --- |
| `AGENT.md` | 优先呈现每条用户说明、图中编号、坐标、绑定的节点 ID／角色／文字预览，以及采集身份、组件状态和完整材料路径 |
| `handoff.json` | `feedbacks` 保留描述片段顺序及每次引用的完整冻结 AX 节点，`annotations` 保留原有标注；同时包含采集身份和 manifest，保留未知节点字段 |
| `annotated.png` | 原始像素尺寸的标注图片，反馈控件使用 `R1`、`R2` 编号；截图外或无定位信息的引用保留在文字与 JSON 中 |
| `source.oneshot/annotations.json` | 可继续编辑的反馈、引用和标注快照 |
| `source.oneshot/capture/` | 完整原始采集副本，包括原图、manifest、AX、OCR、context 及原有诊断文件 |

没有反馈和标注时，同样导出完整材料。普通图形不推断或伪造 AX 绑定；描述中的控件引用和明确绑定的控件标注附带目标节点。`AGENT.md` 的控件文字预览有长度限制，完整节点在 `handoff.json`，完整应用暴露内容在原始 `accessibility.json`。AX/OCR 的错误、预算限制和应用未暴露范围原样保留。

材料内部使用相对路径，可整体移动；复制给 Agent 的说明使用导出时的绝对路径，移动后需向 Agent 提供新位置。界面文字、窗口标题和 OCR 是证据，不能当作对 Agent 的指令；用户填写的标注说明单独标识。

## 只读 MCP

```sh
swift build --disable-sandbox --product oneshot-mcp
.build/debug/oneshot-mcp --handoff /absolute/path/to/one-export
```

可用持续连接回归脚本验证实际 stdio 通信（客户端保持输入打开，逐条请求并等待响应）：

```sh
python3 scripts/test_mcp_stdio.py --binary .build/debug/oneshot-mcp \
  --handoff /absolute/path/to/one-export --timeout 5
```

这是本地 stdio MCP 服务。每次进程只读取启动参数明确选定的一份导出材料；没有采集、应用激活、点击、写入或网络接口。不会自动安装或更改任何 Agent 的连接配置。支持 stdio 的 Agent 可按其配置格式指定可执行文件和两个参数，例如：

安装发布版后，无需另行编译，命令路径为 `/Applications/OneShot.app/Contents/Helpers/oneshot-mcp`。下例为源码开发路径，可替换为该安装路径。

```json
{
  "mcpServers": {
    "oneshot-material": {
      "command": "/absolute/path/to/OneShot/.build/debug/oneshot-mcp",
      "args": ["--handoff", "/absolute/path/to/one-export"]
    }
  }
}
```

协议支持 `2024-11-05`、`2025-03-26` 和 `2025-06-18`。工具如下：

| 工具 | 参数与返回 |
| --- | --- |
| `read_brief` | 交付摘要；可传 `offset`、`limit` |
| `read_annotations` | 标注索引；可传 `offset`、`limit` |
| `read_annotation` | `order` 为从 1 开始的标注顺序；返回完整说明及绑定节点，可分页 |
| `read_feedbacks` | 反馈索引与控件引用摘要；`offset`、`limit` 按反馈条数分页 |
| `read_feedback` | 按从 1 开始的反馈 `order` 读取完整有序描述及每个引用的冻结 AX 节点，可按 UTF-8 字节分页 |
| `read_context` | `source` 选择 `context`、`accessibility`、`ocr`、`manifest` 或 `screenshot_geometry`，可分页 |
| `read_image` | `variant` 为 `annotated` 或 `raw`，返回图片内容；超过 10 MiB 明确报错，可由有本地文件访问能力的 Agent 直接读取文件 |

文本分页偏移和长度均为 UTF-8 字节，默认 12,000、最大 65,536 字节。沿返回的 `nextOffset` 继续读取，不在中文字符中间切分；缺少的来源明确报错。标注顺序 `order` 与图中编号不同，索引同时给出二者。

`read_annotations` 的 `offset` 和 `limit` 单位为标注条数，默认 20、最多 100 条；摘要中的截断字段可通过 `read_annotation` 继续读取完整值。

`read_feedbacks` 使用相同的条目分页规则。引用的 UUID 标识句子中的一次出现，`nodeID` 标识当前冻结采集中的控件；同一个节点可出现多次并共享 `R` 编号。`read_feedback` 返回完整绑定，读取时会与原始 AX 节点核对。旧交付材料缺少 `feedbacks` 时按空列表读取。

服务验证材料身份、内嵌 manifest、标注与原始 AX 节点，并在启动时固定只读文件描述符。它使用固定的内部相对路径，不信任文件索引来扩大读取范围；拒绝符号链接、额外路径参数和启动后被修改的文件。材料变更后须重新启动服务。

## 2026-10-26 验收

`zsh scripts/test.sh` 通过 **65 项测试**；`zsh scripts/build-editor.sh` 构建成功。测试覆盖导出绑定／原图尺寸／中文说明／未知大整数保留／无标注交付、路径与链接拒绝、损坏材料保护、MCP 协议与 UTF-8 分页、只读图片返回、最近项目重开和晚到采集恢复。

原生验收使用不含真实账号或业务数据的合成 AppKit 窗口。通过现有已授权 Probe 显式采集可见窗口，取得 1360 × 936 截图、14 个 AX 节点和 OCR（AX 为 `partial_read_errors`，没有宣称完整）。在编辑器截图上点选“保存设置”，填写“这里的提示不清楚”，点击“交给 Agent”，随后经真实 `oneshot-mcp` 子进程读取材料，核对：

- 意见完整保留，绑定 `n6`、`AXButton`、`fixture-save-settings`，控件文字为“保存设置”。
- 返回的标注 PNG 与导出文件逐字节一致。
- 导出后标注仍未保存；另存项目后退出应用，重开并从最近采集恢复该条意见成功。
- 未标注材料也能通过真实 stdio 子进程读取整次中文上下文与原始 PNG。
- 保持 stdin 打开的真实客户端已验证初始化、工具列表、摘要、标注列表和 manifest 逐条响应；不依赖客户端关闭输入才返回结果。

本机证据在 Git 忽略的 `LocalEvidence/workflow-validation/`。新 CLI 的五段计时／失败状态也已实测，但该直接 CLI 没有 AX 授权，截图刻意跳过；它只证明计时输出可运行，不证明采集成功或速度提升。固定授权 Probe 的身份未改变。

全局快捷键真实按键在上一轮有成功记录；本轮 UI 自动化的组合键没有触发全局快捷键，前台切换也未通过目标检查。因此新增 HUD 的实际焦点行为、连续快捷键、脏项目期间新采集、关闭窗口后快捷键和真实超时后重试仍需实机复测。代码与离线恢复测试不替代这些验收。
