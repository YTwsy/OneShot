# OneShot

独立的应用截图与上下文分享工具。优先支持 macOS，提供 Pinpoint 类似的用户界面与标注体验，并以接近 Codex 原生 Appshots 的信息完整度为采集目标，同时提供通用 MCP 接口。

状态：需求记录，尚未开始实现。记录日期：2026-10-25。

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
| 音乐 | 搜索内容、歌曲列表、播放控件及状态、音量、焦点 |
| OpenSurge | 内嵌 WebView 的节点、延迟、协议、检测时间、策略状态及已暴露的视口外文本 |
| Cursor | 文件／窗口 URL、编辑器文本与选中内容；AX 不可用时的说明及中文 OCR 补充 |

## 实现与复用方向（待验证）

- 以 Pinpoint 的交互和标注为基础，增强捕获核心，可以参考开源 Appshots／Peekaboo 的采集实现，但是不要被这些实现束缚，这些只是潜在参考。
- GUI 与 MCP 共享捕获核心和快照存储，保留完整结果，按需向 Agent 返回。
- 根据实测补充 WebView、浏览器、编辑器适配及中文 OCR；浏览器扩展不能直接覆盖任意 App 的内嵌 WebView。
- 原生 Codex Appshots 捕获器能否独立复用仍未验证，不作为已确定的产品依赖。
- 最低 macOS 版本、具体技术栈、开源与分发方式尚未确定。

## 参考

- [Pinpoint](https://github.com/croustibat/Pinpoint)：交互、标注与现有 MCP 流程。
- [开源 Appshots](https://github.com/Shahfarzane/appshots)：独立的截图、AX、存储和 MCP 实现，非 OpenAI 项目。
- [Remarc](https://github.com/metedata/Remarc)：优先评估的现成标注与 Agent 协作应用。
- [Peekaboo](https://github.com/openclaw/Peekaboo)：采集与 Accessibility 实现参考。
- [原生 Appshots 文档](https://learn.chatgpt.com/docs/appshots)：能力与限制参考。
