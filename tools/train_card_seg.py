#!/usr/bin/env python3
"""
StereoCardSeg (v2): 19世紀ステレオカードの台紙 vs 写真窓 (2クラス) を
セグメンテーションする軽量 CoordConv U-Net の合成データ学習 & Core ML (.mlpackage) 変換スクリプト。
"""

import argparse
import glob
import os
import random
import time
import warnings

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageFilter
from torch.utils.data import DataLoader, TensorDataset

warnings.filterwarnings("ignore")

IMG_W = 512
IMG_H = 256


# ==============================================================================
# 1. 軽量 CoordConv U-Net モデル (2クラス: 0=台紙/背景, 1=写真窓)
# ==============================================================================
class ConvBlock(nn.Module):
    def __init__(self, in_ch: int, out_ch: int):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
        )

    def forward(self, x):
        return self.net(x)


class StereoCardUNet(nn.Module):
    def __init__(self, base_ch: int = 20, num_classes: int = 2):
        super().__init__()
        # 絶対座標 (x, y in [-1, 1]) をモデル内部で連結する CoordConv
        xs = torch.linspace(-1.0, 1.0, IMG_W).view(1, 1, 1, IMG_W).expand(1, 1, IMG_H, IMG_W)
        ys = torch.linspace(-1.0, 1.0, IMG_H).view(1, 1, IMG_H, 1).expand(1, 1, IMG_H, IMG_W)
        self.register_buffer("coords", torch.cat([xs, ys], dim=1))

        self.enc1 = ConvBlock(5, base_ch)
        self.enc2 = ConvBlock(base_ch, base_ch * 2)
        self.enc3 = ConvBlock(base_ch * 2, base_ch * 4)
        self.enc4 = ConvBlock(base_ch * 4, base_ch * 8)

        self.pool = nn.MaxPool2d(2)

        self.dec3 = ConvBlock(base_ch * 8 + base_ch * 4, base_ch * 4)
        self.dec2 = ConvBlock(base_ch * 4 + base_ch * 2, base_ch * 2)
        self.dec1 = ConvBlock(base_ch * 2 + base_ch, base_ch)

        self.head = nn.Conv2d(base_ch, num_classes, kernel_size=1)

    def forward(self, x):
        coords = x[:, :2, :, :] * 0.0 + self.coords
        x_in = torch.cat([x, coords], dim=1)

        e1 = self.enc1(x_in)
        e2 = self.enc2(self.pool(e1))
        e3 = self.enc3(self.pool(e2))
        b = self.enc4(self.pool(e3))

        d3 = F.interpolate(b, scale_factor=2.0, mode="bilinear", align_corners=False)
        d3 = self.dec3(torch.cat([d3, e3], dim=1))

        d2 = F.interpolate(d3, scale_factor=2.0, mode="bilinear", align_corners=False)
        d2 = self.dec2(torch.cat([d2, e2], dim=1))

        d1 = F.interpolate(d2, scale_factor=2.0, mode="bilinear", align_corners=False)
        d1 = self.dec1(torch.cat([d1, e1], dim=1))

        return self.head(d1)


