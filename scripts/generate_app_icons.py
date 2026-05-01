"""Generate four alternative WatchNext launcher icons.

Originals at `mipmap-*/ic_launcher.png` are NOT touched (the user wants
"Classic" preserved as one option).

Outputs per density:
  ic_launcher_vivid.png    — high-contrast film reel (fixes black-on-black)
  ic_launcher_minimal.png  — solid accent + clean play triangle
  ic_launcher_clapper.png  — clapperboard slate
  ic_launcher_cream.png    — Classic base, cream perforated strips + cream
                             reel holes (visual sibling to Classic)

Plus 512px previews under `assets/icons/` so the in-app settings picker
can render them without poking native resources.
"""
from __future__ import annotations
import math
import os
import shutil
from PIL import Image, ImageDraw, ImageFilter

ROOT = "/home/ubuntu/projects/watchnext"
RES = os.path.join(ROOT, "android/app/src/main/res")
ASSETS = os.path.join(ROOT, "assets/icons")
os.makedirs(ASSETS, exist_ok=True)

MIPMAPS = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

# ════════════════════════════ helpers ══════════════════════════════════════
def round_mask(size: int, radius_frac: float = 0.18) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=int(size * radius_frac), fill=255
    )
    return m


def radial_bg(size: int, top: tuple, bot: tuple, gamma: float = 1.4) -> Image.Image:
    img = Image.new("RGB", (size, size), bot)
    px = img.load()
    cx = cy = size / 2
    rmax = math.hypot(cx, cy)
    for y in range(size):
        for x in range(size):
            t = (math.hypot(x - cx, y - cy) / rmax) ** gamma
            px[x, y] = (
                int(top[0] * (1 - t) + bot[0] * t),
                int(top[1] * (1 - t) + bot[1] * t),
                int(top[2] * (1 - t) + bot[2] * t),
            )
    return img


def soft_glow(canvas: Image.Image, cx: int, cy: int, r: int,
              color: tuple, alpha: int = 80, blur: float | None = None) -> None:
    g = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse(
        (cx - r, cy - r, cx + r, cy + r), fill=(*color[:3], alpha)
    )
    g = g.filter(ImageFilter.GaussianBlur(radius=blur or r * 0.18))
    canvas.alpha_composite(g)


# ════════════════════════════ Vivid ═══════════════════════════════════════
def render_vivid(size: int = 1024) -> Image.Image:
    BG_TOP = (16, 22, 42)
    BG_BOTTOM = (8, 10, 22)
    STRIP = (58, 62, 76)         # mid-grey film strip — clear vs background
    SPROCKET = (244, 240, 220)   # warm cream holes
    GOLD = (250, 196, 80)
    GOLD_HI = (255, 220, 120)
    GOLD_LO = (170, 110, 30)
    HUB = (220, 60, 56)
    HUB_HI = (255, 140, 130)

    bg = radial_bg(size, BG_TOP, BG_BOTTOM).convert("RGBA")
    d = ImageDraw.Draw(bg, "RGBA")

    # film strips top + bottom with sprocket holes (two rows each)
    strip_h = int(size * 0.155)
    for y_top in (0, size - strip_h):
        d.rectangle((0, y_top, size, y_top + strip_h), fill=STRIP)
        n = 8
        hole_w = int(size * 0.085)
        hole_h = int(strip_h * 0.30)
        inset_y = int(strip_h * 0.13)
        pad = (size - n * hole_w) / (n + 1)
        for i in range(n):
            x = int(pad + i * (hole_w + pad))
            for row_y in (y_top + inset_y, y_top + strip_h - inset_y - hole_h):
                d.rounded_rectangle(
                    (x, row_y, x + hole_w, row_y + hole_h),
                    radius=hole_h // 3, fill=SPROCKET,
                )

    # central reel
    cx = cy = size // 2
    R = int(size * 0.34)
    soft_glow(bg, cx, cy, int(R * 1.18), GOLD, alpha=80)
    d.ellipse((cx - R, cy - R, cx + R, cy + R), fill=GOLD,
              outline=GOLD_LO, width=int(R * 0.10))
    inner = int(R * 0.86)
    d.ellipse((cx - inner, cy - inner, cx + inner, cy + inner),
              outline=GOLD_HI, width=max(2, int(R * 0.025)))

    # 6 drilled holes (showing the dark backdrop) with rim shadow
    n = 6
    hr = int(R * 0.18)
    orbit = int(R * 0.55)
    for i in range(n):
        a = 2 * math.pi * i / n - math.pi / 2
        x = cx + int(orbit * math.cos(a))
        y = cy + int(orbit * math.sin(a))
        d.ellipse((x - hr, y - hr, x + hr, y + hr),
                  fill=(0, 0, 0, 255), outline=GOLD_LO,
                  width=max(2, int(R * 0.022)))

    # hub: dark ring + red spindle + glossy highlight
    hub_r = int(R * 0.28)
    d.ellipse((cx - hub_r, cy - hub_r, cx + hub_r, cy + hub_r),
              fill=(20, 18, 30, 255), outline=GOLD_LO,
              width=max(2, int(R * 0.025)))
    sp_r = int(R * 0.14)
    d.ellipse((cx - sp_r, cy - sp_r, cx + sp_r, cy + sp_r), fill=HUB)
    sh_r = int(sp_r * 0.45)
    d.ellipse((cx - sh_r - 3, cy - sh_r - 6,
               cx - sh_r + sh_r + 3, cy - sh_r + sh_r),
              fill=(*HUB_HI, 230))

    # tiny play triangle baked into the spindle
    s = int(R * 0.085)
    d.polygon(
        [(cx - s + 2, cy - int(s * 1.05)),
         (cx - s + 2, cy + int(s * 1.05)),
         (cx + int(s * 1.25), cy)],
        fill=(255, 248, 230, 255),
    )

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), round_mask(size))
    return out


