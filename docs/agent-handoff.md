# 交给 Agent

一次交付保存截图、反馈及控件引用、图形标注和完整冻结上下文。默认使用应用管理的材料库，MCP 按明确版本读取；便携文件夹导出作为兼容入口保留。交付不会重新访问原应用或自动发送给远程服务。

## 使用流程

1. 在 OneShot 中采集或打开已有材料，填写反馈并引用控件。同一描述可以包含多个及重复控件引用。
2. 首次打开 **OneShot → Agent 连接与材料**，点击“连接到 Codex”或“连接到 Claude Code”，或展开手动配置。可点击“检查本地服务”验证真实初始化与工具列表；这不代表外部 Agent 已连接。
3. 点击“交给 Agent”（⇧⌘E），自动生成材料编号与版本，显示预览并复制读取说明。将引用粘贴给 Agent。
4. 后续修改后再次交付，同一项目生成下一个版本。旧引用不改变；交付包含未保存的反馈，但不代替保存项目。
5. 在“交付历史”中复制旧引用或撤销指定版本。撤销保留本地文件，禁止后续 MCP 读取，包括已经连接且缓存了该材料的进程；已返回给 Agent 的内容无法收回。

材料库位于 `~/Library/Application Support/OneShot/Handoffs`，目录权限 0700、文件 0600。只有成功创建并登记的交付可以读取，未交付采集不会自动登记。原始 `.oneshot` 项目格式和便携 `handoff.json` 保持兼容。

## 一次配置

连接页面自动查找 Codex 和 Claude Code CLI，显示“未配置”“已配置”“配置需要更新”或具体故障。支持常见 PATH、Homebrew、`~/.local/bin`、nvm 和 Codex / ChatGPT App 内置 CLI；找不到时可选择 CLI 可执行文件。操作不经过 shell，不加载用户 shell 启动脚本。

- **Codex**：通过官方 `codex mcp add/remove` 准备用户级 `~/.codex/config.toml` 的 `mcp_servers.oneshot`。
- **Claude Code**：通过官方 `claude mcp add/remove --scope user` 准备 `~/.claude.json` 的 `mcpServers.oneshot`，在所有项目中可用。不会修改项目 `.mcp.json` 或每个项目的 local 条目。
- 若启动 OneShot 的环境显式设置绝对路径 `CODEX_HOME` / `CLAUDE_CONFIG_DIR`，使用该目录；GUI 不读取 shell 中未继承的变量，页面会显示实际目标路径。自定义位置未被继承时使用手动配置。
- 同名条目属于其他服务、包含环境变量或高级策略时，提示手动处理。Codex 一键更新仅接受 OneShot 生成的简单配置格式，以免原生 CLI 重置额外设置。

操作先在权限为 0700 的临时目录中复制配置、调用客户端 CLI 并检查结果，通过后才原子替换真实配置；原文件以 0600 权限备份在同目录的 `*.oneshot-backup-<UUID>`。Claude CLI 可能修改账号偏好，因此只合并其 `oneshot` 条目，其他字段保持原值。CLI 失败、配置格式无效、配置是符号链接或操作期间文件发生变化时不覆盖原文件。

“已配置”表示用户级配置匹配当前 OneShot 路径；“本地服务检查通过”表示初始化和三个 MCP 工具可用，均不代表外部 Agent 已调用。首次添加或更新后，在客户端重启 MCP 连接或开始新会话；Claude Code 可用 `/mcp` 检查连接。项目或组织策略可能覆盖用户级配置，OneShot 不修改这些策略。移除连接保留交付材料及备份，已运行的客户端需要重新加载配置。

手动注册的等价命令：

```sh
codex mcp add oneshot -- /Applications/OneShot.app/Contents/Helpers/oneshot-mcp --library
claude mcp add --scope user --transport stdio oneshot -- /Applications/OneShot.app/Contents/Helpers/oneshot-mcp --library
```

