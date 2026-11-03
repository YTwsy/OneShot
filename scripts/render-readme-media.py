#!/usr/bin/env python3
"""Render original, fictional workflow diagrams; never read captures or user data.

Requires Python 3.10+ and Pillow 10+. Defaults to macOS fonts; use --font for
another CJK TrueType/OpenType font. Output is Chinese and English GIF + static
PNG, with no network. Use --language to render one language independently.
"""
import argparse
from functools import cache, partial
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFont

WIDTH, HEIGHT, SCALE = 1200, 760, 1.5
BG = "#101B2C"
INK = "#17283D"
MUTED = "#64748B"
MINT = "#77E5C0"
BLUE = "#376AF5"
CORAL = "#E5484D"
PALE = "#EBF1FF"
WHITE = "#FFFFFF"
FONT_PATH = ""
FONTS = {}

ENGLISH = {
    "流程示意 · 虚构数据": "Illustration · Fictional data",
    "示例应用 / 项目设置": "Demo app / Project settings",
    "发布你的下一个想法": "Publish your next idea",
    "项目名称": "Project name",
    "保存": "Save",
    "发布": "Publish",
    "示例应用     文件     编辑     视图": "Demo app     File     Edit     View",
    "OneShot 已运行": "OneShot is running",
    "示例备忘录": "Demo notes",
    "截取一个窗口": "Capture a window",
    "先切到目标应用": "Focus the target app",
    "按下采集快捷键": "Press the shortcut",
    "正在采集…": "Capturing…",
    "窗口画面已固定": "Window captured",
    "采集前台应用最靠前的可见窗口": "Capture the frontmost app's foremost visible window",
    "反馈描述": "Feedback",
    "描述想修改的地方": "Describe what to change",
    "与": "and",
    "统一按钮高度，保留主次样式。": "Match heights, keep the hierarchy.",
    "引用控件       @ 搜索": "Reference control     @ Search",
    "点击“写反馈”开始": 'Click "Write feedback" to begin',
    "点选画面中的控件…": "Pick a control in the image…",
    "R1 · AXButton · 保存": "R1 · AXButton · Save",
    "R2 · AXButton · 发布": "R2 · AXButton · Publish",
    "控件树": "Control tree",
    "点选画面中的控件": "Pick a control in the image",
    "编辑标注": "Edit annotation",
    "AXButton · 控件 #1": "AXButton · Control #1",
    "修改意见": "Change request",
    "与“发布”按钮保持相同高度。": "Match the height of Publish.",
    "为这个控件添加说明…": "Add a note for this control…",
    "已绑定到当前快照中的控件": "Bound to this captured control",
    "OneShot  /  反馈与标注": "OneShot / Feedback and annotations",
    "写反馈": "Write feedback",
    "控件": "Control",
    "编号": "Number",
    "箭头": "Arrow",
    "方框": "Box",
    "文字": "Text",
    "交给 Agent": "Hand to Agent",
    "已采集 · 编辑冻结快照": "Captured · Frozen snapshot",
    "反馈": "Feedback",
    "标注": "Annotations",
    "截取一个窗口，写反馈，标注控件": "Capture a window. Give feedback. Annotate controls.",
    "从目标应用到 OneShot：固定画面，引用控件，说明你想改什么。":
        "From the target app to OneShot: freeze the screen, reference controls, explain the change.",
    "按 Control + Option + Command + S，采集完成后自动打开 OneShot。":
        "Press Control + Option + Command + S. OneShot opens when the capture is ready.",
    "点击“引用控件”，点选保存和发布；R1 / R2 绑定到本次快照。":
        'Click "Reference control", then pick Save and Publish. R1 / R2 belong to this snapshot.',
    "写下具体修改意见；一条反馈可以同时引用多个控件。":
        "Describe the change. One piece of feedback can reference multiple controls.",
    "选择“控件”工具并点选按钮，填写这一个控件的修改意见。":
        'Choose "Control", pick a button, and describe the change for that control.',
    "截取窗口": "Capture a window",
    "引用控件": "Reference controls",
    "写下反馈": "Write feedback",
    "标注控件": "Annotate a control",
    "把画面、反馈和上下文，一起交给 Agent": "Give your agent the screen, feedback, and context",
    "首次连接一次；每次交付，只需粘贴一个固定版本的材料引用。":
        "Connect once. For each handoff, paste a reference to a fixed revision.",
    "OneShot / Agent 连接与材料": "OneShot / Agent connections and materials",
    "一次连接，持续交付": "Connect once. Hand off anytime.",
    "使用已安装客户端的 CLI 配置本地 MCP。": "Use your installed client's CLI to configure local MCP.",
    "用户级配置 · 本地材料库": "User config · Local library",
    "连接到 Codex": "Connect to Codex",
    "连接到 Claude Code": "Connect to Claude Code",
    "选择你使用的客户端，连接后在客户端重新加载 MCP。":
        "Choose your client, connect it, then reload MCP in that client.",
    "OneShot / 交给 Agent": "OneShot / Hand to Agent",
    "本次交付": "This handoff",
    "反馈与控件引用": "Feedback + references",
    "标注图 + 原图": "Annotated + original",
    "冻结 AX / OCR": "Frozen AX / OCR",
    "独立采集状态": "Capture status",
    "保存本次反馈的固定版本": "Create a fixed revision",
    "包含当前尚未保存的编辑内容。": "Includes your current unsaved edits.",
    "Agent 材料已准备好": "Your handoff is ready",
    "读取说明已复制到剪贴板": "Reading instructions copied",
    "将引用粘贴给已连接 OneShot MCP 的 Agent。":
        "Paste the reference into an agent connected to OneShot MCP.",
    "后续修改 → 再次交付 → 新版本 @2": "Edit → hand off again → revision @2",
    "旧引用仍指向原内容。": "Earlier references keep their original content.",
    "Agent 对话 / 通用示意": "Agent conversation / Generic example",
    "你": "You",
    "请读取 OS-0123456789AB@1，按反馈调整按钮。":
        "Read OS-0123456789AB@1 and update the buttons using my feedback.",
    "你的意图": "Your intent",
    "反馈原文 + R1 / R2 引用": "Feedback + R1 / R2 references",
    "画面证据": "Visual evidence",
    "标注预览 + 原始截图": "Annotated preview + original",
    "控件上下文": "Control context",
    "冻结节点 + 采集状态": "Frozen nodes + capture status",
    "需要更多细节时，继续调用 read_details 或 read_image。":
        "Need more detail? Call read_details or read_image.",
    "连接修改选定客户端的配置并保留备份；“已配置”不代表 Agent 已读取。":
        "Updates the chosen client's config with a backup; configured does not mean read.",
    "只有明确交付的内容进入材料库；采集草稿不会自动暴露。":
        "Only explicit handoffs enter the library. Capture drafts are not exposed automatically.",
    "材料留在本机；点击交付不会自动向 Agent 发送消息。":
        "Materials stay local. A handoff does not send a message to your agent.",
    "MCP 只读；Agent 客户端读取之后的数据处理由该客户端决定。":
        "Read-only MCP. Your agent client's policies apply after reading.",
    "连接客户端": "Connect a client",
    "交付快照": "Create a snapshot",
    "复制引用": "Copy the reference",
    "粘贴并读取": "Paste and read",
}


