#!/usr/bin/env python3
"""Render original, fictional workflow diagrams; never read captures or user data.

Requires Python 3.10+ and Pillow 10+. Defaults to macOS fonts; use --font for
another CJK TrueType/OpenType font. Output is GIF + static PNG, with no network.
"""
import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT, SCALE = 1200, 760, 1.5
BG = "#101B2C"
INK = "#17283D"
MUTED = "#64748B"
MINT = "#77E5C0"
BLUE = "#376AF5"
PALE = "#EBF1FF"
WHITE = "#FFFFFF"
FONT_PATH = ""
FONTS = {}


def font(size):
    if size not in FONTS:
        FONTS[size] = ImageFont.truetype(FONT_PATH, round(size * SCALE))
    return FONTS[size]


class Canvas:
    def __init__(self):
        self.image = Image.new("RGB", (round(WIDTH * SCALE), round(HEIGHT * SCALE)), BG)
        self.d = ImageDraw.Draw(self.image)

    def box(self, xy, fill, radius=12, outline=None, width=1):
        self.d.rounded_rectangle(tuple(round(v * SCALE) for v in xy), radius=round(radius * SCALE),
                                 fill=fill, outline=outline, width=round(width * SCALE))

    def text(self, x, y, value, size=20, fill=INK):
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

    def arrow(self, start, end, color=BLUE):
        self.line([start, end], color, 4)
        angle = math.atan2(end[1] - start[1], end[0] - start[0])
        pts = [end, (end[0] - 15 * math.cos(angle - .5), end[1] - 15 * math.sin(angle - .5)),
               (end[0] - 15 * math.cos(angle + .5), end[1] - 15 * math.sin(angle + .5))]
        self.line(pts, color, 4)

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
        c.text(x, 677, f"0{i + 1}  {title}", 18, MINT if i == active else "#90A4BF")
    c.text(38, 718, caption, 16, "#C2CFDF")
    c.text(950, 721, "流程示意 · 虚构数据", 14, "#90A4BF")


def window(c, title, xy=(36, 178, 1164, 638)):
    x, y, right, bottom = xy
    c.box((x, y + 7, right, bottom + 7), "#0A1320", 19)
    c.box(xy, WHITE, 16)
    c.box((x + 1, y + 1, right - 1, y + 47), "#F3F5F8", 15)
    c.box((x + 1, y + 24, right - 1, y + 47), "#F3F5F8", 0)
    for i, color in enumerate(("#FF6C63", "#FFC553", "#60CA79")):
        c.box((x + 17 + i * 20, y + 18, x + 28 + i * 20, y + 29), color, 6)
    c.text(x + 101, y + 11, title, 17, MUTED)