# ==============================================================================
# 2. 実カード画像からのテクスチャ & 台紙色サンプラー + 事前生成合成データセット
# ==============================================================================
def load_source_patches_and_card_colors(data_dir: str):
    exts = ("*.jpg", "*.jpeg", "*.png", "*.tif", "*.tiff", "*.webp")
    paths = []
    for ext in exts:
        paths.extend(glob.glob(os.path.join(data_dir, ext)))
    paths = sorted(paths)
    if not paths:
        raise RuntimeError(f"学習用画像が見つかりません: {data_dir}")

    photo_patches = []
    card_colors = [
        (235, 205, 145),
        (220, 185, 125),
        (242, 238, 225),
        (25, 25, 23),
        (75, 72, 68),
        (170, 85, 60),
    ]

    for p in paths:
        try:
            with Image.open(p) as im:
                im = im.convert("RGB")
                w, h = im.size
                # 通常パッチ (中央)
                left_crop = im.crop((int(w * 0.12), int(h * 0.15), int(w * 0.45), int(h * 0.85)))
                right_crop = im.crop((int(w * 0.55), int(h * 0.15), int(w * 0.88), int(h * 0.85)))
                photo_patches.append(left_crop.resize((256, 256), Image.Resampling.BILINEAR))
                photo_patches.append(right_crop.resize((256, 256), Image.Resampling.BILINEAR))

                # 上部・下部を含むフルウィンドウパッチ (月・天体カードの宇宙空間やアーチ頂点を含む)
                left_full = im.crop((int(w * 0.08), int(h * 0.03), int(w * 0.48), int(h * 0.95)))
                right_full = im.crop((int(w * 0.52), int(h * 0.03), int(w * 0.92), int(h * 0.95)))
                photo_patches.append(left_full.resize((256, 256), Image.Resampling.BILINEAR))
                photo_patches.append(right_full.resize((256, 256), Image.Resampling.BILINEAR))

                arr = np.asarray(im.resize((128, 64), Image.Resampling.BILINEAR))
                border = np.concatenate([arr[:3].reshape(-1, 3), arr[-3:].reshape(-1, 3)], axis=0)
                med = np.median(border, axis=0).astype(int)
                card_colors.append((int(med[0]), int(med[1]), int(med[2])))
        except Exception as e:
            print(f"[Warn] スキップ {os.path.basename(p)}: {e}")

    # 暗い宇宙・夜空パッチ（月カード等の天体写真用）を明示的に追加
    for _ in range(8):
        space_arr = np.random.normal(32, 4, (256, 256, 3)).clip(18, 55).astype(np.uint8)
        # ランダムな月球体（直径 100〜180px）を配置
        sp_img = Image.fromarray(space_arr)
        sp_draw = ImageDraw.Draw(sp_img)
        cx, cy = random.randint(100, 156), random.randint(100, 156)
        cr = random.randint(55, 95)
        moon_luma = random.randint(110, 190)
        sp_draw.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=(moon_luma, moon_luma, int(moon_luma * 0.92)))
        photo_patches.append(sp_img)

    print(f"[Data] {len(paths)} 枚のカードから {len(photo_patches)} パッチ・{len(card_colors)} 台紙色を抽出")
    return photo_patches, card_colors


