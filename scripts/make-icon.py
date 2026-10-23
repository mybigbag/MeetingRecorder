#!/usr/bin/env python3
"""生成应用图标（.icns）。

设计约束（与项目视觉基调一致）：
  - 只用黑白灰，**没有渐变**，没有阴影，没有描边
  - 造型语言是「两条独立的波形轨」——这正是本工具的核心设计
    （音轨即说话人身份：上面一条是你，下面一条是对方）
  - 所有尺寸从一张 1024 的超采样图缩放，避免小尺寸自己糊掉

用法：
  python3 scripts/make-icon.py            # 生成 app/AppIcon.icns
"""

import os
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("需要 Pillow：/usr/bin/python3 -m pip install --user pillow")

# macOS 图标外形的圆角比例（Apple 的 squircle 近似值）
CORNER_RATIO = 0.2237
SUPERSAMPLE = 4          # 先按 4 倍画再缩，边缘才干净

BACKGROUND = (44, 44, 46, 255)      # #2C2C2E 深灰
TOP_TRACK = (255, 255, 255, 255)    # 「我」：纯白
BOTTOM_TRACK = (255, 255, 255, 145)  # 「对方」：半透明白，形成主次

# 每组的竖条高度（相对边长），中间高两侧低——读起来就是一段声波
TOP_HEIGHTS = [0.095, 0.180, 0.250, 0.160, 0.085]
BOTTOM_HEIGHTS = [0.085, 0.160, 0.250, 0.180, 0.095]

BAR_WIDTH = 0.075
BAR_PITCH = 0.112        # 相邻竖条中心距
# 两组之间留出可见的空隙（0.054 边长）。挨得太近会连成一个图形，
# 就看不出「这是两条独立的轨」——而那正是这个图标要说的意思。
TOP_CENTER_Y = 0.348
BOTTOM_CENTER_Y = 0.652


def draw_icon(pixel_size: int) -> Image.Image:
    """在 pixel_size × pixel_size 上绘制（该尺寸已含超采样倍率）。"""
    size = pixel_size
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # 底：圆角方形
    radius = CORNER_RATIO * size
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=BACKGROUND)

    bar_width = BAR_WIDTH * size
    pitch = BAR_PITCH * size
    count = len(TOP_HEIGHTS)
    # 让整组水平居中
    first_center = size / 2 - pitch * (count - 1) / 2

    def draw_track(heights, center_y, color):
        for index, ratio in enumerate(heights):
            center_x = first_center + pitch * index
            half_height = ratio * size / 2
            left = center_x - bar_width / 2
            top = center_y * size - half_height
            right = center_x + bar_width / 2
            bottom = center_y * size + half_height
            # 胶囊形（圆角＝半宽），和整体造型语言一致
            draw.rounded_rectangle(
                [left, top, right, bottom], radius=bar_width / 2, fill=color)

    draw_track(TOP_HEIGHTS, TOP_CENTER_Y, TOP_TRACK)
    draw_track(BOTTOM_HEIGHTS, BOTTOM_CENTER_Y, BOTTOM_TRACK)

    return image


def build() -> str:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    app_dir = os.path.join(root, "app")
    iconset_dir = os.path.join(app_dir, "AppIcon.iconset")
    icns_path = os.path.join(app_dir, "AppIcon.icns")

    os.makedirs(iconset_dir, exist_ok=True)

    # 一次画到最大尺寸，再向下缩放：比每个尺寸各画一遍更干净
    master_size = 1024 * SUPERSAMPLE
    master = draw_icon(master_size).resize((1024, 1024), Image.LANCZOS)

    # iconutil 要求的固定文件名
    variants = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for name, dim in variants:
        resized = master if dim == 1024 else master.resize((dim, dim), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, name))

    subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        check=True)

    # 留一张预览图方便肉眼检查（不进 bundle）
    master.save(os.path.join(app_dir, "AppIcon-preview.png"))

    print(f"✅ 已生成 {icns_path}")
    print(f"   预览：{os.path.join(app_dir, 'AppIcon-preview.png')}")
    return icns_path


if __name__ == "__main__":
    build()
