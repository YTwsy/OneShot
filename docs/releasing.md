# 构建与发布

首发产品为 OneShot，支持 macOS 14+ 与 Apple Silicon（arm64），使用 MIT License。GitHub 发布目标为 `YTwsy/OneShot`。首个候选版本为 `v0.1.0-alpha.1`，定位 Pre-release；自动更新后续加入。

当前没有 Developer ID 签名或 Apple 公证，分发包使用 ad-hoc 签名并明确标注未公证。签名、系统采集授权和功能验证是不同的验收项。

## 产品布局

```text
OneShot.app/
  Contents/
    Info.plist
    MacOS/oneshot-editor
    Resources/…应用图标与许可证
    Helpers/
      OneShot Capture.app/
        Contents/MacOS/oneshot
      oneshot-mcp
```

| 组件 | 发布身份 | 作用 |
| --- | --- | --- |
| OneShot | `io.github.ytwsy.oneshot` | 编辑器、菜单栏和全局快捷键 |
| OneShot Capture | `io.github.ytwsy.oneshot.capture-probe` | 实际执行截图、AX、OCR 和显式权限请求 |
| oneshot-mcp | 随 App 安装的命令行工具 | 读取用户明确选定的一份交付材料 |

正式 App 优先使用内置组件，不自动沿用开发 Editor 保存的外部 Probe 路径。开发版的 `dev.oneshot.editor`、`dev.oneshot.capture-probe` 和相邻 App 布局继续保留。发布构建不替换开发版 Probe，也不改动 TCC 状态。

## 本地构建

先完成源码修改、自动测试及必要实测，固定到一个干净提交，再执行：

```sh
zsh scripts/build-release.sh --version 0.1.0-alpha.1 --build-number 1 --ref HEAD
```

脚本从指定 Git 提交导出隔离的源码，使用 Release 配置与 arm64 构建三个可执行文件，组装 App 后从内向外签名，再制作 DMG。版本标签、数字应用版本、构建号和完整源码提交分别记录。`CFBundleShortVersionString` 使用 `0.1.0`；预发布后缀保留在发布标签与自定义元数据中。

产物保存在版本／构建／提交专属目录，包含 App、DMG、SHA-256、源码归档及 `release-manifest.json`。已有产物不覆盖；需要重新出包时使用新的构建号。

构建产物的清单和校验是发布依据，不把构建命令执行成功解释为安装、采集、签名信任或公证通过。发布脚本不上传、不创建 GitHub 仓库、不修改远程引用。

## 发行验证

自动校验应核对：

- App 内的主程序、采集组件和 MCP 齐全，架构均为 arm64，最低系统版本为 14.0。
- 主 App 与 helper 的 Bundle ID、数字版本、构建号、预发布标签及源码提交相互一致。
- 嵌套签名完整，实际为 ad-hoc；没有把本地签名描述为 Developer ID 或已公证。
- DMG 可只读挂载，内含完整 App、Applications 入口与许可证，SHA-256 可验证。
- 从挂载包复制到普通安装目录后，内置组件可被定位，MCP 以持续打开的 stdio 连接逐条响应。

人工实机验收还包括下载后的 Gatekeeper 首次打开、首次授权、采集失败后的恢复、升级后权限、连续快捷键、未保存标注期间的新采集、关闭编辑窗口后再采集和 HUD 不抢焦点。没有完成的项目必须保留在 Pre-release 说明中。

当前使用 ad-hoc 签名，升级后系统可能需要重新批准采集组件。应用的权限检查与授权入口使用实际 helper；最终批准由用户在系统设置中完成。不要用自动重置权限或关闭系统安全检查代替验证。

## GitHub 开源与发布

公开前检查当前文件及准备公开的历史：凭据、原始截图、AX／OCR 正文、设备和网络数据、个人文件路径、第三方代码或资源来源。`.gitignore` 不会移除已经进入历史的文件。保留当前仓库配置的 Git 作者与提交者身份，不为了平台隐私而静默改写它。

`Captures/`、`Ref/`、`LocalEvidence/`、`Edits/`、`.build/`、`artifacts/` 留在本地。发布 DMG 只从干净源码和明确的打包清单产生，不复制开发工作区。

GitHub 首次公开时，确认目标 `YTwsy/OneShot`、公开可见性、推送的提交／分支、版本标签和要上传的产物；然后创建仓库、推送经过核验的源码、在相同提交打标签，并以 Pre-release 发布 DMG、校验和及源码／构建清单。不要提前发布尚未验证的包，也不要将预发布标为稳定最新版。

发布后再次核对远程标签指向、Release 的 Pre-release 状态、产物名称／大小和校验和，记录链接。发布成功与否以远端实际状态为准。