def make_arch_window_mask(w: int, h: int, shape_type: str, rx_ratio: float, ry_ratio: float) -> Image.Image:
    mask = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(mask)
    if shape_type == "rect":
        draw.rectangle([0, 0, w - 1, h - 1], fill=255)
    elif shape_type == "rounded":
        r = max(2, int(min(w, h) * rx_ratio))
        draw.rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    else:
        r_bot = max(2, int(min(w, h) * 0.08))
        arch_h = max(6, int(h * ry_ratio))
        draw.rounded_rectangle([0, arch_h // 2, w - 1, h - 1], radius=r_bot, fill=255)
        draw.pieslice([0, 0, w - 1, arch_h * 2], start=180, end=360, fill=255)
    return mask


def generate_synthetic_tensors(patches, card_colors, count: int):
    t0 = time.time()
    imgs = np.empty((count, 3, IMG_H, IMG_W), dtype=np.uint8)
    lbls = np.empty((count, IMG_H, IMG_W), dtype=np.uint8)

    for idx in range(count):
        rng = random.Random(idx * 9973 + 42)
        base_col = rng.choice(card_colors)
        card_arr = np.zeros((IMG_H, IMG_W, 3), dtype=np.float32)
        card_arr[:, :, 0] = np.clip(base_col[0] + rng.uniform(-12, 12), 0, 255)
        card_arr[:, :, 1] = np.clip(base_col[1] + rng.uniform(-12, 12), 0, 255)
        card_arr[:, :, 2] = np.clip(base_col[2] + rng.uniform(-12, 12), 0, 255)

        noise = np.random.normal(0, rng.uniform(1.5, 6.0), (IMG_H, IMG_W, 3)).astype(np.float32)
        card_arr = np.clip(card_arr + noise, 0, 255).astype(np.uint8)
        canvas = Image.fromarray(card_arr)
        draw_c = ImageDraw.Draw(canvas)

        # スキャン外周余白（白 or 黒 + 枠線）を 50% の確率で付与
        if rng.random() < 0.50:
            bg_col = (242, 242, 242) if rng.random() < 0.80 else (16, 16, 16)
            mx = rng.randint(4, 20)
            my = rng.randint(4, 14)
            outer = Image.new("RGB", (IMG_W, IMG_H), bg_col)
            inner_card = canvas.resize((IMG_W - mx * 2, IMG_H - my * 2), Image.Resampling.BILINEAR)
            outer.paste(inner_card, (mx, my))
            draw_o = ImageDraw.Draw(outer)
            draw_o.rectangle([mx, my, IMG_W - mx - 1, IMG_H - my - 1], outline=(90, 82, 70), width=1)
            canvas = outer
        else:
            mx, my = 0, 0

        for _ in range(rng.randint(0, 5)):
            sx = rng.randint(0, IMG_W - 1)
            sy = rng.randint(0, IMG_H - 1)
            sr = rng.randint(1, 3)
            scol = tuple(int(np.clip(c + rng.uniform(-45, 25), 0, 255)) for c in base_col)
            draw_c.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=scol)

        avail_w = IMG_W - mx * 2
        avail_h = IMG_H - my * 2
        margin_x = rng.randint(int(avail_w * 0.015), int(avail_w * 0.11))
        # 実カードでは中央の隙間が 1px〜数px の極細のものが多い
        gap_x = rng.randint(1, 18) if rng.random() < 0.75 else rng.randint(18, 36)
        win_w = max(80, (avail_w - margin_x * 2 - gap_x) // 2)
        margin_y = rng.randint(int(avail_h * 0.03), int(avail_h * 0.16))
        win_h = max(80, avail_h - margin_y * 2)

        lx0 = mx + margin_x + rng.randint(-3, 3)
        rx0 = lx0 + win_w + gap_x
        ly0 = my + margin_y + rng.randint(-3, 3)
        ry0 = ly0 + rng.randint(-2, 2)

        shape_type = rng.choice(["arch", "arch", "rounded", "rect"])
        rx_ratio = rng.uniform(0.06, 0.18)
        ry_ratio = rng.uniform(0.14, 0.30)

        patch = rng.choice(patches)
        if rng.random() < 0.5:
            patch = patch.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        p_arr = np.asarray(patch.resize((win_w, win_h), Image.Resampling.BILINEAR), dtype=np.float32)

        # 天体・夜空写真の再現（25%）: 暗い宇宙（Luma 25..45）の中に月球体を配置
        if rng.random() < 0.25:
            space_col = np.array([rng.randint(22, 38), rng.randint(24, 40), rng.randint(26, 42)], dtype=np.float32)
            p_arr = np.full((win_h, win_w, 3), space_col, dtype=np.float32) + np.random.normal(0, 3, (win_h, win_w, 3))
            mr = rng.randint(int(min(win_w, win_h) * 0.30), int(min(win_w, win_h) * 0.46))
            mcx = rng.randint(int(win_w * 0.38), int(win_w * 0.62))
            mcy = rng.randint(int(win_h * 0.38), int(win_h * 0.62))
            yy, xx = np.ogrid[:win_h, :win_w]
            dist_sq = (xx - mcx) ** 2 + (yy - mcy) ** 2
            moon_mask = dist_sq <= (mr ** 2)
            moon_luma = rng.uniform(105, 175)
            p_arr[moon_mask] = np.clip(p_arr[moon_mask] * 0.1 + moon_luma + np.random.normal(0, 15, p_arr[moon_mask].shape), 0, 255)
        # 上部白飛び / 台紙同系色空の再現
        elif rng.random() < 0.40:
            sky_h = int(win_h * rng.uniform(0.22, 0.48))
            sky_col = np.array(base_col, dtype=np.float32) + np.random.uniform(-15, 22, 3)
            sky_col = np.clip(sky_col, 165, 252)
            for yy in range(sky_h):
                alpha = 1.0 - (yy / max(1, sky_h)) ** 1.5
                p_arr[yy, :, :] = p_arr[yy, :, :] * (1.0 - alpha) + sky_col * alpha

        p_arr = np.clip(p_arr * rng.uniform(0.78, 1.22) + rng.uniform(-12, 12), 0, 255).astype(np.uint8)
        photo_l = Image.fromarray(p_arr)
        shift = rng.randint(2, 9)
        photo_r_arr = np.roll(p_arr, -shift, axis=1)
        photo_r_arr = np.clip(photo_r_arr.astype(np.float32) * rng.uniform(0.93, 1.07), 0, 255).astype(np.uint8)
        photo_r = Image.fromarray(photo_r_arr)

        win_mask = make_arch_window_mask(win_w, win_h, shape_type, rx_ratio, ry_ratio)

        # 2クラスラベル (0=台紙, 1=写真窓)
        label = Image.new("L", (IMG_W, IMG_H), 0)
        canvas.paste(photo_l, (lx0, ly0), win_mask)
        canvas.paste(photo_r, (rx0, ry0), win_mask)

        # 中央セパレータを明瞭に保つため、左右が近接する境界の視認性を再現
        if rng.random() < 0.20:
            gold = (165, 145, 85)
            d_c = ImageDraw.Draw(canvas)
            d_c.rounded_rectangle([lx0 - 1, ly0 - 1, lx0 + win_w, ly0 + win_h], radius=10, outline=gold, width=2)
            d_c.rounded_rectangle([rx0 - 1, ry0 - 1, rx0 + win_w, ry0 + win_h], radius=10, outline=gold, width=2)

        m_photo = win_mask.point(lambda v: 1 if v > 127 else 0)
        label.paste(m_photo, (lx0, ly0), win_mask)
        label.paste(m_photo, (rx0, ry0), win_mask)

        if rng.random() < 0.45:
            angle = rng.uniform(-1.5, 1.5)
            canvas = canvas.rotate(angle, resample=Image.Resampling.BILINEAR, fillcolor=base_col)
            label = label.rotate(angle, resample=Image.Resampling.NEAREST, fillcolor=0)

        if rng.random() < 0.20:
            canvas = canvas.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.3, 0.7)))

        imgs[idx] = np.asarray(canvas, dtype=np.uint8).transpose(2, 0, 1)
        lbls[idx] = np.asarray(label, dtype=np.uint8)

    print(f"[Data] {count} 枚の合成データを事前生成完了 ({time.time() - t0:.1f}s)")
    return torch.from_numpy(imgs), torch.from_numpy(lbls)


