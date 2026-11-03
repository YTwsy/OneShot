# 公开发布检查表

公开源码与发布可供普通用户安装的 App 是两件事。可以先公开源码并标记预发布状态，再完成分发签名、公证及安装验收。不要把本地构建成功写成 GitHub Release 已发布或实机验收通过。

## 本次检查记录

检查日期：2026-10-28。源码基线：`6fec1ce5ea42`。以下是该时点的本地观察，不会随仓库自动更新。

| 项目 | 观察 |
| --- | --- |
| Git 状态 | 检查开始时工作区干净，分支为 `codex/stable-signing`，未配置 remote |
| 许可证与依赖 | 已有 MIT License；SwiftPM 未声明第三方包依赖 |
| 历史范围 | 检查全部本地 refs 可达的 22 个提交、233 个不同 blob，约 2.5 MB |
| 有限规则扫描 | 未命中常见 GitHub / OpenAI / AWS 令牌、私钥头、带凭据 URL 或非示例个人主目录路径 |
| 本地材料 | 历史路径未见 `Captures/`、`LocalEvidence/`、`Ref/`、`Edits/`、`artifacts/`、`.signing/` 或 P12/PFX/钥匙串文件；当前 `.gitignore` 已排除这些目录与常见签名私钥文件 |
| 作者信息 | 历史有 1 组作者身份；公开历史会保留作者姓名与邮箱，本次未修改 |
| 构建流程 | 已有 macOS 构建与测试 CI；证书构建工作流仅手动触发，使用 `signing` environment，不自动发布 Release |
| 本轮测试 | `zsh scripts/test.sh` 在正常 macOS 环境下 113 项通过；受限环境首次运行卡在 AppKit 系统服务调用，停止后重跑通过。未启用真实客户端 CLI 的 opt-in 测试 |
| 本地安装包 | build 10 清单记录 Apple Development 签名、arm64、未经公证，来源为上述源码提交 |
| 首页素材 | 两张原创流程 GIF 及静态 PNG，只使用虚构数据，明确注明不是实机录屏 |

这是有限规则和文件范围的检查，**不是完整安全审计或无敏感信息保证**。没有检查远端仓库、GitHub 设置或实际 Release；未运行跨应用、首次安装与升级授权验收。正式推送前应针对最终提交再检查一遍，包括提交信息和计划附加的二进制文件。

## 公开源码前

- [ ] 确定仓库归属、名称和默认分支，决定当前开发分支如何进入公开主线；按实际地址配置 remote。
- [ ] 复核准备公开的文件、所有拟推送历史、提交信息和作者邮箱。不要只检查当前工作目录或依赖 `.gitignore`。
- [ ] 使用专门的秘密扫描工具复查历史；人工检查历史调查文档、复现文字和附件。若发现真实凭据，先撤销或轮换，再处理历史。参见 [GitHub 的敏感数据处理说明](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)。
- [ ] 确认第三方引用、代码、图标与字体的来源；本次示意图由仓库脚本生成，不打包字体文件。
- [ ] 运行最终提交的测试与 CI。纯文档变更检查链接和图片；采集与权限行为另外记录实机验收。
- [ ] 提交拟公开文档和素材；初次推送只选择计划公开的分支与标签，不盲目推送所有 refs。
- [ ] 确认历史调查报告可以公开；其中旧版本安装包路径、符号和实验结论不代表当前产品承诺。

公开后，其他人可以复制仓库内容。不要把“以后改回私有”当作收回已有副本的方法，参见 [GitHub 仓库可见性说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)。

## GitHub 仓库设置

- [ ] 在 GitHub 上检查 secret scanning，并启用适用的 push protection。参见 [secret scanning](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/detect-secret-leaks/enable-secret-scanning) 和 [push protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection)。
- [ ] 启用私密漏洞报告，实际确认 **Security → Report a vulnerability** 入口可用；仅添加 `SECURITY.md` 不会启用该功能。参见 [GitHub 配置说明](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)。
- [ ] 为默认分支设置所需检查与合并规则；确认 macOS CI 能在 GitHub runner 上通过。
- [ ] 若启用证书构建，配置 `signing` environment 的审阅者和默认分支部署限制。证书与密码放在 Secrets；不提交私钥，不给不可信 PR 提供签名材料。
- [ ] 填写仓库 About、描述和 topics；公开地址确定后再补 README 下载入口与实际 CI 链接，不添加虚构的通过徽章。

建议描述：`Native macOS capture and annotation for AI agents. Screenshots, control references, and frozen UI context through read-only MCP.`

建议 topics：`macos`、`swift`、`swiftui`、`mcp`、`screenshot`、`annotation`、`accessibility`、`ai-agents`。

## 发布第一个安装包前

- [ ] 选定版本、构建号和准确源码提交，更新 Changelog 与该版本说明，从干净提交构建。
- [ ] 明确分发策略。Apple Development 签名不等同于 Developer ID；当前脚本即使选 Developer ID，也不会自动执行公证。
- [ ] 面向普通用户分发时完成 Developer ID 签名与 Apple 公证；若先发布受控测试包，清楚标明签名类型、未经公证、适用机器与安装限制。
- [ ] 在实际 Mac 验证首次启动、两项授权、快捷键采集、控件引用、多条反馈、保存重开、版本交付及撤销。
- [ ] 验证 Codex / Claude Code 连接及 Agent 的真实读取；配置成功或本地 MCP 检查通过不能替代这一步。
- [ ] 验证一次旧版到新版升级，核对屏幕录制与辅助功能权限是否保持。
- [ ] 核对 DMG、SHA-256、源码归档、构建清单和签名报告；逐项检查拟上传报告中的证书身份与本机信息。
- [ ] 先创建 Pre-release，上传明确选择的产物并验证下载内容、架构、校验和与标签提交；不要上传整个 `artifacts/` 目录。

具体命令和验收边界见[构建与发布](releasing.md)。