def font(size):
    if size not in FONTS:
        FONTS[size] = ImageFont.truetype(FONT_PATH, round(size * SCALE))
    return FONTS[size]


class Canvas:
    def __init__(self, size=(WIDTH, HEIGHT), background=BG, language="zh"):
        self.language = language
        self.image = Image.new("RGBA" if background is None else "RGB",
                               tuple(round(v * SCALE) for v in size),
                               (0, 0, 0, 0) if background is None else background)
        self.d = ImageDraw.Draw(self.image)

    def box(self, xy, fill, radius=12, outline=None, width=1):
        self.d.rounded_rectangle(tuple(round(v * SCALE) for v in xy), radius=round(radius * SCALE),
                                 fill=fill, outline=outline, width=round(width * SCALE))

    def label(self, value):
        if self.language == "en":
            value = ENGLISH.get(value, value)
            if any("\u3400" <= char <= "\u9fff" for char in value):
                raise ValueError(f"Missing English translation: {value}")
        return value

    def text(self, x, y, value, size=20, fill=INK):
        value = self.label(value)
        self.d.text((round(x * SCALE), round(y * SCALE)), value, font=font(size), fill=fill)

    def line(self, points, fill, width=2):
        self.d.line([(round(x * SCALE), round(y * SCALE)) for x, y in points], fill=fill,
                    width=round(width * SCALE), joint="curve")

    def badge(self, x, y, label, fill=BLUE):
        self.box((x, y, x + 39, y + 27), fill, 8)
        self.text(x + 7, y + 1, label, 16, WHITE)

    def cursor(self, x, y, click=False):
        if click:
            self.box((x - 17, y - 17, x + 17, y + 17), None, 17, MINT, 3)
        pts = [(x, y), (x + 4, y + 25), (x + 10, y + 18), (x + 17, y + 28),
               (x + 22, y + 25), (x + 15, y + 15), (x + 24, y + 13)]
        self.d.polygon([(round(a * SCALE), round(b * SCALE)) for a, b in pts], fill=INK,
                       outline=WHITE, width=round(2 * SCALE))

    def paste(self, image, xy):
        x, y, right, bottom = (round(v * SCALE) for v in xy)
        resized = image.resize((right - x, bottom - y), Image.Resampling.LANCZOS)
        self.image.paste(resized, (x, y), resized if resized.mode == "RGBA" else None)

    def finish(self):
        return self.image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)


