# 构建与发布

OneShot 支持 macOS 14+ 与 Apple Silicon（arm64），使用 MIT License，目前为 Pre-release，采用手动下载替换更新。历史 build 4 为 ad-hoc 签名；截至 2026-10-28，本地 build 10 的构建清单记录 Apple Development 签名，来源为 `6fec1ce5ea42`，仍未经 Apple 公证。这不代表已经发布 GitHub Release，也不代表 Developer ID 分发验收完成。实际下载包以对应版本的发布说明及构建清单为准。

首次公开前参见[公开发布检查表](public-release-checklist.md)。下述证书构建流程需要先配置签名身份；加入工作流本身不会改变已安装版本或现有授权。

## 组件与代码身份

```text
OneShot.app/
  Contents/
    MacOS/oneshot-editor
    Helpers/OneShot Capture.app/Contents/MacOS/oneshot
    Helpers/oneshot-mcp
    Resources/…应用图标、许可证与安装说明
```

| 组件 | 代码签名标识 | 作用 |
| --- | --- | --- |
| OneShot | `io.github.ytwsy.oneshot` | 编辑器、菜单栏和全局快捷键 |
| OneShot Capture | `io.github.ytwsy.oneshot.capture-probe` | 实际执行截图、AX、OCR 和显式权限请求 |
| oneshot-mcp | `io.github.ytwsy.oneshot.mcp` | 读取用户明确选定的一份交付材料 |

三个组件使用同一证书，从内向外分别签名。发布版只使用内置 Capture，不替换开发版 Probe，也不修改系统 TCC 权限。保持 Bundle ID、安装路径与兼容的 designated requirement（DR，代码身份要求）；不要在每次构建时生成新证书。

| 签名模式 | 适用范围 | 更新边界 |
| --- | --- | --- |
| `self-signed` | 固定自签根证书，用于受控测试 | 显式 DR 绑定组件 ID 与证书指纹，须复用同一证书及私钥；权限行为需实机验证 |
| `apple-development`（当前默认） | 本地开发与升级权限验证 | 使用 Apple Development 身份，校验真实 Apple 证书链和 Team ID |
| `developer-id` | 面向分发的签名 | 使用 Developer ID Application 身份及安全时间戳；当前流程仍不执行公证 |
| `ad-hoc` | 明确选择的临时包 | 代码变化会改变身份要求，不能作为保持升级权限的方案 |

Apple 说明隐私权限依赖代码身份要求；自签证书是否被某个子系统接受还取决于该子系统的策略。DR 检查通过只是升级验收的一部分，不能证明用户 Mac 已保留屏幕录制或辅助功能授权。见 [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/)。

2026-10-27 在 macOS 14.8.5 的隔离对照中，仅导入 P12、指定 `--keychain` 而未加入用户钥匙串查找列表时，`codesign` 找不到身份。临时加入查找列表后，无需修改系统信任，即可签出两个代码不同的版本，三个组件的验证和双向 DR 比较均通过。证书仍显示 `CSSMERR_TP_NOT_TRUSTED`，因此不能用 `find-identity -v` 的默认信任判断阻断该自签路径。

当前验证支持的自签证书约束是 `basicConstraints=critical,CA:true`、`keyUsage=critical,digitalSignature,keyCertSign`、`extendedKeyUsage=critical,codeSigning`。`CA:false` 的自签 leaf 虽可被 codesign 使用，但本机 LibreSSL 的自签根校验不接受它，当前流程不支持。临时实验身份已经销毁，尚未创建长期私钥，也未验证 TCC 权限继承。

## 本地构建

当前采用 Apple Development 验证本机升级。先在钥匙串中准备 Apple 签发的开发证书及对应私钥，再运行：

```sh
security find-identity -v -p codesigning
```

只有 `.cer`、没有对应私钥，不能用于签名。如果已有另一台 Mac 导出的开发签名身份，可将带私钥的 P12 导入本机钥匙串；不要每次出包重新创建证书。没有现有身份时，通过完整 Xcode 的 Settings → Accounts 添加 Apple 账户，选择团队，在 Manage Certificates 中创建 Apple Development。免费账户可使用 Personal Team，见 Apple 的[签名工作流](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html)与[证书管理](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html)。账户登录及双重认证由用户完成。

