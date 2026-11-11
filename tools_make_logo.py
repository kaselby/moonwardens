# Draws the CurseForge project logo (400x400 PNG): silver crescent moon on a
# night-blue disc with a gold ring, a few stars. Run with any Python with Pillow.
from PIL import Image, ImageDraw, ImageFilter
import math, os, random
S = 1600  # draw big, scale down for smooth edges
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "curseforge", "logo.png")

im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# background: rounded square, deep blue to near-black radial glow
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(bg)
d.rounded_rectangle((0, 0, S - 1, S - 1), radius=220, fill=(10, 12, 28, 255))
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((300, 260, 1300, 1260), fill=(48, 62, 120, 255))
glow = glow.filter(ImageFilter.GaussianBlur(220))
bg.alpha_composite(Image.composite(glow, Image.new("RGBA", (S, S)), bg.split()[3]))
im.alpha_composite(bg)
d = ImageDraw.Draw(im)
# stars
random.seed(7)
for _ in range(38):
    x, y = random.randint(140, S - 140), random.randint(140, S - 140)
    if (x - S / 2) ** 2 + (y - S / 2) ** 2 < 560 ** 2: continue
    r = random.choice([5, 6, 8, 10, 13])
    a = random.randint(140, 255)
    d.ellipse((x - r, y - r, x + r, y + r), fill=(220, 225, 255, a))
# gold ring
c, R = S / 2, 560
d.ellipse((c - R, c - R, c + R, c + R), outline=(214, 170, 60, 255), width=46)
d.ellipse((c - R + 60, c - R + 60, c + R - 60, c + R - 60), outline=(120, 92, 30, 255), width=10)
# crescent: full moon minus an offset disc, with a soft glow
moon = Image.new("L", (S, S), 0)
dm = ImageDraw.Draw(moon)
mr = 380
mx, my = c - 40, c
dm.ellipse((mx - mr, my - mr, mx + mr, my + mr), fill=255)
dm.ellipse((mx - mr + 230, my - mr - 70, mx + mr + 230, my + mr - 70), fill=0)
halo = Image.new("RGBA", (S, S), (200, 215, 255, 0))
halo.putalpha(moon.filter(ImageFilter.GaussianBlur(50)).point(lambda v: int(v * 0.55)))
im.alpha_composite(halo)
face = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shade = Image.linear_gradient("L").rotate(-35, expand=False).resize((S, S))
light = Image.merge("RGBA", (shade.point(lambda v: 205 + v * 50 // 255),
                             shade.point(lambda v: 210 + v * 45 // 255),
                             shade.point(lambda v: 228 + v * 27 // 255), moon))
im.alpha_composite(light)
im = im.resize((400, 400), Image.LANCZOS)
im.save(OUT)
print("wrote", OUT)