def header(c, number, title, subtitle):
    c.box((36, 28, 138, 60), MINT, 16)
    c.text(52, 30, "OneShot", 18)
    c.text(158, 33, "SHOW IT. EXPLAIN IT. HAND IT OFF.", 14, "#A7B8CE")
    c.text(36, 76, title, 36, WHITE)
    c.text(38, 130, subtitle, 18, "#B6C5D8")
    c.text(1015, 36, number + " / 02", 20, MINT)


def footer(c, steps, active, caption):
    for i, title in enumerate(steps):
        x = 38 + i * 284
        color = MINT if i == active else "#23354C"
        c.box((x, 660, x + 266, 665), color, 2)
        c.text(x, 677, f"0{i + 1}  {c.label(title)}", 18, MINT if i == active else "#90A4BF")
    c.text(38, 718, caption, 16, "#C2CFDF")
    c.text(950, 721, "流程示意 · 虚构数据", 14, "#90A4BF")


def window(c, title, xy=(36, 178, 1164, 638), shadow=True):
    x, y, right, bottom = xy
    if shadow:
        c.box((x, y + 7, right, bottom + 7), "#0A1320", 19)
    c.box(xy, WHITE, 16)
    c.box((x + 1, y + 1, right - 1, y + 47), "#F3F5F8", 15)
    c.box((x + 1, y + 24, right - 1, y + 47), "#F3F5F8", 0)
    for i, color in enumerate(("#FF6C63", "#FFC553", "#60CA79")):
        c.box((x + 17 + i * 20, y + 18, x + 28 + i * 20, y + 29), color, 6)
    c.text(x + 101, y + 11, title, 17, MUTED)


DESKTOP_WINDOW = (152, 249, 882, 575)
SNAPSHOT_WINDOW = (82, 307, 720, 592)
CAPTURE_END = 2.5
EDITOR_START = 3.2