def soft_dice_loss(logits: torch.Tensor, targets: torch.Tensor) -> torch.Tensor:
    probs = F.softmax(logits, dim=1)[:, 1]  # 写真クラスの確率
    t = (targets == 1).float()
    inter = (probs * t).sum(dim=(1, 2))
    union = probs.sum(dim=(1, 2)) + t.sum(dim=(1, 2))
    dice = (2.0 * inter + 1e-4) / (union + 1e-4)
    return 1.0 - dice.mean()


# ==============================================================================
# 3. 学習 & Core ML (.mlpackage) エクスポート & 実カード検証
# ==============================================================================
def train_and_export(data_dir: str, out_path: str, epochs: int = 25, samples: int = 1600):
    patches, card_colors = load_source_patches_and_card_colors(data_dir)
    imgs_u8, lbls_u8 = generate_synthetic_tensors(patches, card_colors, samples)

    dataset = TensorDataset(imgs_u8, lbls_u8)
    loader = DataLoader(dataset, batch_size=32, shuffle=True)

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"[Train] Device: {device}, Epochs: {epochs}, Samples: {samples}")

    model = StereoCardUNet(base_ch=20, num_classes=2).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2.5e-3, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)
    ce_loss = nn.CrossEntropyLoss()

    t0 = time.time()
    for ep in range(1, epochs + 1):
        model.train()
        total_loss = 0.0
        correct = 0
        total_px = 0
        for b_imgs, b_lbls in loader:
            b_imgs = b_imgs.to(device=device, dtype=torch.float32) / 255.0
            b_lbls = b_lbls.to(device=device, dtype=torch.long)

            optimizer.zero_grad()
            logits = model(b_imgs)
            loss = ce_loss(logits, b_lbls) + 0.5 * soft_dice_loss(logits, b_lbls)
            loss.backward()
            optimizer.step()

            total_loss += loss.item() * b_imgs.size(0)
            preds = logits.argmax(dim=1)
            correct += (preds == b_lbls).sum().item()
            total_px += b_lbls.numel()

        scheduler.step()
        acc = correct / total_px * 100.0
        print(f"  Epoch {ep:02d}/{epochs} | Loss: {total_loss / samples:.4f} | Pixel Acc: {acc:.2f}%")

    print(f"[Train] 学習完了 ({time.time() - t0:.1f}s)")

    model_cpu = model.to("cpu").eval()
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    torch.save(model_cpu.state_dict(), os.path.join(os.path.dirname(os.path.abspath(out_path)), "stereo_card_seg.pt"))
    example_input = torch.rand(1, 3, IMG_H, IMG_W)
    traced = torch.jit.trace(model_cpu, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, IMG_H, IMG_W), scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.author = "StereoWindow Project"
    mlmodel.short_description = "19th-century Stereo Card 2-class CoordConv segmentation (0=Card, 1=Photo)"
    mlmodel.save(out_path)
    print(f"[Export] Core ML モデル保存完了: {out_path}")

    # 実カード検証（2クラスマスク + 中央セパレータ分割確認）
    exts = ("*.jpg", "*.jpeg", "*.png", "*.tif", "*.tiff", "*.webp")
    real_paths = []
    for ext in exts:
        real_paths.extend(glob.glob(os.path.join(data_dir, ext)))
    real_paths = sorted(real_paths)

    ok_cnt = 0
    for rp in real_paths:
        with Image.open(rp) as im:
            im_rgb = im.convert("RGB").resize((IMG_W, IMG_H), Image.Resampling.BILINEAR)
            out_dict = mlmodel.predict({"image": im_rgb})
            logits_np = out_dict["logits"][0]  # (2, H, W)
            # Softmax photo prob
            e0 = np.exp(logits_np[0] - np.maximum(logits_np[0], logits_np[1]))
            e1 = np.exp(logits_np[1] - np.maximum(logits_np[0], logits_np[1]))
            prob = e1 / (e0 + e1)
            seg = (prob >= 0.5)

            # 中央 x ∈ [40%, 60%] で最小列を探索
            c0, c1 = int(IMG_W * 0.40), int(IMG_W * 0.60)
            col_means = prob[:, c0:c1].mean(axis=0)
            split_x = c0 + int(np.argmin(col_means))

            l_ratio = seg[:, :split_x].mean()
            r_ratio = seg[:, split_x:].mean()
            card_ratio = 1.0 - seg.mean()
            sep_min = float(col_means.min())

            status = "OK" if (l_ratio > 0.30 and r_ratio > 0.30 and card_ratio > 0.05) else "WARN"
            if status == "OK":
                ok_cnt += 1
            print(f"  [{status}] {os.path.basename(rp)}: L={l_ratio*100:.1f}%, R={r_ratio*100:.1f}%, Card={card_ratio*100:.1f}%, splitX={split_x} (minProb={sep_min:.2f})")
    print(f"[Verify] 実カードテスト: {ok_cnt}/{len(real_paths)} 枚で左右写真領域を正常検出")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="StereoWindow/学習用データ")
    parser.add_argument("--out", default="StereoWindow/tools/StereoCardSeg.mlpackage")
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--samples", type=int, default=1600)
    args = parser.parse_args()
    train_and_export(args.data, args.out, epochs=args.epochs, samples=args.samples)