# ════════════════════════════ Minimal ═════════════════════════════════════
def render_minimal(size: int = 1024) -> Image.Image:
    """Solid violet square, large white play triangle. Modern + flat."""
    BG_TOP = (118, 70, 220)      # violet — matches one of the AppAccent seeds
    BG_BOTTOM = (78, 36, 170)
    bg = radial_bg(size, BG_TOP, BG_BOTTOM, gamma=1.2).convert("RGBA")
    d = ImageDraw.Draw(bg, "RGBA")

    # Soft inner ring for depth
    cx = cy = size // 2
    R = int(size * 0.40)
    d.ellipse(
        (cx - R, cy - R, cx + R, cy + R),
        outline=(255, 255, 255, 50),
        width=int(size * 0.012),
    )

    # White play triangle — slightly offset right for optical centering
    s = int(size * 0.22)
    pts = [
        (cx - int(s * 0.55), cy - s),
        (cx - int(s * 0.55), cy + s),
        (cx + int(s * 1.05), cy),
    ]
    # subtle drop shadow
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.polygon([(p[0] + 6, p[1] + 10) for p in pts], fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.012))
    bg.alpha_composite(shadow)

    d.polygon(pts, fill=(255, 255, 255, 255))

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), round_mask(size))
    return out


# ════════════════════════════ Clapper ═════════════════════════════════════
def render_clapper(size: int = 1024) -> Image.Image:
    """Clapperboard slate. Top half = striped clapper arm, bottom = chalk slate."""
    BG = (30, 30, 36)
    SLATE = (28, 30, 38)
    SLATE_LINE = (62, 64, 74)
    BLACK = (24, 24, 28)
    WHITE = (244, 240, 220)
    GOLD = (250, 196, 80)

    bg = Image.new("RGBA", (size, size), (*BG, 255))
    d = ImageDraw.Draw(bg, "RGBA")

    # subtle radial background
    rg = radial_bg(size, (40, 40, 50), BG, gamma=1.1)
    bg.paste(rg, (0, 0))
    d = ImageDraw.Draw(bg, "RGBA")

    # Slate (bottom 2/3) — dark with chalk lines
    slate_top = int(size * 0.36)
    d.rectangle((0, slate_top, size, size), fill=SLATE)
    chalk_y = slate_top + int(size * 0.10)
    for k in range(4):
        ly = chalk_y + k * int(size * 0.135)
        d.rectangle(
            (int(size * 0.10), ly,
             int(size * 0.90), ly + max(2, int(size * 0.012))),
            fill=SLATE_LINE,
        )

    # Clapper arm (top ~1/3) — angled rectangle with B/W stripes
    # Use a sub-image we rotate slightly so the arm tilts up from left to right
    arm_h = int(size * 0.30)
    arm_w = int(size * 1.05)
    arm = Image.new("RGBA", (arm_w, arm_h), (*WHITE, 255))
    ad = ImageDraw.Draw(arm)
    n_stripes = 8
    sw = arm_w / n_stripes
    for i in range(n_stripes):
        if i % 2 == 0:
            ad.polygon(
                [(int(i * sw), 0),
                 (int((i + 1) * sw + arm_h * 0.4), 0),
                 (int((i + 1) * sw - arm_h * 0.4), arm_h),
                 (int(i * sw - arm_h * 0.4), arm_h)],
                fill=(*BLACK, 255),
            )
    arm = arm.rotate(-8, resample=Image.BICUBIC, expand=True)

    # Position the arm at the top
    bg.alpha_composite(arm, (-int((arm.width - size) / 2),
                             int(size * 0.05)))
    d = ImageDraw.Draw(bg, "RGBA")  # rebind

    # Hinge dot where the arm meets the slate
    hx = int(size * 0.16)
    hy = int(size * 0.36)
    hr = int(size * 0.022)
    d.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=(*GOLD, 255))

    # "WN" letterform on the slate
    # No font dependency — draw two stylised glyphs as polygons
    bx = int(size * 0.18)
    by = int(size * 0.55)
    bh = int(size * 0.25)
    bw = int(size * 0.12)
    # W
    sx = bw / 4
    d.line(
        [(bx, by), (bx + sx, by + bh),
         (bx + sx * 2, by + bh * 0.4),
         (bx + sx * 3, by + bh),
         (bx + sx * 4, by)],
        fill=(*GOLD, 255),
        width=int(size * 0.020),
    )
    # N
    nx = int(size * 0.55)
    d.line(
        [(nx, by + bh), (nx, by),
         (nx + bw, by + bh),
         (nx + bw, by)],
        fill=(*GOLD, 255),
        width=int(size * 0.020),
    )

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), round_mask(size))
    return out