def ease(progress):
    p = max(0, min(1, progress))
    return p * p * (3 - 2 * p)


@cache
def example_window(language="zh"):
    """Use identical fictional window pixels on the desktop and in the snapshot."""
    c = Canvas((638, 285), background=None, language=language)
    window(c, "示例应用 / 项目设置", (0, 0, 638, 285), shadow=False)
    c.text(25, 69, "发布你的下一个想法", 25)
    c.text(25, 109, "项目名称", 16, MUTED)
    c.box((24, 141, 612, 186), "#F7F9FC", 7, "#DAE2EC")
    c.text(39, 149, "Demo workspace", 18)
    c.box((356, 229, 466, 261), "#EFF2F7", 8)
    c.text(392, 231, "保存", 18)
    c.box((484, 221, 602, 261), BLUE, 8)
    c.text(514 if language == "en" else 522, 228, "发布", 18, WHITE)
    return c.image


def capture_scene(c, t, show_window=True):
    # Desktop context makes the capture target visibly distinct from OneShot.
    c.box((36, 178, 1164, 638), "#253F53", 16)
    c.box((37, 179, 1163, 215), "#355365", 15)
    c.box((37, 199, 1163, 215), "#355365", 0)
    c.text(62, 184, "示例应用     文件     编辑     视图", 15, WHITE)
    c.box((978, 183, 1144, 209), "#203D48", 9)
    c.text(995, 184, "OneShot 已运行", 15, MINT)
    window(c, "示例备忘录", (73, 231, 519, 510))
    for y, length in ((306, 260), (339, 316), (372, 230), (405, 280)):
        c.box((99, y, 99 + length, y + 7), "#DCE4ED", 3)
    if show_window:
        c.box((148, 253, 890, 585), "#142C3C", 17)
        c.paste(example_window(c.language), DESKTOP_WINDOW)
        if t >= 1.2:
            c.box((148, 245, 886, 579), None, 17, MINT, 3)
    c.box((908, 249, 1142, 575), "#192E42", 14)
    c.text(928, 268, "截取一个窗口", 24, WHITE)
    c.text(929, 310, "先切到目标应用", 18, "#B6C5D8")
    pressed = .8 <= t < 1.9
    for i, key in enumerate(("Ctrl", "Opt", "Cmd", "S")):
        x = 927 + i * 51
        c.box((x, 357, x + 43, 402), MINT if pressed else "#304C63", 8)
        key_width = font(16).getlength(key) / SCALE
        c.text(x + (43 - key_width) / 2, 369, key, 16, INK if pressed else WHITE)
    c.text(931, 416, "Control + Option", 16, "#B6C5D8")
    c.text(931, 441, "+ Command + S", 16, "#B6C5D8")
    label = "按下采集快捷键" if t < 1.2 else "正在采集…" if t < 1.9 else "窗口画面已固定"
    c.box((927, 497, 1123, 546), "#254E4F" if t >= 1.2 else "#304C63", 9)
    c.text(945, 509, label, 19, MINT if t >= 1.2 else WHITE)
    c.text(154, 599, "采集前台应用最靠前的可见窗口", 18, "#D4E5EE")
    if t < .8:
        p = ease(t / .5)
        c.cursor(754 - 160 * p, 418 - 143 * p, .5 <= t < .8)


