#!/usr/bin/env python3
"""
StereoCardSeg (v3): Phase 2-4
事前学習済み timm バックボーン + CoordConv U-Net++ による 3クラスセグメンテーション
(0: 台紙/背景, 1: 左写真, 2: 右写真) 学習 & Core ML (.mlpackage, FP16) 変換スクリプト。

特徴:
- バックボーンの default_cfg["mean"] / ["std"] をラッパー forward() 内に内蔵し、
  Core ML 入力は ImageType(scale=1/255.0, bias=[0,0,0]) のみ
- 知覚ハッシュ (16x8 dHash) + ベース名正規化によるリーク完全防止 Group Split (split_manifest.json)
- 水平反転 (HorizontalFlip) 時のクラス 1 <-> 2 厳密スワップ
- 赤スタンプ合成拡張 (正解マスクはクラス 1/2 を維持)
- PyTorch vs Core ML FP16 一致検証 + 4 ComputeUnits レイテンシ計測 (--smoke-test 対応)
"""

import argparse
import glob
import json
import os
import random
import re
import time
import warnings
from collections import defaultdict

import coremltools as ct
import numpy as np
import timm
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter
from torch.utils.data import DataLoader, Dataset

warnings.filterwarnings("ignore")

IMG_W = 512
IMG_H = 256
NUM_CLASSES = 3


# ==============================================================================
# 1. 知覚ハッシュ + ベース名正規化によるリーク防止 Group Split
# ==============================================================================
def compute_dhash_16x8(img_path: str) -> np.ndarray:
    with Image.open(img_path) as im:
        gray = im.convert("L").resize((17, 8), Image.Resampling.BILINEAR)
        arr = np.asarray(gray, dtype=np.int16)
        return (arr[:, 1:] > arr[:, :-1]).reshape(-1)


def normalize_base_name(stem: str) -> str:
    s = stem.strip()
    m_flickr = re.match(r"^(\d{9,12})_[0-9a-f]{8,}_[obh](?:_Card)?$", s, flags=re.IGNORECASE)
    if m_flickr:
        return f"flickr_{m_flickr.group(1)}"
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\s*\(\d+\)$", "", s)
        s = re.sub(r"_Card$", "", s, flags=re.IGNORECASE)
        s = re.sub(r"=color$", "", s, flags=re.IGNORECASE)
        s = re.sub(r"(-scaled|-\d+x\d+|_\d+x\d+)$", "", s, flags=re.IGNORECASE)
        s = re.sub(r"_[obh]$", "", s, flags=re.IGNORECASE)
    return s.lower()


def collect_dataset_records(dataset_root: str):
    """
    dataset_root 直下の images/*.png と masks/*.png のみを対象にする
    (_excluded_duplicates, _review_top40 等の _ 始まりディレクトリは無視)
    """
    images_dir = os.path.join(dataset_root, "images")
    masks_dir = os.path.join(dataset_root, "masks")
    meta_dir = os.path.join(dataset_root, "metadata")

    img_paths = sorted(
        p for p in glob.glob(os.path.join(images_dir, "*.png"))
        if not os.path.basename(p).startswith(".")
    )
    records = []
    for ip in img_paths:
        stem = os.path.splitext(os.path.basename(ip))[0]
        mp = os.path.join(masks_dir, f"{stem}.png")
        if not os.path.exists(mp):
            continue
        meta_path = os.path.join(meta_dir, f"{stem}.json")
        was_manual = False
        if os.path.exists(meta_path):
            try:
                with open(meta_path, "r", encoding="utf-8") as f:
                    was_manual = bool(json.load(f).get("wasManuallyEdited", False))
            except Exception:
                pass
        records.append({
            "stem": stem,
            "image_path": ip,
            "mask_path": mp,
            "dhash": compute_dhash_16x8(ip),
            "norm_base": normalize_base_name(stem),
            "was_manual": was_manual,
        })
    return records


def build_leak_free_split(records, val_ratio: float = 0.15, seed: int = 42, manifest_out: str = None):
    n = len(records)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for i in range(n):
        for j in range(i + 1, n):
            dist = int(np.sum(records[i]["dhash"] != records[j]["dhash"]))
            same_base = (records[i]["norm_base"] == records[j]["norm_base"])
            if dist <= 16 or (same_base and dist <= 45):
                union(i, j)

    groups_map = defaultdict(list)
    for i in range(n):
        groups_map[find(i)].append(i)

    group_list = list(groups_map.values())
    rng = random.Random(seed)
    rng.shuffle(group_list)

    target_val = max(1, int(round(n * val_ratio))) if n >= 5 else 0
    val_indices = []
    train_indices = []

    for grp in group_list:
        if len(val_indices) < target_val:
            val_indices.extend(grp)
        else:
            train_indices.extend(grp)

    train_groups = {find(i) for i in train_indices}
    val_groups = {find(i) for i in val_indices}
    assert train_groups.isdisjoint(val_groups), "Data leak detected between train and val groups!"

    train_records = [records[i] for i in sorted(train_indices)]
    val_records = [records[i] for i in sorted(val_indices)]

    if manifest_out:
        multi_groups = [
            [records[idx]["stem"] for idx in grp]
            for grp in group_list if len(grp) > 1
        ]
        manifest = {
            "seed": seed,
            "val_ratio": val_ratio,
            "total_samples": n,
            "total_groups": len(group_list),
            "train_count": len(train_records),
            "val_count": len(val_records),
            "multi_member_groups": multi_groups,
            "train_stems": [r["stem"] for r in train_records],
            "val_stems": [r["stem"] for r in val_records],
        }
        os.makedirs(os.path.dirname(os.path.abspath(manifest_out)), exist_ok=True)
        with open(manifest_out, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)

    return train_records, val_records