当前验证机器运行 macOS 14.8.5；Apple 的[兼容表](https://developer.apple.com/xcode/system-requirements)列明 Xcode 16.2 支持 macOS 14.5 起的 Sonoma。需要此旧版时从 [Apple Developer 下载页](https://developer.apple.com/download/all/?q=Xcode%2016.2)取得，不直接假设 App Store 最新版兼容。Xcode 可只用于配置签名账户，无须为本流程更改全局 `xcode-select`。

先测试并提交准备出包的源码，构建脚本从干净 Git 提交导出隔离源码。证书和私钥留在钥匙串中；身份参数使用 `security find-identity -p codesigning` 对应的 **40 位证书 SHA1**。

```sh
export ONESHOT_SIGNING_IDENTITY='<40-character-certificate-SHA1>'
zsh scripts/build-release.sh --version 0.1.0-alpha.1 --build-number 5 --ref HEAD \
  --signing-mode apple-development
```

已有证书签名的授权基线时，增加 `--previous-app /Applications/OneShot.app`。这是阻断式检查：新旧三个组件必须互相满足对方的 DR，否则不生成交付包。从旧 ad-hoc 迁移到证书身份时，预期不兼容，需要首次重新授权；迁移包应省略此参数，并在发布说明中明确迁移边界。后续升级再以已授权的证书版本为基线。

当前按 Apple Development 路线验证本机升级权限。Apple 模式建议传 `--expected-team-id <TEAMID>`。将来准备分发时可显式改用 `--signing-mode developer-id` 并单独完成相应验收。指定非默认钥匙串时增加 `--signing-keychain /absolute/signing.keychain-db`。证书模式缺少身份、签名失败或证书类型不匹配都会停止，不回退到 ad-hoc。临时包必须显式传 `--signing-mode ad-hoc`，且不能同时指定证书。

产物目录为 `artifacts/OneShot-<version>-build<build>-<commit12>-<mode>/`，包含 App、DMG、SHA-256、源码归档、`code-signing.json` 和 `release-manifest.json`；有升级基线时另含 `identity-compatibility.json`。已有目录不覆盖。清单记录真实签名方式、各组件证书 SHA256、Team ID、DR、源码提交及 `permissionContinuity: not-verified`，不会把签名成功写成授权成功。关于窗口和安装说明也显示对应签名状态。

可独立检查现有包或比较两个包：

```sh
python3 packaging/signing.py verify --app /absolute/OneShot.app --signing-mode apple-development
python3 packaging/signing.py compare \
  --previous-app /absolute/old/OneShot.app --candidate-app /absolute/new/OneShot.app
```

## GitHub Actions 证书构建

`.github/workflows/build.yml` 执行普通编译和测试，不读取发布签名私钥。两份工作流的 `python3 scripts/test_signing_integration.py` 使用独立的两天临时证书，真正签出代码不同的两代 arm64 组件，校验 DR 兼容并清理证书、私钥和钥匙串查找项；该测试身份不会用于发布。`.github/workflows/signed-build.yml` 提供手动触发的证书构建，只允许默认分支，使用 GitHub environment `signing`，不会自动推送、打标签或创建 Release。

在**确认目标仓库后**配置 `signing` environment，并限制为仅允许默认分支部署；套餐支持时再设置 required reviewers。GitHub Pro / Team 私有仓库的环境不支持 required reviewers，不能把环境名称本身当成审批保护，参见 [GitHub 环境保护说明](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)。工作流引用 environment 不会自动替代仓库保护设置。配置以下 environment Secrets：

| Secret | 内容 |
| --- | --- |
| `ONESHOT_SIGNING_CERTIFICATE_BASE64` | 长期使用的证书及私钥导出的、带密码 P12 的 Base64 |
| `ONESHOT_SIGNING_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `ONESHOT_SIGNING_IDENTITY` | 该证书的 40 位 SHA1；它不是私钥 |

不要把 P12、私钥、导出密码或 Base64 内容放进仓库、构建参数、日志或产物。工作流将既有身份导入 runner 的临时钥匙串，保留原有查找项并添加本次钥匙串，所有签名显式指定此钥匙串；不会生成替代发布证书，不改变全局信任或用户默认钥匙串。任务结束移除本次钥匙串及查找项，保留其他条目；上传清单只包含公开构建结果。GitHub 官方流程见[在 Actions 中签名 Xcode 应用](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。

Apple 模式可在 environment Variables 设置 `ONESHOT_EXPECTED_TEAM_ID`，用于核对预期团队；自签模式不设置此变量。手动运行时填写版本、构建号和签名模式，当前默认 `apple-development`。选择 `self-signed` 时使用满足上述约束的固定证书；它不会获得系统全局信任。`baseline_run_id` 可选：填入同一仓库前一次成功证书构建的 run ID，下载其 App 作为 DR 基线。首次证书构建留空，报告应显示未做基线检查。旧产物过期、签名模式或身份不兼容时修复基线或身份配置，不跳过失败冒充升级通过。

工作流的 App 使用 tar 归档保留可执行权限，当前布局不需要 App 内符号链接，基线解包拒绝链接与越界路径。产物名包含 run ID 和 attempt；DMG、校验和及报告一起上传。CI runner 换机器不影响证书身份，用户授权仍保存在用户 Mac 上。证书轮换需要重新比较兼容性；固定自签证书的 leaf 指纹改变会失败。

## 升级与发行验收

自动校验包括三个组件的 arm64 架构、macOS 14.0 部署目标、Bundle ID、版本／构建／提交一致性、hardened runtime、签名完整性，以及证书实际类型。Developer ID 和 Apple Development 通过 Apple anchor、用途 OID 与 Team ID 校验；自签模式校验自签证书及精确 leaf DR。模式名称或证书显示名称不能替代这些检查。

权限保持必须在用户 Mac 完成一次真实升级链路：

1. 安装证书签名版本 A 到 `/Applications/OneShot.app`，为实际 Capture 组件批准屏幕录制和辅助功能；确认截图及 AX 控件读取成功。
2. 使用相同身份从 Actions 构建代码发生变化的版本 B，指定 A 的 CI run 为基线（若 A 为本地包，先独立执行 compare）。
3. 退出 A、替换安装 B、从相同路径启动，检查 Capture 的实际权限，并真正截图、读取控件。
4. 记录 macOS 版本、A/B 提交、证书指纹、DR 比较结果及实际采集结果。只在该环境验证通过后描述“此次升级保留权限”。

旧 ad-hoc → 首个证书版本需要单独作为迁移验收，不能拿它证明后续证书版本之间失去权限。不要自动重置 TCC、代替用户批准权限或关闭系统安全检查。权限恢复步骤见[权限引导](permissions.md)。

其他实机验收包括 DMG 只读挂载和安装、下载后的 Gatekeeper 首次打开、首次授权与失败恢复、连续快捷键、未保存标注期间的新采集、关闭编辑窗口后再采集、HUD 焦点和持续 stdio 的 MCP。签名检查不代替这些验收，未完成项保留在预发布说明中。

## 公开发布

文档中的计划目标是 `YTwsy/OneShot`，但远端以实际确认和配置为准。首次公开前确认目标、可见性、推送范围、版本标签与产物，并检查准备公开的文件和历史是否含凭据、原始截图、AX／OCR 正文或个人路径。保留当前 Git 作者身份。`Captures/`、`Ref/`、`LocalEvidence/`、`Edits/`、`.build/`、`artifacts/` 留在本地。

在相同已验证提交打标签，以 Pre-release 发布 DMG、校验和及构建清单，再核对远端标签和实际产物。构建与签名流程本身不发布 Release，也不证明公证或实机升级验收通过。

### 从 GitHub 产物发布已有草稿

`.github/workflows/publish-preview.yml` 在默认分支上手动触发，适用于私有或公开仓库。输入成功的 `Signed preview build` 的 `build_run_id`，以及已存在的 Pre-release 草稿 `release_id`。草稿的 `target_commitish` 必须是该构建的完整源码提交，标签必须与构建清单一致。

工作流检查构建来自同一仓库的默认分支、指定签名工作流及成功的手动运行，下载对应 attempt 的产物并校验摘要。随后核对清单中的文件哈希，仅上传 DMG、校验和、源码归档、构建清单及签名报告。已经上传且哈希一致的附件会保留；不覆盖不一致或未完成的附件，不向已经发布的版本追加文件。五项附件齐全且哈希正确后，才将草稿发布为 Pre-release。

该步骤使用仓库 `GITHUB_TOKEN` 的 `contents: write` 与 `actions: read`，不读取签名 Secrets，也不重新编译 App。构建提交可以早于后续的纯发布工作流修正；Release 始终绑定经验证的构建提交。远端未完成的上传占位项需要先确认来源并单独处理，不由工作流自动删除。