def feedback_inspector(c, t):
    c.text(789, 337, "反馈描述", 22)
    c.box((787, 377, 1137, 530), "#F9FBFF", 11, "#D7E1F1")
    c.text(803, 388, "描述想修改的地方", 15, MUTED)
    if t >= 2.2:
        c.badge(803, 424, "R1")
        c.text(851, 425, "保存", 18, BLUE)
    if t >= 4:
        c.text(900, 425, "与", 18)
        c.badge(935, 424, "R2")
        c.text(982, 425, "发布", 18, BLUE)
    if t >= 4.7:
        message = c.label("统一按钮高度，保留主次样式。")
        rate = len(message) / 1.9 if c.language == "en" else 8
        typed = message[:min(len(message), int((t - 4.7) * rate))]
        c.text(804, 465, typed, 19)
        if t < 6.7 and int(t * 4) % 2 == 0:
            x = 804 + font(19).getlength(typed) / SCALE
            c.line([(x, 469), (x, 490)], BLUE)
    picking = 1.3 <= t < 2.2 or 3.1 <= t < 4
    if picking:
        c.box((796, 497, 941 if c.language == "en" else 882, 522), PALE, 6)
    c.text(802, 500, "引用控件       @ 搜索", 16, BLUE)
    if t < 2.2:
        prompt = "点击“写反馈”开始" if t < .6 else "点选画面中的控件…"
        c.text(803, 439, prompt, 18, MUTED)
    if t >= 2.2:
        c.text(790, 548, "R1 · AXButton · 保存", 17, MUTED)
    if t >= 4:
        c.text(790, 580, "R2 · AXButton · 发布", 17, MUTED)


def control_inspector(c, t):
    if t < 8.1:
        c.text(789, 337, "控件树", 22)
        c.text(789, 380, "点选画面中的控件", 18, MUTED)
        for y, label in ((428, "保存"), (510, "发布")):
            selected = label == "保存" and t >= 7.8
            c.box((787, y, 1137, y + 69), PALE if selected else "#F7F9FC", 9)
            c.text(805, y + 8, label, 20, BLUE if selected else INK)
            c.text(805, y + 39, "AXButton", 15, MUTED)
        return

    c.text(789, 337, "编辑标注", 22)
    c.box((787, 378, 1137, 451), "#FFF5F5", 10, "#F2D3D5")
    c.box((802, 398, 834, 430), CORAL, 16)
    c.text(813, 401, "1", 18, WHITE)
    c.text(850, 385, "保存", 21)
    c.text(850, 419, "AXButton · 控件 #1", 16, MUTED)
    c.text(789, 470, "修改意见", 18)
    c.box((787, 504, 1137, 574), "#F9FBFF", 10, "#D7E1F1")
    note = c.label("与“发布”按钮保持相同高度。")
    rate = len(note) / 1.8 if c.language == "en" else 8
    typed = note[:max(0, min(len(note), int((t - 9) * rate)))]
    if t < 8.8:
        c.text(803, 526, "为这个控件添加说明…", 18, MUTED)
    else:
        c.text(803, 526, typed, 19)
        if t < 10.9 and int(t * 4) % 2 == 0:
            x = 803 + font(19).getlength(typed) / SCALE
            c.line([(x, 529), (x, 551)], BLUE)
    c.text(789, 591, "已绑定到当前快照中的控件", 16, "#147153")