def annotate(t):
    c = Canvas()
    header(c, "01", "把“这里改一下”，变成明确的反馈", "固定窗口画面，引用真实控件，再补充你的意图。")
    window(c, "OneShot  /  反馈与标注")
    c.box((64, 240, 153, 273), PALE, 8)
    c.text(77, 244, "写反馈", 17, BLUE)
    c.text(174, 244, "控件    编号    箭头    方框    文字", 16, MUTED)
    c.box((1007, 237, 1141, 273), BLUE, 8)
    c.text(1028, 243, "交给 Agent", 17, WHITE)
    c.box((59, 288, 744, 614), "#EDF1F7", 11)
    c.box((82, 307, 720, 592), WHITE, 12, "#DAE2EC")
    c.text(104, 322, "示例应用 / 项目设置", 16, MUTED)
    c.line([(103, 356), (699, 356)], "#E5EAF1")
    c.text(107, 376, "发布你的下一个想法", 25)
    c.text(107, 416, "项目名称", 16, MUTED)
    c.box((106, 448, 694, 493), "#F7F9FC", 7, "#DAE2EC")
    c.text(121, 456, "Demo workspace", 18)
    c.box((438, 536, 548, 568), "#EFF2F7", 8)
    c.text(474, 538, "保存", 18)
    c.box((566, 528, 684, 568), BLUE, 8)
    c.text(604, 535, "发布", 18, WHITE)
    c.line([(763, 292), (763, 615)], "#DEE5EF")
    c.text(789, 294, "反馈", 18, BLUE)
    c.text(867, 294, "标注     控件树", 18, MUTED)
    c.text(789, 337, "反馈描述", 22)
    c.box((787, 377, 1137, 530), "#F9FBFF", 11, "#D7E1F1")
    c.text(803, 388, "描述想修改的地方", 15, MUTED)
    if t >= 3:
        c.box((432, 530, 554, 574), None, 10, BLUE, 3)
        c.badge(430, 509, "R1")
        c.badge(803, 424, "R1")
        c.text(851, 425, "保存", 18, BLUE)
    if t >= 5:
        c.box((560, 522, 690, 574), None, 10, BLUE, 3)
        c.badge(650, 501, "R2")
        c.text(900, 425, "与", 18)
        c.badge(935, 424, "R2")
        c.text(982, 425, "发布", 18, BLUE)
    if t >= 6.2:
        message = "统一按钮高度，保留主次样式。"
        c.text(804, 465, message[:max(0, min(len(message), int((t - 6.2) * 9)))], 19)
    c.text(802, 500, "引用控件       @ 搜索", 16, BLUE)
    if t < 3:
        c.text(803, 439, "点选画面中的控件…", 18, MUTED)
    if t >= 5:
        c.text(790, 548, "R1 · AXButton · 保存", 17, MUTED)
        c.text(790, 580, "R2 · AXButton · 发布", 17, MUTED)
    if t >= 10:
        c.arrow((335, 548), (420, 548))
        c.box((113, 523, 322, 570), "#FFF3DB", 9)
        c.text(128, 534, "对齐两侧按钮高度", 18, "#875D13")
    if 1.6 <= t < 4.3:
        p = min(1, max(0, (t - 1.6) / 1.2))
        c.cursor(819 + (490 - 819) * p, 510 + 37 * p, 3 <= t < 3.5)
    elif 4.3 <= t < 6.1:
        p = min(1, (t - 4.3) / .7)
        c.cursor(490 + 134 * p, 547, 5 <= t < 5.5)
    elif 10 <= t < 11:
        c.cursor(340, 548)
    active = 0 if t < 3 else 1 if t < 6.2 else 2 if t < 10 else 3
    captions = ["Ctrl + Option + Command + S 采集前台窗口；编辑的是冻结快照。", "从画面点选，或输入 @ 搜索；引用与截图双向定位。",
                "一条反馈可以引用多个控件，保留文字与引用的顺序。", "箭头、方框与文字补充视觉位置；R 编号绑定冻结控件。"]
    footer(c, ["采集窗口", "引用控件", "写清反馈", "补充标注"], active, captions[active])
    return c.finish()


def handoff(t):
    c = Canvas()
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
        message = "请读取 OS-0123456789AB@1，按反馈调整按钮。"
        n = min(len(message), int((t - 9) * 32))
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


def render(name, draw, poster_time, output):
    frames = [draw(i / 10) for i in range(145)]
    # One palette per animation prevents flickering at static edges.
    sheet = Image.new("RGB", (WIDTH, HEIGHT * 5))
    for i, index in enumerate((0, 35, 65, 105, 140)):
        sheet.paste(frames[index], (0, HEIGHT * i))
    palette = sheet.quantize(colors=128, method=Image.Quantize.MEDIANCUT)
    indexed = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
    durations = [100] * len(indexed)
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
    args = parser.parse_args()
    if not args.font.is_file():
        parser.error("CJK font not found; provide --font /path/to/font.ttf")
    global FONT_PATH
    FONT_PATH = str(args.font)
    args.output.mkdir(parents=True, exist_ok=True)
    render("annotate-workflow", annotate, 13, args.output)
    render("agent-handoff-workflow", handoff, 13, args.output)


if __name__ == "__main__":
    main()