# ════════════════════════════ Cream ══════════════════════════════════════
def render_cream(size: int = 1024) -> Image.Image:
    """Take the EXISTING Classic icon untouched and recolor only the top +
    bottom bars from dark to cream. The reel and the rest of the design are
    pixel-preserved.

    Strategy: load Classic at its largest available density, upscale to the
    working size, scan vertically to find the strip Y-bounds (rows that
    carry both dark and bright pixels — the perforated film-strip
    signature), then for pixels INSIDE those bounds remap brightness
    linearly from (dark→cream, bright→dark navy). Antialiased edges fall on
    the gradient between the two so they keep their soft-stop quality.
    Pixels outside the strip rows are left exactly as they were.
    """
    classic_path = os.path.join(RES, "mipmap-xxxhdpi", "ic_launcher.png")
    src = Image.open(classic_path).convert("RGBA")
    img = src.resize((size, size), Image.LANCZOS)
    px = img.load()
    w, h = img.size

    CREAM = (240, 226, 188)
    DARK = (12, 16, 32)

    def row_variance(y: int) -> float:
        """Spread between brightest and darkest visible pixel in row y.
        Strip rows have BOTH dark bar bg AND bright sprocket holes, so the
        spread is large; pure-bg rows below the strip have a small spread."""
        lo = 255.0
        hi = 0.0
        for x in range(0, w, 4):
            r, g, b, a = px[x, y]
            if a < 32:
                continue
            br = (r + g + b) / 3
            if br < lo:
                lo = br
            if br > hi:
                hi = br
        return hi - lo

    # Walk down from the top, mark every high-variance row as "strip".
    # Stop as soon as we hit a stable run of low-variance rows (the
    # bg-with-reel area). Mirror for the bottom.
    threshold = 110.0
    top_end = 0
    quiet_run = 0
    for y in range(h // 3):
        if row_variance(y) > threshold:
            top_end = y
            quiet_run = 0
        else:
            quiet_run += 1
            if quiet_run > int(h * 0.02):
                break
    bottom_start = h
    quiet_run = 0
    for y in range(h - 1, h * 2 // 3, -1):
        if row_variance(y) > threshold:
            bottom_start = y
            quiet_run = 0
        else:
            quiet_run += 1
            if quiet_run > int(h * 0.02):
                break
    # Defensive fallback if the heuristic mismeasured (image lacks the
    # expected strip pattern at this density — shouldn't happen for the
    # Classic asset, but better than crashing the build).
    if top_end == 0 or bottom_start == h:
        top_end = int(h * 0.155)
        bottom_start = h - int(h * 0.155)

    def remap(p):
        r, g, b, a = p
        if a == 0:
            return p
        t = (r + g + b) / 3 / 255  # 0=dark, 1=bright
        return (
            int(CREAM[0] * (1 - t) + DARK[0] * t),
            int(CREAM[1] * (1 - t) + DARK[1] * t),
            int(CREAM[2] * (1 - t) + DARK[2] * t),
            a,
        )

    for y in range(top_end + 1):
        for x in range(w):
            px[x, y] = remap(px[x, y])
    for y in range(bottom_start, h):
        for x in range(w):
            px[x, y] = remap(px[x, y])

    return img


# ════════════════════════════ writers ═════════════════════════════════════
def write_mipmaps(master: Image.Image, name: str) -> None:
    for density, px in MIPMAPS.items():
        path = os.path.join(RES, f"mipmap-{density}", f"{name}.png")
        master.resize((px, px), Image.LANCZOS).save(path, optimize=True)
        print(f"wrote {path} ({px}x{px})")


def main() -> None:
    variants = [
        ("ic_launcher_vivid", render_vivid()),
        ("ic_launcher_minimal", render_minimal()),
        ("ic_launcher_clapper", render_clapper()),
        ("ic_launcher_cream", render_cream()),
    ]
    for name, master in variants:
        write_mipmaps(master, name)
        master.resize((512, 512), Image.LANCZOS).save(
            os.path.join(ASSETS, f"{name}.png"), optimize=True
        )

    # Also stash a 512px copy of the ORIGINAL (Classic) for the in-app picker.
    orig = Image.open(os.path.join(RES, "mipmap-xxxhdpi", "ic_launcher.png"))
    orig.resize((512, 512), Image.LANCZOS).save(
        os.path.join(ASSETS, "ic_launcher_classic.png"), optimize=True
    )
    print(f"wrote {os.path.join(ASSETS, 'ic_launcher_classic.png')} (512x512)")


if __name__ == "__main__":
    main()