def editor_scene(c, t, show_window=True):
    window(c, "OneShot  /  反馈与标注")
    if t < 7.4:
        c.box((64, 240, 210 if c.language == "en" else 153, 273), PALE, 8)
    c.text(77, 244, "写反馈", 17, BLUE if t < 7.4 else MUTED)
    tool_positions = (226, 320, 410, 490, 553) if c.language == "en" else (174, 230, 286, 342, 398)
    for x, label in zip(tool_positions, ("控件", "编号", "箭头", "方框", "文字")):
        selected = label == "控件" and t >= 7.4
        if selected:
            label_width = font(16).getlength(c.label(label)) / SCALE
            c.box((x - 8, 240, x + label_width + 8, 273), PALE, 7)
        c.text(x, 244, label, 16, BLUE if selected else MUTED)
    c.box((1007, 237, 1141, 273), BLUE, 8)
    c.text(1018 if c.language == "en" else 1028, 243, "交给 Agent", 17, WHITE)
    c.box((59, 288, 744, 614), "#EDF1F7", 11)
    if show_window:
        c.paste(example_window(c.language), SNAPSHOT_WINDOW)
    c.box((518, 192, 752 if c.language == "en" else 732, 218), "#E2F5ED", 8)
    c.text(531, 193, "已采集 · 编辑冻结快照", 15, "#147153")
    c.line([(763, 292), (763, 615)], "#DEE5EF")
    active_tab = "反馈" if t < 7.4 else "控件树" if t < 8.1 else "标注"
    tab_positions = (789, 898, 1032) if c.language == "en" else (789, 867, 945)
    for x, label in zip(tab_positions, ("反馈", "标注", "控件树")):
        c.text(x, 294, label, 18, BLUE if label == active_tab else MUTED)
    if t < 7.4:
        feedback_inspector(c, t)
    else:
        control_inspector(c, t)

    if t >= 2.2:
        if t < 7.4 or 7.8 <= t < 8.1:
            c.box((432, 530, 554, 574), None, 10, BLUE, 3)
        c.badge(514, 505, "R1")
    if t >= 4:
        if t < 7.4:
            c.box((560, 522, 690, 574), None, 10, BLUE, 3)
        c.badge(650, 501, "R2")
    if t >= 8.1:
        # A control annotation binds a numbered border to the captured AX bounds.
        c.box((435, 533, 551, 571), None, 6, CORAL, 3)
        c.box((438, 536, 468, 566), CORAL, 15)
        c.text(448, 538, "1", 18, WHITE)

    # Each reference pick is one-shot, so explicitly click the button twice.
    control_tool = (253, 254) if c.language == "en" else (190, 254)
    cursor_segments = (
        (0, .6, (730, 360), (110, 254), True),
        (.8, 1.3, (110, 254), (838, 510), True),
        (1.5, 2.2, (838, 510), (490, 547), True),
        (2.6, 3.1, (490, 547), (838, 510), True),
        (3.3, 4, (838, 510), (624, 547), True),
        (4.3, 4.7, (624, 547), (1038, 470), True),
        (6.9, 7.4, (1038, 470), control_tool, True),
        (7.6, 8.1, control_tool, (490, 547), True),
        (8.3, 8.8, (490, 547), (890, 535), True),
    )
    for start, end, origin, target, click in cursor_segments:
        if start <= t < end + .2:
            p = ease((t - start) / (end - start))
            x, y = (a + (b - a) * p for a, b in zip(origin, target))
            c.cursor(x, y, click and t >= end)
            break


def annotate(t, language="zh"):
    c = Canvas(language=language)
    if t < CAPTURE_END:
        capture_scene(c, t)
    elif t < EDITOR_START:
        # Follow the same window into the editor; desktop chrome stays behind.
        p = ease((t - CAPTURE_END) / (EDITOR_START - CAPTURE_END))
        capture_scene(c, CAPTURE_END, show_window=False)
        editor = Canvas(language=language)
        editor_scene(editor, -1, show_window=False)
        blank = Canvas().image
        c.image = (Image.blend(c.image, blank, p * 2) if p < .5
                   else Image.blend(blank, editor.image, (p - .5) * 2))
        c.d = ImageDraw.Draw(c.image)
        bounds = tuple(a + (b - a) * p for a, b in zip(DESKTOP_WINDOW, SNAPSHOT_WINDOW))
        c.paste(example_window(language), bounds)
    else:
        editor_scene(c, t - EDITOR_START)
    header(c, "01", "截取一个窗口，写反馈，标注控件", "从目标应用到 OneShot：固定画面，引用控件，说明你想改什么。")
    active = 0 if t < EDITOR_START + .8 else 1 if t < EDITOR_START + 4.7 else 2 if t < EDITOR_START + 6.9 else 3
    captions = ["按 Control + Option + Command + S，采集完成后自动打开 OneShot。",
                "点击“引用控件”，点选保存和发布；R1 / R2 绑定到本次快照。",
                "写下具体修改意见；一条反馈可以同时引用多个控件。",
                "选择“控件”工具并点选按钮，填写这一个控件的修改意见。"]
    footer(c, ["截取窗口", "引用控件", "写下反馈", "标注控件"], active, captions[active])
    return c.finish()


