"""生成 TodoList 应用图标（1024x1024）。

- background.png : 蓝色对角渐变，用于 Android 自适应图标背景
- foreground.png : 透明底 + 白色圆形徽标 + 勾，用于自适应图标前景
- icon.png       : 圆角方块完整图标（商店/旧版启动器用）

品牌色（与 App 设计 token 一致）：
  深蓝 #0061A4 -> 亮蓝 #4DA3FF
"""
import numpy as np
from PIL import Image, ImageDraw

S = 1024
R = 220  # 圆角半径（仅 icon.png 用）
C1 = np.array([0, 97, 164])    # #0061A4
C2 = np.array([77, 163, 255])  # #4DA3FF

# ---- 对角渐变 ----
xs = np.linspace(0, 1, S)
ys = np.linspace(0, 1, S)
gx, gy = np.meshgrid(xs, ys)
t = (gx + gy) / 2.0  # 左上(0)->右下(1)
grad = (C1[None, None, :] * (1 - t[..., None]) + C2[None, None, :] * t[..., None]).astype(np.uint8)
grad_img = Image.fromarray(grad, "RGB").convert("RGBA")


def rounded_alpha(size, r):
    """生成圆角矩形 alpha 蒙版（圆角外透明）。"""
    a = Image.new("L", (size, size), 255)
    d = ImageDraw.Draw(a)
    d.polygon([(0, 0), (size, 0), (size, size), (0, size)], fill=255)
    # 四个角裁掉
    d.pieslice([0, 0, 2 * r, 2 * r], 90, 180, fill=0)
    d.pieslice([size - 2 * r, 0, size, 2 * r], 0, 90, fill=0)
    d.pieslice([0, size - 2 * r, 2 * r, size], 180, 270, fill=0)
    d.pieslice([size - 2 * r, size - 2 * r, size, size], 270, 360, fill=0)
    return a


def draw_badge_and_check(img):
    d = ImageDraw.Draw(img, "RGBA")
    cx, cy = 512, 512
    # 白色圆形徽标
    r = 300
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 235))
    # 勾：两段粗线 + 圆角端点
    w = 74
    p1 = (cx - 135, cy - 8)
    p2 = (cx - 35, cy + 98)
    p3 = (cx + 178, cy - 128)
    d.line([p1, p2, p3], fill=(0, 97, 164, 255), width=w, joint="curve")
    for p in (p1, p3):
        d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2],
                  fill=(0, 97, 164, 255))
    return img


# ---- background.png（自适应背景，无圆角）----
bg = grad_img.copy()
bg.save("assets/icon/background.png")

# ---- foreground.png（透明底 + 徽标 + 勾）----
fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw_badge_and_check(fg)
fg.save("assets/icon/foreground.png")

# ---- icon.png（圆角方块完整图标）----
icon = grad_img.copy()
mask = rounded_alpha(S, R)
icon.putalpha(mask)
draw_badge_and_check(icon)
# 顶部高光，增加立体感
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
hd.rounded_rectangle([40, 40, S - 40, 360], radius=180, fill=(255, 255, 255, 28))
icon = Image.alpha_composite(icon, hl)
icon.save("assets/icon/icon.png")

print("generated: icon.png, foreground.png, background.png (1024x1024)")