# ==============================================================================
# 2. 実戦的データ拡張（水平反転 1<->2 スワップ + 赤スタンプ合成 + 劣化）
# ==============================================================================
def horizontal_flip_with_lr_swap(img_np: np.ndarray, mask_np: np.ndarray):
    """画像を左右反転し、マスクのクラス 1 (左写真) <-> クラス 2 (右写真) を厳密にスワップする"""
    flipped_img = np.ascontiguousarray(img_np[:, ::-1, :])
    flipped_mask = mask_np[:, ::-1]
    swapped_mask = np.where(
        flipped_mask == 1, 2,
        np.where(flipped_mask == 2, 1, 0)
    ).astype(np.uint8)
    return flipped_img, swapped_mask


def synthesize_red_watermark(img_pil: Image.Image, mask_np: np.ndarray, rng: random.Random) -> Image.Image:
    """写真領域（クラス1または2）上に回転付き赤スタンプを合成する（正解マスクはクラス1/2を維持）"""
    w, h = img_pil.size
    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    target_cls = 2 if rng.random() < 0.7 else 1
    ys, xs = np.where(mask_np == target_cls)
    if len(xs) < 20:
        return img_pil

    cx = int(np.percentile(xs, rng.uniform(55, 92)))
    cy = int(np.percentile(ys, rng.uniform(60, 92)))
    rad = rng.randint(max(12, w // 28), max(18, w // 14))
    alpha = rng.randint(95, 175)
    red_col = (rng.randint(165, 225), rng.randint(25, 65), rng.randint(25, 65), alpha)

    stamp_sz = max(48, rad * 3)
    sc = stamp_sz // 2
    stamp = Image.new("RGBA", (stamp_sz, stamp_sz), (0, 0, 0, 0))
    draw = ImageDraw.Draw(stamp)

    draw.ellipse([sc - rad, sc - rad, sc + rad, sc + rad], outline=red_col, width=max(2, rad // 10))
    inner_r = int(rad * 0.74)
    draw.ellipse([sc - inner_r, sc - inner_r, sc + inner_r, sc + inner_r], outline=red_col, width=max(1, rad // 14))

    band_h = max(8, rad // 3)
    draw.rectangle([sc - rad - 4, sc - band_h // 2, sc + rad + 4, sc + band_h // 2], fill=(220, 45, 45, min(200, alpha + 20)))
    draw.text((sc - rad + 4, sc - band_h // 2 + 1), "PROTECTED", fill=(255, 235, 235, min(230, alpha + 35)))

    angle = rng.uniform(-35.0, 35.0)
    stamp = stamp.rotate(angle, resample=Image.Resampling.BILINEAR, expand=True)
    overlay.paste(stamp, (cx - stamp.width // 2, cy - stamp.height // 2), stamp)

    if rng.random() < 0.5:
        overlay = overlay.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.3, 0.8)))

    base = img_pil.convert("RGBA")
    comp = Image.alpha_composite(base, overlay)
    return comp.convert("RGB")


class StereoCard3ClassDataset(Dataset):
    def __init__(self, records, augment: bool = True, seed: int = 42):
        self.records = records
        self.augment = augment
        self.rng = random.Random(seed)

    def __len__(self):
        return len(self.records)

    def __getitem__(self, idx):
        rec = self.records[idx]
        with Image.open(rec["image_path"]) as im_raw, Image.open(rec["mask_path"]) as mk_raw:
            im = im_raw.convert("RGB")
            mk = mk_raw.convert("L")

            if self.augment:
                # 1. 極薄余白クロップ（外縁 0..3% トリム）
                if self.rng.random() < 0.45:
                    w0, h0 = im.size
                    c_l = int(w0 * self.rng.uniform(0.0, 0.025))
                    c_r = int(w0 * self.rng.uniform(0.0, 0.025))
                    c_t = int(h0 * self.rng.uniform(0.0, 0.025))
                    c_b = int(h0 * self.rng.uniform(0.0, 0.025))
                    if w0 - c_l - c_r >= 64 and h0 - c_t - c_b >= 32:
                        im = im.crop((c_l, c_t, w0 - c_r, h0 - c_b))
                        mk = mk.crop((c_l, c_t, w0 - c_r, h0 - c_b))

                # 2. 微少回転 (±2.5度)
                if self.rng.random() < 0.40:
                    ang = self.rng.uniform(-2.5, 2.5)
                    bg_sample = tuple(int(v) for v in np.asarray(im)[0, 0])
                    im = im.rotate(ang, resample=Image.Resampling.BILINEAR, fillcolor=bg_sample)
                    mk = mk.rotate(ang, resample=Image.Resampling.NEAREST, fillcolor=0)

            im_resized = im.resize((IMG_W, IMG_H), Image.Resampling.BILINEAR)
            mk_resized = mk.resize((IMG_W, IMG_H), Image.Resampling.NEAREST)

            img_np = np.asarray(im_resized, dtype=np.uint8)
            mask_np = np.asarray(mk_resized, dtype=np.uint8)
            mask_np = np.clip(mask_np, 0, NUM_CLASSES - 1)

            if self.augment:
                # 3. 水平反転 (クラス 1 <-> 2 スワップ)
                if self.rng.random() < 0.50:
                    img_np, mask_np = horizontal_flip_with_lr_swap(img_np, mask_np)

                # 4. 赤スタンプ合成 (正解マスクは維持)
                if self.rng.random() < 0.35:
                    im_aug = synthesize_red_watermark(Image.fromarray(img_np), mask_np, self.rng)
                    img_np = np.asarray(im_aug, dtype=np.uint8)

                # 5. 経年劣化・低コントラスト・黄ばみ・ブラー
                im_aug = Image.fromarray(img_np)
                if self.rng.random() < 0.70:
                    im_aug = ImageEnhance.Brightness(im_aug).enhance(self.rng.uniform(0.80, 1.20))
                    im_aug = ImageEnhance.Contrast(im_aug).enhance(self.rng.uniform(0.75, 1.25))
                    im_aug = ImageEnhance.Color(im_aug).enhance(self.rng.uniform(0.65, 1.30))
                if self.rng.random() < 0.25:
                    im_aug = im_aug.filter(ImageFilter.GaussianBlur(radius=self.rng.uniform(0.3, 0.9)))
                img_np = np.asarray(im_aug, dtype=np.uint8)

                # 6. 黄ばみ・ガウスノイズ
                if self.rng.random() < 0.45:
                    f_arr = img_np.astype(np.float32)
                    tint = np.array([
                        self.rng.uniform(0.95, 1.08),
                        self.rng.uniform(0.94, 1.04),
                        self.rng.uniform(0.84, 1.02),
                    ], dtype=np.float32)
                    f_arr = f_arr * tint + np.random.normal(0.0, self.rng.uniform(1.0, 5.0), size=f_arr.shape).astype(np.float32)
                    img_np = np.clip(f_arr, 0, 255).astype(np.uint8)

        img_t = torch.from_numpy(np.ascontiguousarray(img_np.transpose(2, 0, 1))).float() / 255.0
        mask_t = torch.from_numpy(np.ascontiguousarray(mask_np)).long()
        return img_t, mask_t


# ==============================================================================
# 3. timm バックボーン + mean/std内蔵 + CoordConv U-Net++ (3クラス)
# ==============================================================================
class UNetPPBlock(nn.Module):
    def __init__(self, in_ch: int, out_ch: int):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
        )

    def forward(self, x):
        return self.conv(x)


class StereoCardUNetPP(nn.Module):
    def __init__(self, backbone_name: str = "efficientnet_b0", pretrained: bool = True, num_classes: int = NUM_CLASSES):
        super().__init__()
        self.encoder = timm.create_model(
            backbone_name,
            pretrained=pretrained,
            features_only=True,
            out_indices=(0, 1, 2, 3, 4),
            exportable=True,
        )
        cfg = getattr(self.encoder, "default_cfg", {}) or {}
        mean = cfg.get("mean", (0.485, 0.456, 0.406))
        std = cfg.get("std", (0.229, 0.224, 0.225))
        self.register_buffer("img_mean", torch.tensor(mean, dtype=torch.float32).view(1, 3, 1, 1))
        self.register_buffer("img_std", torch.tensor(std, dtype=torch.float32).view(1, 3, 1, 1))

        # CoordConv 用正規化座標 [-1, 1] バッファ (256x512)
        xs = torch.linspace(-1.0, 1.0, IMG_W).view(1, 1, 1, IMG_W).expand(1, 1, IMG_H, IMG_W)
        ys = torch.linspace(-1.0, 1.0, IMG_H).view(1, 1, IMG_H, 1).expand(1, 1, IMG_H, IMG_W)
        self.register_buffer("coords", torch.cat([xs, ys], dim=1))

        enc_chs = self.encoder.feature_info.channels()  # [c0, c1, c2, c3, c4] (strides 2, 4, 8, 16, 32)
        nb = [24, 40, 64, 96, 128]

        self.proj0 = nn.Conv2d(enc_chs[0], nb[0], kernel_size=1, bias=False)
        self.proj1 = nn.Conv2d(enc_chs[1], nb[1], kernel_size=1, bias=False)
        self.proj2 = nn.Conv2d(enc_chs[2], nb[2], kernel_size=1, bias=False)
        self.proj3 = nn.Conv2d(enc_chs[3], nb[3], kernel_size=1, bias=False)
        self.proj4 = nn.Conv2d(enc_chs[4], nb[4], kernel_size=1, bias=False)

        # U-Net++ Nested Dense Skip Pathways
        self.conv0_1 = UNetPPBlock(nb[0] + nb[1], nb[0])
        self.conv1_1 = UNetPPBlock(nb[1] + nb[2], nb[1])
        self.conv2_1 = UNetPPBlock(nb[2] + nb[3], nb[2])
        self.conv3_1 = UNetPPBlock(nb[3] + nb[4], nb[3])

        self.conv0_2 = UNetPPBlock(nb[0] * 2 + nb[1], nb[0])
        self.conv1_2 = UNetPPBlock(nb[1] * 2 + nb[2], nb[1])
        self.conv2_2 = UNetPPBlock(nb[2] * 2 + nb[3], nb[2])

        self.conv0_3 = UNetPPBlock(nb[0] * 3 + nb[1], nb[0])
        self.conv1_3 = UNetPPBlock(nb[1] * 3 + nb[2], nb[1])

        self.conv0_4 = UNetPPBlock(nb[0] * 4 + nb[1], nb[0])

        # フル解像度 (256x512) に戻してから CoordConv を結合して最終予測
        self.final_refine = UNetPPBlock(nb[0] + 2, nb[0])
        self.head = nn.Conv2d(nb[0], num_classes, kernel_size=1)

    @staticmethod
    def _up2(t: torch.Tensor) -> torch.Tensor:
        return F.interpolate(t, scale_factor=2.0, mode="bilinear", align_corners=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # 入力 x は [0, 1] の RGB (Core ML scale=1/255.0, bias=[0,0,0])
        x_norm = (x - self.img_mean) / self.img_std
        feats = self.encoder(x_norm)

        x0_0 = self.proj0(feats[0])  # 1/2
        x1_0 = self.proj1(feats[1])  # 1/4
        x2_0 = self.proj2(feats[2])  # 1/8
        x3_0 = self.proj3(feats[3])  # 1/16
        x4_0 = self.proj4(feats[4])  # 1/32

        x0_1 = self.conv0_1(torch.cat([x0_0, self._up2(x1_0)], dim=1))
        x1_1 = self.conv1_1(torch.cat([x1_0, self._up2(x2_0)], dim=1))
        x2_1 = self.conv2_1(torch.cat([x2_0, self._up2(x3_0)], dim=1))
        x3_1 = self.conv3_1(torch.cat([x3_0, self._up2(x4_0)], dim=1))

        x0_2 = self.conv0_2(torch.cat([x0_0, x0_1, self._up2(x1_1)], dim=1))
        x1_2 = self.conv1_2(torch.cat([x1_0, x1_1, self._up2(x2_1)], dim=1))
        x2_2 = self.conv2_2(torch.cat([x2_0, x2_1, self._up2(x3_1)], dim=1))

        x0_3 = self.conv0_3(torch.cat([x0_0, x0_1, x0_2, self._up2(x1_2)], dim=1))
        x1_3 = self.conv1_3(torch.cat([x1_0, x1_1, x1_2, self._up2(x2_2)], dim=1))

        x0_4 = self.conv0_4(torch.cat([x0_0, x0_1, x0_2, x0_3, self._up2(x1_3)], dim=1))

        up_full = self._up2(x0_4)
        coords = x[:, :2, :, :] * 0.0 + self.coords
        out = self.final_refine(torch.cat([up_full, coords], dim=1))
        return self.head(out)


# ==============================================================================
# 4. 損失関数・評価指標・Core ML 変換 & ベンチマーク
# ==============================================================================
def multiclass_soft_dice_loss(logits: torch.Tensor, targets: torch.Tensor) -> torch.Tensor:
    probs = F.softmax(logits, dim=1)
    loss_sum = 0.0
    weights = [0.2, 0.4, 0.4]  # 左・右写真クラスを重視
    for c in range(NUM_CLASSES):
        p = probs[:, c]
        t = (targets == c).float()
        inter = (p * t).sum(dim=(1, 2))
        union = p.sum(dim=(1, 2)) + t.sum(dim=(1, 2))
        dice = (2.0 * inter + 1e-4) / (union + 1e-4)
        loss_sum += weights[c] * (1.0 - dice.mean())
    return loss_sum


def compute_boundary_weight_map(targets: torch.Tensor) -> torch.Tensor:
    t_f = targets.unsqueeze(1).float()
    max_p = F.max_pool2d(t_f, kernel_size=5, stride=1, padding=2)
    min_p = -F.max_pool2d(-t_f, kernel_size=5, stride=1, padding=2)
    is_edge = (max_p != min_p).squeeze(1).float()
    return 1.0 + is_edge * 1.5


def compute_class_ious(pred: np.ndarray, target: np.ndarray):
    ious = []
    for c in range(NUM_CLASSES):
        p_c = (pred == c)
        t_c = (target == c)
        inter = np.logical_and(p_c, t_c).sum()
        union = np.logical_or(p_c, t_c).sum()
        ious.append(float(inter) / float(union) if union > 0 else 1.0)
    return ious


def compute_boundary_iou(pred: np.ndarray, target: np.ndarray, band_px: int = 5) -> float:
    """正解マスクの境界 band_px バンド上における 3クラス平均 IoU (Boundary mIoU) を計算する"""
    t_f = torch.from_numpy(target.astype(np.float32)).unsqueeze(0).unsqueeze(0)
    k = band_px if band_px % 2 == 1 else band_px + 1
    pad = k // 2
    max_p = F.max_pool2d(t_f, kernel_size=k, stride=1, padding=pad)
    min_p = -F.max_pool2d(-t_f, kernel_size=k, stride=1, padding=pad)
    band = (max_p != min_p).squeeze().numpy()
    if not np.any(band):
        return 1.0
    b_ious = []
    for c in range(NUM_CLASSES):
        p_c = np.logical_and(pred == c, band)
        t_c = np.logical_and(target == c, band)
        union = np.logical_or(p_c, t_c).sum()
        if union > 0:
            inter = np.logical_and(p_c, t_c).sum()
            b_ious.append(float(inter) / float(union))
    return float(np.mean(b_ious)) if b_ious else 1.0


def _overlay_class_mask(rgb_np: np.ndarray, mask_np: np.ndarray, err_mask: np.ndarray = None) -> np.ndarray:
    out = rgb_np.astype(np.float32).copy()
    # 0=Mount(暗転), 1=Left(シアン), 2=Right(グリーン)
    m0 = (mask_np == 0)
    m1 = (mask_np == 1)
    m2 = (mask_np == 2)
    out[m0] *= 0.45
    out[m1] = out[m1] * 0.62 + np.array([30.0, 200.0, 240.0], dtype=np.float32) * 0.38
    out[m2] = out[m2] * 0.62 + np.array([50.0, 225.0, 120.0], dtype=np.float32) * 0.38
    if err_mask is not None:
        out[err_mask] = out[err_mask] * 0.25 + np.array([255.0, 45.0, 45.0], dtype=np.float32) * 0.75
    return np.clip(out, 0, 255).astype(np.uint8)


def export_val_previews(model_cpu: nn.Module, val_records, out_dir: str, max_samples: int = 8):
    """Val 全件を推論・採点し、代表的なサンプルの 3パネル比較画像（元画像 / 正解 / 予測+誤差強調）を出力する"""
    if not val_records or not out_dir:
        return
    os.makedirs(out_dir, exist_ok=True)
    model_cpu.eval()
    eval_items = []

    for rec in val_records:
        with Image.open(rec["image_path"]) as im_raw, Image.open(rec["mask_path"]) as mk_raw:
            im_rgb = im_raw.convert("RGB").resize((IMG_W, IMG_H), Image.Resampling.BILINEAR)
            mk_gt = mk_raw.convert("L").resize((IMG_W, IMG_H), Image.Resampling.NEAREST)
            img_np = np.asarray(im_rgb, dtype=np.uint8)
            gt_np = np.clip(np.asarray(mk_gt, dtype=np.uint8), 0, NUM_CLASSES - 1)

        t_in = torch.from_numpy(np.ascontiguousarray(img_np.transpose(2, 0, 1))).float().unsqueeze(0) / 255.0
        with torch.no_grad():
            logits = model_cpu(t_in)[0].numpy()
        pred_np = logits.argmax(axis=0).astype(np.uint8)
        c_ious = compute_class_ious(pred_np, gt_np)
        miou = float(np.mean(c_ious))
        b_miou = compute_boundary_iou(pred_np, gt_np, band_px=5)
        eval_items.append({
            "stem": rec["stem"],
            "was_manual": bool(rec.get("was_manual", False)),
            "miou": miou,
            "boundary_miou": b_miou,
            "bg_iou": float(c_ious[0]),
            "l_iou": float(c_ious[1]),
            "r_iou": float(c_ious[2]),
            "img_np": img_np,
            "gt_np": gt_np,
            "pred_np": pred_np,
        })

    # サマリー JSON 書き出し
    summary_rows = [
        {
            "stem": x["stem"],
            "was_manual": x["was_manual"],
            "miou_pct": round(x["miou"] * 100.0, 2),
            "boundary_miou_pct": round(x["boundary_miou"] * 100.0, 2),
            "bg_iou_pct": round(x["bg_iou"] * 100.0, 2),
            "l_iou_pct": round(x["l_iou"] * 100.0, 2),
            "r_iou_pct": round(x["r_iou"] * 100.0, 2),
        }
        for x in sorted(eval_items, key=lambda r: r["boundary_miou"])
    ]
    summary_path = os.path.join(out_dir, "val_metrics_summary.json")
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary_rows, f, ensure_ascii=False, indent=2)

    # 手動補正済み優先 + Boundary mIoU ワースト〜ベストからバランス良く最大 max_samples 枚選出
    by_b = sorted(eval_items, key=lambda r: r["boundary_miou"])
    selected = []
    seen = set()
    # 1. 手動補正済みを最大 4 枚（ワースト側優先）
    for item in by_b:
        if item["was_manual"] and len(selected) < min(4, max_samples):
            selected.append(item)
            seen.add(item["stem"])
    # 2. Boundary mIoU ワースト側とベスト側を追加
    for item in by_b:
        if item["stem"] not in seen and len(selected) < max_samples - 2:
            selected.append(item)
            seen.add(item["stem"])
    for item in reversed(by_b):
        if item["stem"] not in seen and len(selected) < max_samples:
            selected.append(item)
            seen.add(item["stem"])

    for idx, item in enumerate(selected, start=1):
        img_np = item["img_np"]
        gt_vis = _overlay_class_mask(img_np, item["gt_np"])
        err = (item["pred_np"] != item["gt_np"])
        pred_vis = _overlay_class_mask(img_np, item["pred_np"], err_mask=err)
        canvas = np.concatenate([img_np, gt_vis, pred_vis], axis=1)
        pil_out = Image.fromarray(canvas)
        draw = ImageDraw.Draw(pil_out)
        tag = "[MAN]" if item["was_manual"] else "[AUTO]"
        label = (
            f"{tag} {item['stem']} | mIoU={item['miou']*100:.1f}% "
            f"(L={item['l_iou']*100:.1f}%, R={item['r_iou']*100:.1f}%) | "
            f"B-mIoU={item['boundary_miou']*100:.1f}% | Panels: Orig / GT / Pred(Red=Err)"
        )
        draw.rectangle([0, 0, pil_out.width, 18], fill=(12, 12, 16))
        draw.text((6, 3), label, fill=(245, 245, 250))
        safe_stem = item["stem"].replace("/", "_")
        out_png = os.path.join(out_dir, f"{idx:02d}_{safe_stem}_cmp.png")
        pil_out.save(out_png)
    print(f"[ValPreview] Exported {len(selected)} comparison images & summary -> {out_dir}")


def export_to_coreml_fp16(model_cpu: nn.Module, out_path: str):
    model_cpu.eval()
    example_input = torch.rand(1, 3, IMG_H, IMG_W)
    with torch.no_grad():
        traced = torch.jit.trace(model_cpu, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMG_H, IMG_W),
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.author = "ViewStereo Project"
    mlmodel.short_description = "19th-century Stereo Card 3-class CoordConv U-Net++ (0=Mount, 1=Left, 2=Right)"
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    mlmodel.save(out_path)
    return mlmodel


def verify_pytorch_vs_coreml(model_cpu: nn.Module, mlmodel_path: str, test_image_paths):
    mlmodel = ct.models.MLModel(mlmodel_path, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    model_cpu.eval()
    max_diffs = []
    mean_diffs = []
    agree_rates = []
    ious_all = []

    for ip in test_image_paths:
        with Image.open(ip) as im:
            im_rgb = im.convert("RGB").resize((IMG_W, IMG_H), Image.Resampling.BILINEAR)
        arr = np.asarray(im_rgb, dtype=np.float32) / 255.0
        t_in = torch.from_numpy(arr.transpose(2, 0, 1)).unsqueeze(0)
        with torch.no_grad():
            pt_logits = model_cpu(t_in)[0].numpy()  # (3, H, W)

        cm_out = mlmodel.predict({"image": im_rgb})["logits"][0]
        diff = np.abs(pt_logits - cm_logits_norm(cm_out))
        max_diffs.append(float(diff.max()))
        mean_diffs.append(float(diff.mean()))

        pt_pred = pt_logits.argmax(axis=0)
        cm_pred = cm_out.argmax(axis=0)
        agree_rates.append(float(np.mean(pt_pred == cm_pred)) * 100.0)
        ious_all.append(compute_class_ious(cm_pred, pt_pred))

    mean_iou = float(np.mean(ious_all)) if ious_all else 0.0
    print(
        f"[Verify PyTorch vs CoreML FP16] samples={len(test_image_paths)} | "
        f"max_abs_diff={max(max_diffs):.5f} | mean_abs_diff={np.mean(mean_diffs):.5f} | "
        f"argmax_agree={np.mean(agree_rates):.2f}% | mIoU(cm vs pt)={mean_iou*100:.2f}%"
    )


def cm_logits_norm(arr: np.ndarray) -> np.ndarray:
    return arr


def benchmark_compute_units(mlmodel_path: str, sample_image_path: str, warmup: int = 3, iters: int = 10):
    with Image.open(sample_image_path) as im:
        im_rgb = im.convert("RGB").resize((IMG_W, IMG_H), Image.Resampling.BILINEAR)

    units = [
        ("ALL", ct.ComputeUnit.ALL),
        ("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU),
        ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE),
        ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY),
    ]
    print("[Benchmark] Core ML FP16 latency:")
    for label, cu in units:
        try:
            m = ct.models.MLModel(mlmodel_path, compute_units=cu)
            for _ in range(warmup):
                _ = m.predict({"image": im_rgb})
            times = []
            for _ in range(iters):
                t0 = time.perf_counter()
                _ = m.predict({"image": im_rgb})
                times.append((time.perf_counter() - t0) * 1000.0)
            print(f"  - {label:12s}: mean={np.mean(times):6.2f} ms | median={np.median(times):6.2f} ms")
        except Exception as e:
            print(f"  - {label:12s}: FAILED ({type(e).__name__}: {e})")


def run_smoke_test(dataset_root: str, out_path: str, backbone: str, pretrained: bool):
    print("=== Phase 2-4 Smoke Test ===")
    # 1. 水平反転 1 <-> 2 スワップ単体検証
    dummy_img = np.arange(4 * 6 * 3, dtype=np.uint8).reshape(4, 6, 3)
    dummy_mask = np.array([
        [0, 1, 1, 0, 2, 2],
        [0, 1, 1, 0, 2, 2],
        [0, 1, 1, 0, 2, 2],
        [0, 0, 0, 0, 0, 0],
    ], dtype=np.uint8)
    _, swapped = horizontal_flip_with_lr_swap(dummy_img, dummy_mask)
    expected_row0 = np.array([1, 1, 0, 2, 2, 0], dtype=np.uint8)
    assert np.array_equal(swapped[0], expected_row0), f"Flip swap failed: {swapped[0]}"
    assert np.array_equal(np.unique(swapped), np.array([0, 1, 2])), "Flip classes corrupted!"
    print("[Smoke 1/5] HorizontalFlip class 1 <-> 2 swap check: PASSED")

    # 2. Group Split & データリーク検証
    records = collect_dataset_records(dataset_root)
    print(f"[Smoke 2/5] Loaded dataset records: {len(records)} (from {dataset_root})")
    if len(records) >= 5:
        manifest_tmp = os.path.join(os.path.dirname(os.path.abspath(out_path)), "split_manifest_smoke.json")
        tr, va = build_leak_free_split(records, val_ratio=0.15, seed=42, manifest_out=manifest_tmp)
        print(f"  Group Split: train={len(tr)}, val={len(va)} (0 group leaks) -> {manifest_tmp}")
        sample_paths = [r["image_path"] for r in (va[:3] if va else tr[:3])]
    else:
        raise RuntimeError(f"データセットが見つかりません: {dataset_root}")

    # 3. 赤スタンプ合成 & Boundary mIoU & DatasetLoader 検証
    ds = StereoCard3ClassDataset(tr[:4], augment=True, seed=42)
    b_img, b_msk = ds[0]
    assert b_img.shape == (3, IMG_H, IMG_W) and b_msk.shape == (IMG_H, IMG_W)
    b_iou_self = compute_boundary_iou(b_msk.numpy(), b_msk.numpy(), band_px=5)
    assert abs(b_iou_self - 1.0) < 1e-6, f"Boundary IoU self-check failed: {b_iou_self}"
    print(f"[Smoke 3/5] Augmented tensor shape: img={tuple(b_img.shape)} mask={tuple(b_msk.shape)} classes={torch.unique(b_msk).tolist()} | BoundaryIoU(self)={b_iou_self*100:.1f}%")

    # 4. 未学習モデルでの FP16 Core ML 変換
    t0 = time.time()
    model = StereoCardUNetPP(backbone_name=backbone, pretrained=pretrained, num_classes=NUM_CLASSES).eval()
    export_to_coreml_fp16(model, out_path)
    print(f"[Smoke 4/5] Exported FP16 mlpackage ({backbone}, pretrained={pretrained}) in {time.time() - t0:.1f}s -> {out_path}")

    # 5. PyTorch vs Core ML 一致確認 + 4 ComputeUnits レイテンシ計測
    verify_pytorch_vs_coreml(model, out_path, sample_paths)
    benchmark_compute_units(out_path, sample_paths[0])


def train_and_export(args):
    records = collect_dataset_records(args.dataset)
    if not records:
        raise RuntimeError(f"有効な 3クラスデータセットがありません: {args.dataset}")

    out_dir = os.path.dirname(os.path.abspath(args.out))
    manifest_path = os.path.join(out_dir, "split_manifest.json")
    train_recs, val_recs = build_leak_free_split(records, val_ratio=args.val_ratio, seed=args.seed, manifest_out=manifest_path)
    print(f"[Data] Total={len(records)} | Train={len(train_recs)} | Val={len(val_recs)} | Manifest={manifest_path}")

    train_ds = StereoCard3ClassDataset(train_recs, augment=True, seed=args.seed)
    val_ds = StereoCard3ClassDataset(val_recs, augment=False, seed=args.seed)

    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=0)

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"[Train] Device={device} | Backbone={args.backbone} (pretrained={not args.no_pretrained}) | Epochs={args.epochs}")

    model = StereoCardUNetPP(
        backbone_name=args.backbone,
        pretrained=not args.no_pretrained,
        num_classes=NUM_CLASSES,
    ).to(device)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    ce_fn = nn.CrossEntropyLoss(reduction="none", label_smoothing=0.02)

    best_score = -1.0
    best_miou = -1.0
    best_b_miou = -1.0
    best_c_ious = np.zeros(3)
    best_epoch = 0
    best_pt_path = os.path.join(out_dir, "stereo_card_seg_v3_best.pt")
    os.makedirs(out_dir, exist_ok=True)

    for ep in range(1, args.epochs + 1):
        model.train()
        tr_loss = 0.0
        for b_imgs, b_lbls in train_loader:
            b_imgs = b_imgs.to(device)
            b_lbls = b_lbls.to(device)

            optimizer.zero_grad()
            logits = model(b_imgs)
            b_w = compute_boundary_weight_map(b_lbls)
            loss_ce = (ce_fn(logits, b_lbls) * b_w).mean()
            loss_dice = multiclass_soft_dice_loss(logits, b_lbls)
            loss = loss_ce + 0.65 * loss_dice
            loss.backward()
            optimizer.step()
            tr_loss += loss.item() * b_imgs.size(0)
        scheduler.step()

        # Validation
        model.eval()
        val_ious = []
        val_b_ious = []
        with torch.no_grad():
            for b_imgs, b_lbls in val_loader:
                logits = model(b_imgs.to(device))
                preds = logits.argmax(dim=1).cpu().numpy()
                tgts = b_lbls.numpy()
                for p, t in zip(preds, tgts):
                    val_ious.append(compute_class_ious(p, t))
                    val_b_ious.append(compute_boundary_iou(p, t, band_px=5))

        mean_c_ious = np.mean(val_ious, axis=0) if val_ious else np.zeros(3)
        miou = float(np.mean(mean_c_ious))
        b_miou = float(np.mean(val_b_ious)) if val_b_ious else 0.0
        score = 0.5 * miou + 0.5 * b_miou
        print(
            f"  Epoch {ep:02d}/{args.epochs} | Loss={tr_loss / max(1, len(train_ds)):.4f} | "
            f"Val mIoU={miou*100:.2f}% (Bg={mean_c_ious[0]*100:.1f}%, L={mean_c_ious[1]*100:.1f}%, R={mean_c_ious[2]*100:.1f}%) | "
            f"Boundary mIoU={b_miou*100:.2f}% | Score={score*100:.2f}%"
        )
        if score > best_score:
            best_score = score
            best_miou = miou
            best_b_miou = b_miou
            best_c_ious = mean_c_ious.copy()
            best_epoch = ep
            torch.save(model.state_dict(), best_pt_path)

    model.load_state_dict(torch.load(best_pt_path, map_location="cpu"))
    model_cpu = model.to("cpu").eval()
    export_to_coreml_fp16(model_cpu, args.out)
    print(
        f"[Export] Best Epoch={best_epoch} | Score={best_score*100:.2f}% | "
        f"Val mIoU={best_miou*100:.2f}% (Bg={best_c_ious[0]*100:.2f}%, L={best_c_ious[1]*100:.2f}%, R={best_c_ious[2]*100:.2f}%) | "
        f"Boundary mIoU={best_b_miou*100:.2f}% | Saved Core ML FP16 -> {args.out}"
    )

    if args.val_preview_dir and val_recs:
        export_val_previews(model_cpu, val_recs, args.val_preview_dir, max_samples=8)

    val_imgs = [r["image_path"] for r in val_recs[:min(8, len(val_recs))]]
    if val_imgs:
        verify_pytorch_vs_coreml(model_cpu, args.out, val_imgs)
        benchmark_compute_units(args.out, val_imgs[0])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default="/Users/okano/マイドライブ/DEV/ViewStereo/dataset_3class")
    parser.add_argument("--out", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/StereoCardSeg_v3.mlpackage")
    parser.add_argument("--val-preview-dir", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/val_preview_v3")
    parser.add_argument("--backbone", default="efficientnet_b0")
    parser.add_argument("--epochs", type=int, default=70)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--val-ratio", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--no-pretrained", action="store_true")
    parser.add_argument("--smoke-test", action="store_true")
    args = parser.parse_args()

    if args.smoke_test:
        run_smoke_test(args.dataset, args.out, backbone=args.backbone, pretrained=not args.no_pretrained)
    else:
        train_and_export(args)
