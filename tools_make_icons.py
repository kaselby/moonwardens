# Draws the alert button art (red megaphone, red rounded-square border) as
# 64x64 TGA for WoW. Run with any Python that has Pillow.
from PIL import Image, ImageDraw, ImageFilter
import math, os
S = 512
OUT = os.path.join(os.path.dirname(__file__), "Moonwardens", "media")

def rounded(draw, box, r, **kw):
    draw.rounded_rectangle(box, radius=r, **kw)

def icon():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # body: dark red-black, then the red border on top
    rounded(d, (8, 8, S - 8, S - 8), 84, fill=(30, 8, 8, 255))
    inner = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    di = ImageDraw.Draw(inner)
    rounded(di, (8, 8, S - 8, S - 8), 84, fill=(70, 14, 12, 255))
    inner = inner.filter(ImageFilter.GaussianBlur(40))
    im.alpha_composite(Image.composite(inner, Image.new("RGBA", (S, S)), im.split()[3]))
    d = ImageDraw.Draw(im)
    rounded(d, (8, 8, S - 8, S - 8), 84, outline=(210, 30, 24, 255), width=34)
    rounded(d, (40, 40, S - 40, S - 40), 58, outline=(110, 14, 12, 255), width=6)
    # megaphone, pointing right
    red, hi = (232, 44, 34, 255), (255, 120, 100, 255)
    cy = 250
    d.rounded_rectangle((100, cy - 38, 172, cy + 38), radius=14, fill=red)          # mouthpiece
    d.polygon([(166, cy - 46), (316, cy - 120), (316, cy + 120), (166, cy + 46)], fill=red)  # cone
    d.ellipse((290, cy - 124, 342, cy + 124), fill=red)                               # bell rim
    d.ellipse((304, cy - 100, 334, cy + 100), fill=(150, 20, 16, 255))                # bell opening
    d.polygon([(190, cy + 40), (226, cy + 30), (246, cy + 118), (210, cy + 128)], fill=red)  # handle
    d.line([(178, cy - 52), (300, cy - 112)], fill=hi, width=10)                      # highlight
    # sound waves
    for r, w in ((70, 20), (118, 20)):
        d.arc((330 - r, cy - r, 330 + r, cy + r), -38, 38, fill=red, width=w)
    return im.resize((64, 64), Image.LANCZOS)

def glow():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    rounded(d, (40, 40, S - 40, S - 40), 90, outline=(255, 90, 40, 255), width=50)
    im = im.filter(ImageFilter.GaussianBlur(22))
    return im.resize((64, 64), Image.LANCZOS)

os.makedirs(OUT, exist_ok=True)
def diamond():
    im = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    ImageDraw.Draw(im).polygon([(S / 2, 4), (S - 4, S / 2), (S / 2, S - 4), (4, S / 2)], fill=(255, 255, 255, 255))
    return im.resize((64, 64), Image.LANCZOS)

def ring():
    im = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((8, 8, S - 8, S - 8), fill=(255, 255, 255, 255))
    d.ellipse((92, 92, S - 92, S - 92), fill=(255, 255, 255, 0))
    return im.resize((64, 64), Image.LANCZOS)

diamond().save(os.path.join(OUT, "diamond.tga"), compression=None)   # guildie dots (tinted)
ring().save(os.path.join(OUT, "ring.tga"), compression=None)         # group member rings (tinted)
icon().save(os.path.join(OUT, "alert.tga"), compression=None)
glow().save(os.path.join(OUT, "alert_glow.tga"), compression=None)
icon().resize((256, 256), Image.NEAREST).save("/tmp/alert_preview.png")
print("ok")
