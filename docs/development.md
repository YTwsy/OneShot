# 开发与 CLI

需要 macOS 14+、Swift 6 工具链与 Python 3。项目使用 SwiftPM，没有第三方 Swift 包依赖。

## 本地运行

```sh
zsh scripts/test.sh
zsh scripts/build-probe.sh
zsh scripts/build-editor.sh
open '.build/OneShot Editor.app'
```

开发版 Editor 和 Probe 使用独立开发身份，可以分开构建。`build-editor.sh` 不替换已授权的开发 Probe；重建 Probe 后应重新检查系统授权。安装版使用自己内置的采集组件，不与开发版共享身份。

## 命令行采集

```sh
zsh scripts/run-probe.sh doctor
zsh scripts/run-probe.sh authorize
zsh scripts/run-probe.sh capture --app com.apple.Music --output Captures/example --ocr
```

多个窗口时先用 `windows --app …` 查询，再显式指定 `--window-id`。`authorize` 主动请求系统权限；`capture` 和 `doctor` 不自动显示授权提示。读取已有捕获不会重新访问原应用。

采集不自动滚动、点击或切换目标应用的辅助功能模式。CLI 对 Electron AX 的启用是单独的显式选项。采集忙碌时不会重复启动；超时不终止组件或自动重试，完成结果可以恢复。

## 构建安装包

先提交拟发布的内容；构建脚本要求工作区干净，并从指定提交导出隔离源码。下例为**明确选择 ad-hoc 的本地测试包**，不代表适合公开分发或能够保持升级权限：

```sh
zsh scripts/build-release.sh \
  --version 0.1.0-alpha.1 --build-number 1 --ref HEAD \
  --signing-mode ad-hoc
```

实际使用时选择未用过的版本／构建号。脚本生成 App、DMG、校验和、源码归档及构建清单，保存到 Git 忽略的 `artifacts/`，不会覆盖已有产物或自动上传。

默认签名模式为 `apple-development`，必须提供可复用证书身份，不会失败后降级为 ad-hoc。证书、GitHub Actions、Developer ID 和公证边界详见[构建与发布](releasing.md)。

## README 动图

`scripts/render-readme-media.py` 使用代码绘制原创流程示意，不读取真实截图、采集、项目或材料库。依赖 Python 3.10+ 和 Pillow 10+，不影响应用本身的依赖。

```sh
python3 -m venv .build/readme-media-venv
.build/readme-media-venv/bin/python -m pip install 'Pillow>=10'
.build/readme-media-venv/bin/python scripts/render-readme-media.py
```

默认使用 macOS 的 PingFang 字体；其他环境可传 `--font /path/to/cjk-font.ttf`。字体不打包入仓库。默认输出 `docs/media/` 中两组流程的中英文版本，共四张循环 GIF 和四张静态 PNG；英文文件以 `.en.gif` / `.en.png` 结尾，供英文 README 使用。可用 `--language zh` 或 `--language en` 单独生成一个语言版本。英文示意图中的界面标签为说明性翻译，不表示应用已提供英文界面。首次连接、复制引用、粘贴和只读读取均按现有实现表达，不能用这些示意图作为实机验收证据。

首组动图从目标应用的前台窗口开始，展示快捷键采集、同一窗口进入冻结画布、引用控件、写反馈，再通过“控件”工具点选按钮并填写修改意见。单独重制这组动图和对应静态图时，在渲染命令后加 `--only annotate`；`--only handoff` 仅重制交付流程。两个选项可以组合，例如 `--only handoff --language en` 仅生成英文交付流程。

## 历史调查与验证

- [快捷键采集与计时](shortcut-capture.md)
- [原生标注编辑器](annotation-editor.md)
- [采集完整度基准](capture-baseline.md)
- [原生采集实测](capture-validation-2026-10-25.md)
- [前台场景对照](foreground-comparison-2026-10-25.md)
- [浏览器窗口匹配对照](browser-capture-comparison-2026-10-27.md)
- [历史 AppShot 调查与实现边界](codex-appshot-investigation.md)

这些报告仅描述对应日期、版本与样本，不是当前机器或未来版本的保证。原始参考图、实际捕获及本地验收证据留在本机，不纳入 Git。历史计时不能作为跨应用性能基准。