def handoff(t, language="zh"):
    c = Canvas(language=language)
    header(c, "02", "把画面、反馈和上下文，一起交给 Agent", "首次连接一次；每次交付，只需粘贴一个固定版本的材料引用。")
    if t < 4:
        window(c, "OneShot / Agent 连接与材料")
        c.text(83, 253, "一次连接，持续交付", 27)
        c.text(83, 301, "使用已安装客户端的 CLI 配置本地 MCP。", 20, MUTED)
        for y, label in ((357, "Codex"), (453, "Claude Code")):
            c.box((82, y, 1118, y + 77), "#F6F8FC", 12, "#E0E7F0")
            c.text(107, y + 23, label, 23)
            c.text(393, y + 25, "用户级配置 · 本地材料库", 18, MUTED)
            c.box((839, y + 18, 1093, y + 59), BLUE, 9)
            c.text(857, y + 26, "连接到 " + label, 18, WHITE)
        c.text(84, 570, "选择你使用的客户端，连接后在客户端重新加载 MCP。", 19, MUTED)
    elif t < 9:
        window(c, "OneShot / 交给 Agent")
        c.box((80, 253, 340, 595), "#F0F5FC", 12)
        c.text(103, 279, "本次交付", 23)
        for y, label in ((337, "反馈与控件引用"), (383, "标注图 + 原图"), (429, "冻结 AX / OCR"), (475, "独立采集状态")):
            c.box((105, y + 6, 114, y + 15), BLUE, 4)
            c.text(128, y, label, 18)
        c.box((103, 530, 316, 575), BLUE, 8)
        c.text(153, 540, "交给 Agent", 19, WHITE)
        if t < 5.3:
            c.text(408, 330, "保存本次反馈的固定版本", 29)
            c.text(409, 391, "包含当前尚未保存的编辑内容。", 20, MUTED)
            c.cursor(254, 552, t >= 4.7)
        else:
            c.text(401, 266, "Agent 材料已准备好", 27)
            c.box((400, 323, 1108, 385), "#E9FAF3", 10)
            c.text(422, 337, "OS-0123456789AB@1", 28, "#147153")
            c.text(402, 409, "读取说明已复制到剪贴板", 23)
            c.text(402, 454, "将引用粘贴给已连接 OneShot MCP 的 Agent。", 19, MUTED)
            c.text(402, 500, "后续修改 → 再次交付 → 新版本 @2", 19, MUTED)
            c.text(402, 542, "旧引用仍指向原内容。", 18, MUTED)
    else:
        window(c, "Agent 对话 / 通用示意")
        c.box((74, 249, 1126, 345), "#F0F4FD", 12)
        c.text(96, 263, "你", 16, MUTED)
        message = c.label("请读取 OS-0123456789AB@1，按反馈调整按钮。")
        rate = len(message) / 1.5 if language == "en" else 32
        n = min(len(message), int((t - 9) * rate))
        c.text(96, 299, message[:n], 22)
        if t >= 11:
            c.box((75, 365, 1125, 418), "#E9FAF3", 10)
            c.text(97, 378, 'MCP  →  read_handoff("OS-0123456789AB@1")', 21, "#147153")
            for i, (title, detail) in enumerate((("你的意图", "反馈原文 + R1 / R2 引用"), ("画面证据", "标注预览 + 原始截图"), ("控件上下文", "冻结节点 + 采集状态"))):
                x = 75 + i * 356
                c.box((x, 438, x + 338, 556), "#F7F9FC", 12, "#DCE4EF")
                c.text(x + 20, 456, title, 23)
                c.text(x + 20, 504, detail, 17, MUTED)
            c.text(79, 582, "需要更多细节时，继续调用 read_details 或 read_image。", 19, MUTED)
    active = 0 if t < 4 else 1 if t < 5.3 else 2 if t < 9 else 3
    captions = ["连接修改选定客户端的配置并保留备份；“已配置”不代表 Agent 已读取。",
                "只有明确交付的内容进入材料库；采集草稿不会自动暴露。",
                "材料留在本机；点击交付不会自动向 Agent 发送消息。",
                "MCP 只读；Agent 客户端读取之后的数据处理由该客户端决定。"]
    footer(c, ["连接客户端", "交付快照", "复制引用", "粘贴并读取"], active, captions[active])
    return c.finish()