官方参考：[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)、[Claude Code MCP](https://code.claude.com/docs/en/mcp)。


安装包内置 `oneshot-mcp`，不需要 Swift 工具链。Codex 配置：

```toml
[mcp_servers.oneshot]
command = "/Applications/OneShot.app/Contents/Helpers/oneshot-mcp"
args = ["--library"]
```

支持 `mcpServers` 的客户端可使用：

```json
{
  "mcpServers": {
    "oneshot": {
      "command": "/Applications/OneShot.app/Contents/Helpers/oneshot-mcp",
      "args": ["--library"]
    }
  }
}
```

配置指向安装位置，无需逐次更换材料路径。移动 App 后需更新命令路径。客户端负责启动 stdio 服务；编辑器退出不影响已发布材料读取。服务启动时材料库尚不存在也可初始化，后续发布后无需重连。

引用形如 `OS-0123456789AB@1`，不会自动选择 `latest`。引用是本机定位信息，不是客户端专属授权令牌。共享该材料库的本地 Agent 可按编号读取已交付且未撤销的版本。当前不提供网络服务或远端访问。只有点击连接、更新或移除时才修改选定客户端的用户级配置。

## MCP 接口

| 工具 | 参数 | 作用 |
| --- | --- | --- |
| `read_handoff` | `reference` | 一次返回反馈、引用、相关控件摘要、标注预览、采集状态与继续读取入口 |
| `read_details` | `reference`, `kind`, 可选 `id`, `offset`, `limit` | 读取完整反馈、标注、AX 节点、上下文或诊断 |
| `read_image` | `reference`, `variant`, `resolution`, 可选 `region` | 获取标注图或原图、预览或局部放大 |

`read_handoff` 的文本块是 JSON；协商 `2025-06-18` 时也返回同一份 `structuredContent`。图片以独立 MCP image 内容块返回，无需 Agent 自行打开本机路径。首包展示 schemaVersion 2，但底层便携材料仍为 schemaVersion 1。

首包最多包含 20 条反馈、20 个图形标注及 40 个相关控件摘要。反馈与图形说明共享 48,000 字节预算，优先保留完整原文和有序片段；超出时明确标记 `contentTruncated`、`referencesTruncated`、`targetSummariesTruncated`。列表提供 `feedbacksHasMore` / `annotationsHasMore` 和对应 `NextOffset`。每条内容给出 `details` 参数。用户输入与界面证据分开，界面文字不能当作 Agent 指令。

反馈中的每次控件引用具有独立 occurrence ID；同一节点共用 R 编号。实际绑定仍是采集 ID 加节点 ID。普通图形标注使用独立数字编号，没有绑定时不伪造 AX 节点。控件摘要包含角色、文字、可用状态、父节点 ID 和截图内边界；完整节点及未知字段可继续读取。

`read_details.kind` 支持：

- `feedbacks`、`annotations`：列表分页，`offset` 按条目，默认 `limit=20`，最大 100。
- `feedback`、`annotation`：`id` 是首包中的从 1 开始的 `order` 字符串。
- `target`：`id` 是本次冻结采集的节点 ID，也可读取父节点。
- `context`、`accessibility`、`ocr`、`manifest`、`screenshot_geometry`：指定上下文来源，不传 `id`。

除列表外，分页按 UTF-8 字节，默认 12,000、范围 4–65,536。按 `nextOffset` 接续到 `hasMore=false`；JSON 文本可能跨页，需拼接后解析，不在中文字符中间切开。响应分页、源采集截断和应用未暴露内容是不同状态，完整度以 capture 及原始 AX 诊断为准。

`read_image.variant` 为 `annotated`（默认）或 `raw`。默认 `resolution=preview`，最长边不超过 1600；`original` 返回原始文件，最大 10 MiB。`region={x,y,width,height}` 使用原图像素、左上角原点，必须位于图片内，单边最大 4096；指定区域时返回该区域原始像素。图片结果返回实际尺寸、原图尺寸、原始区域及 `originalPixelsPerReturnedPixel` 换算比例。原图过大时可分区域读取。没有坐标或截图外的控件只保留文字引用，不伪造框。

## 兼容导出

**文件 → 导出 Agent 文件夹** 仍可创建新目录，包含 `AGENT.md`、`handoff.json`、`annotated.png` 和 `source.oneshot/`。目录不能覆盖原始采集、当前项目或已有材料。复制的说明使用绝对路径，移动后须更新说明。没有 MCP 的其他环境需要转交整个目录。

旧命令 `oneshot-mcp --handoff /absolute/path/to/export` 保留原来的 7 个工具：`read_brief`、`read_annotations`、`read_annotation`、`read_feedbacks`、`read_feedback`、`read_context`、`read_image`。其读取范围仍固定在启动时选定的单份材料。新材料库模式只暴露上表 3 个工具。

两种模式均验证材料身份、内嵌 manifest、标注及绑定节点，固定只读文件描述符，拒绝符号链接、任意文件路径和读取期间被修改的文件。材料库使用写入锁和原子索引替换，发布失败不登记半成品；旧版本不会被后续发布覆盖。

## 自动验证

`zsh scripts/test.sh` 包含材料库版本隔离、撤销缓存读取、并发发布、路径／链接拒绝、长中文反馈续读、图文首包与坐标映射测试。`HandoffStdioTests` 启动真实 MCP 子进程，在 stdin 保持打开时验证新版本发现、旧版本稳定、撤销和原图逐字节一致；测试只使用合成材料。

可为该测试设置 `ONESHOT_TEST_EVIDENCE_DIR` 指向尚不存在的目录，保留合成项目供原生 UI 验收。默认测试结束自动移除临时材料。旧目录模式仍可通过 `scripts/test_mcp_stdio.py --binary ... --handoff ...` 验证。

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