def render(name, draw, poster_time, output, seconds=14.5,
           palette_times=(0, 3.5, 6.5, 10.5, 14), palette_colors=(), frame_ms=100):
    frames = [draw(i / 10) for i in range(round(seconds * 10))]
    # One palette per animation prevents flickering at static edges.
    sheet = Image.new("RGB", (WIDTH, HEIGHT * len(palette_times)))
    for i, t in enumerate(palette_times):
        sheet.paste(frames[round(t * 10)], (0, HEIGHT * i))
    color_count = 128 - len(palette_colors)
    palette = sheet.quantize(colors=color_count, method=Image.Quantize.MEDIANCUT)
    if palette_colors:
        # Keep small, recognizable accents such as window controls from turning gray.
        accents = [channel for color in palette_colors for channel in ImageColor.getrgb(color)]
        palette.putpalette(palette.getpalette()[:color_count * 3] + accents)
    indexed = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
    durations = [frame_ms] * len(indexed)
    durations[-1] = 2600
    indexed[0].save(output / f"{name}.gif", save_all=True, append_images=indexed[1:],
                    duration=durations, loop=0, optimize=True, disposal=1)
    draw(poster_time).save(output / f"{name}.png", optimize=True)
    with Image.open(output / f"{name}.gif") as check:
        elapsed = 0
        for i in range(check.n_frames):
            check.seek(i)
            elapsed += check.info["duration"]
        assert check.size == (WIDTH, HEIGHT) and elapsed == sum(durations)
        assert check.info.get("loop") == 0
    print(f"{name}: {WIDTH}x{HEIGHT}, {elapsed / 1000:.1f}s, "
          f"{(output / (name + '.gif')).stat().st_size / 1024:.0f} KiB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path, default=Path("/System/Library/Fonts/PingFang.ttc"))
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "docs/media")
    parser.add_argument("--only", choices=("all", "annotate", "handoff"), default="all",
                        help="Render one workflow or both (default: all).")
    parser.add_argument("--language", choices=("all", "zh", "en"), default="all",
                        help="Render one language or both (default: all).")
    args = parser.parse_args()
    if not args.font.is_file():
        parser.error("CJK font not found; provide --font /path/to/font.ttf")
    global FONT_PATH
    FONT_PATH = str(args.font)
    args.output.mkdir(parents=True, exist_ok=True)
    languages = ("zh", "en") if args.language == "all" else (args.language,)
    for language in languages:
        suffix = ".en" if language == "en" else ""
        if args.only in ("all", "annotate"):
            render("annotate-workflow" + suffix, partial(annotate, language=language), 15.4,
                   args.output, seconds=15.5, palette_times=(0, 1.4, 3.2, 8, 14.8),
                   palette_colors=(MINT, BLUE, CORAL, "#FF6C63", "#FFC553", "#60CA79"), frame_ms=60)
        if args.only in ("all", "handoff"):
            accents = (MINT, BLUE, "#FF6C63", "#FFC553", "#60CA79") if language == "en" else ()
            render("agent-handoff-workflow" + suffix, partial(handoff, language=language), 13,
                   args.output, palette_colors=accents)


if __name__ == "__main__":
    main()
