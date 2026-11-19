#!/usr/bin/env python3
"""
1. 学習用データフォルダのステレオカード画像から StereoCardSeg.mlpackage を使って
   台紙を除いた左右写真領域 (L/R) を切り出す。
2. 重複画像 (リサイズ版など) を除外し、写真内部の色情報から
   - hand_tinted (手彩色・カラー画像: 学習・定量評価用)
   - monochrome  (モノクロ・セピア画像: 定性テスト用)
   に仕分ける。
3. 現在の StereoColorizer.mlpackage を用いてベースライン検証（定量指標 + 比較画像）を行う。
"""

import argparse
import glob
import json
import os
from typing import Dict, List, Optional, Tuple

import coremltools as ct
import numpy as np
from PIL import Image, ImageDraw, ImageFont


# ------------------------------------------------------------------------------
# sRGB <-> CIE Lab (D65) 変換 (StereoColorizer.swift と同等の数式)
# ------------------------------------------------------------------------------
def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, np.power((c + 0.055) / 1.055, 2.4))


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """rgb: [H, W, 3] in [0, 1] -> Lab: L in [0, 100], a,b in ~[-110, 110]"""
    lin = srgb_to_linear(rgb)
    r, g, b = lin[..., 0], lin[..., 1], lin[..., 2]
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / 1.00000
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883

    eps = 0.008856
    kappa = 903.3
    fx = np.where(x > eps, np.cbrt(x), (kappa * x + 16.0) / 116.0)
    fy = np.where(y > eps, np.cbrt(y), (kappa * y + 16.0) / 116.0)
    fz = np.where(z > eps, np.cbrt(z), (kappa * z + 16.0) / 116.0)

    L = 116.0 * fy - 16.0
    a = 500.0 * (fx - fy)
    b_ch = 200.0 * (fy - fz)
    return np.stack([L, a, b_ch], axis=-1).astype(np.float32)


def lab_to_rgb(lab: np.ndarray) -> np.ndarray:
    """Lab -> sRGB [0, 1]"""
    L, a, b_ch = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16.0) / 116.0
    fx = a / 500.0 + fy
    fz = fy - b_ch / 200.0

    eps = 0.008856
    kappa = 903.3
    x = np.where(fx**3 > eps, fx**3, (116.0 * fx - 16.0) / kappa) * 0.95047
    y = np.where(L > kappa * eps, ((L + 16.0) / 116.0) ** 3, L / kappa) * 1.00000
    z = np.where(fz**3 > eps, fz**3, (116.0 * fz - 16.0) / kappa) * 1.08883

    r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
    g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
    b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
    return linear_to_srgb(np.stack([r, g, b], axis=-1)).astype(np.float32)


# ------------------------------------------------------------------------------
# 1. ステレオカード左右窓の抽出 & 分類
# ------------------------------------------------------------------------------
def dhash(im: Image.Image, hash_size: int = 8) -> int:
    gray = im.convert("L").resize((hash_size + 1, hash_size), Image.Resampling.LANCZOS)
    arr = np.asarray(gray)
    diff = arr[:, 1:] > arr[:, :-1]
    val = 0
    for bit in diff.flatten():
        val = (val << 1) | int(bit)
    return val


def extract_lr_boxes(seg_model: ct.models.MLModel, im: Image.Image) -> Optional[Tuple[Tuple[int, int, int, int], Tuple[int, int, int, int]]]:
    w, h = im.size
    if w < 100 or h < 80:
        return None
    im_seg = im.resize((512, 256), Image.Resampling.BILINEAR)
    logits = seg_model.predict({"image": im_seg})["logits"][0]  # [2, 256, 512]
    mask = logits[1] > logits[0]

    boxes = []
    for half_idx, (x_start, x_end) in enumerate([(0, 256), (256, 512)]):
        sub = mask[:, x_start:x_end]
        if sub.mean() < 0.08:
            return None
        ys, xs = np.where(sub)
        # 外れ値除去のため 1%-99% 分位点でタイトに囲む
        y0 = int(np.percentile(ys, 1))
        y1 = int(np.percentile(ys, 99))
        x0 = int(np.percentile(xs, 1)) + x_start
        x1 = int(np.percentile(xs, 99)) + x_start
        # 元画像座標へ変換し、さらに台紙残り防止のため内側 2% トリミング
        gx0 = int(x0 / 512.0 * w)
        gx1 = int(x1 / 512.0 * w)
        gy0 = int(y0 / 256.0 * h)
        gy1 = int(y1 / 256.0 * h)
        bw = gx1 - gx0
        bh = gy1 - gy0
        if bw < 40 or bh < 40:
            return None
        ix = max(2, int(bw * 0.02))
        iy = max(2, int(bh * 0.02))
        boxes.append((gx0 + ix, gy0 + iy, gx1 - ix, gy1 - iy))
    return boxes[0], boxes[1]


def classify_color_nature(crop: Image.Image) -> Dict[str, float]:
    """切り出した写真領域が『手彩色/カラー』か『モノクロ/セピア』かを判定"""
    arr = np.asarray(crop.convert("RGB"), dtype=np.float32) / 255.0
    lab = rgb_to_lab(arr)
    a = lab[..., 1]
    b = lab[..., 2]
    # セピア/モノクロは (a, b) の分散が小さく、a*b の符号変化も少ない
    ab_std = float(np.std(a) + np.std(b))
    # 色相の広がり: 緑/青/シアン方向 (a < -4 or b < -2) や赤系 (a > 12) があるか
    vivid_ratio = float(np.mean((a < -4.0) | (b < -3.0) | (a > 12.0)))
    chroma = np.sqrt(a**2 + b**2)
    chroma_95 = float(np.percentile(chroma, 95))
    is_color = (ab_std > 10.5 and chroma_95 > 14.0) or (vivid_ratio > 0.06 and ab_std > 7.5)
    return {
        "is_color": is_color,
        "ab_std": ab_std,
        "chroma_95": chroma_95,
        "vivid_ratio": vivid_ratio,
    }


# ------------------------------------------------------------------------------
# 2. Colorizer 推論 & 評価
# ------------------------------------------------------------------------------
def run_colorizer(col_model: ct.models.MLModel, crop: Image.Image) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """
    crop: PIL Image
    returns: (orig_rgb [H,W,3], pred_rgb_full [H,W,3], pred_ab_512 [512,512,2])
    """
    orig_rgb = np.asarray(crop.convert("RGB"), dtype=np.float32) / 255.0
    orig_lab = rgb_to_lab(orig_rgb)

    im_512 = crop.convert("RGB").resize((512, 512), Image.Resampling.BILINEAR)
    rgb_512 = np.asarray(im_512, dtype=np.float32) / 255.0
    lab_512 = rgb_to_lab(rgb_512)
    L_512 = lab_512[..., 0]

    # StereoColorizer.swift と同じ 2%〜98% パーセンタイルストレッチ
    p_low = float(np.percentile(L_512, 2))
    p_high = float(np.percentile(L_512, 98))
    span = max(12.0, p_high - p_low)
    L_norm = np.clip((L_512 - p_low) / span * 0.92 + 0.04, 0.0, 1.0).astype(np.float32)

    inp = L_norm[None, None, :, :]  # [1, 1, 512, 512]
    out_ab = col_model.predict({"input_luma": inp})["output_ab"][0]  # [2, 512, 512] in [-1, 1]
    pred_ab_512 = np.transpose(out_ab, (1, 2, 0)) * 110.0

    # 元解像度へ戻して合成
    h, w = orig_rgb.shape[:2]
    a_up = np.asarray(Image.fromarray(pred_ab_512[..., 0]).resize((w, h), Image.Resampling.BILINEAR))
    b_up = np.asarray(Image.fromarray(pred_ab_512[..., 1]).resize((w, h), Image.Resampling.BILINEAR))
    pred_lab = np.stack([orig_lab[..., 0], a_up, b_up], axis=-1)
    pred_rgb = lab_to_rgb(pred_lab)
    return orig_rgb, pred_rgb, pred_ab_512


def make_contact_sheet(rows: List[Tuple[str, Image.Image, Image.Image, Optional[Image.Image]]], out_path: str, cell_w: int = 320, cell_h: int = 320):
    """(label, gray_input, ai_pred, gt_color_or_None) のリストから比較シートを作成"""
    if not rows:
        return
    cols = 3 if rows[0][3] is not None else 2
    pad = 12
    header = 26
    W = cols * (cell_w + pad) + pad
    H = len(rows) * (cell_h + header + pad) + pad
    canvas = Image.new("RGB", (W, H), (24, 24, 28))
    draw = ImageDraw.Draw(canvas)

    for r_idx, (label, im_gray, im_pred, im_gt) in enumerate(rows):
        y0 = pad + r_idx * (cell_h + header + pad)
        draw.text((pad, y0), label, fill=(220, 220, 220))
        items = [im_gray, im_pred] + ([im_gt] if im_gt is not None else [])
        for c_idx, item in enumerate(items):
            x0 = pad + c_idx * (cell_w + pad)
            thumb = item.copy()
            thumb.thumbnail((cell_w, cell_h), Image.Resampling.LANCZOS)
            canvas.paste(thumb, (x0, y0 + header))
    canvas.save(out_path, quality=92)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", default="/Users/okano/マイドライブ/DEV/ViewStereo/学習用データ")
    parser.add_argument("--out-dir", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/colorizer_dataset")
    parser.add_argument("--seg-model", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/StereoCardSeg.mlpackage")
    parser.add_argument("--col-model", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/StereoColorizer.mlpackage")
    parser.add_argument("--report-dir", default="/Users/okano/.gemini/antigravity/brain/a8507f4e-e2bc-4a0a-854e-047b4ff462b6")
    args = parser.parse_args()

    print("Loading Core ML models...")
    seg_model = ct.models.MLModel(args.seg_model)
    col_model = ct.models.MLModel(args.col_model)

    os.makedirs(os.path.join(args.out_dir, "hand_tinted"), exist_ok=True)
    os.makedirs(os.path.join(args.out_dir, "monochrome"), exist_ok=True)

    exts = ("*.jpg", "*.jpeg", "*.png", "*.tif", "*.tiff")
    paths = []
    for e in exts:
        paths.extend(glob.glob(os.path.join(args.data_dir, e)))
    paths = sorted(paths)

    seen_hashes: List[Tuple[int, int, str]] = []  # (dhash, pixel_area, path)
    unique_items = []
    skipped_dup = 0
    skipped_seg = 0

    for p in paths:
        try:
            im = Image.open(p).convert("RGB")
        except Exception:
            continue
        h_val = dhash(im)
        area = im.size[0] * im.size[1]
        # ハミング距離 <= 4 を重複とみなす（大きい解像度を優先）
        dup_idx = None
        for idx, (sh, sa, _) in enumerate(seen_hashes):
            if bin(h_val ^ sh).count("1") <= 4:
                dup_idx = idx
                break
        if dup_idx is not None:
            skipped_dup += 1
            if area > seen_hashes[dup_idx][1]:
                seen_hashes[dup_idx] = (h_val, area, p)
                unique_items[dup_idx] = (p, im)
            continue
        seen_hashes.append((h_val, area, p))
        unique_items.append((p, im))

    print(f"Total files: {len(paths)}, Unique cards: {len(unique_items)}, Skipped duplicates: {skipped_dup}")

    ht_records = []
    mono_records = []
    delta_es = []
    chroma_ratios = []
    ht_sheet_rows = []
    mono_sheet_rows = []

    for p, im in unique_items:
        boxes = extract_lr_boxes(seg_model, im)
        if boxes is None:
            skipped_seg += 1
            continue
        base = os.path.splitext(os.path.basename(p))[0]
        box_l, box_r = boxes
        crop_l = im.crop(box_l)
        crop_r = im.crop(box_r)
        info = classify_color_nature(crop_l)

        sub_dir = "hand_tinted" if info["is_color"] else "monochrome"
        out_l = os.path.join(args.out_dir, sub_dir, f"{base}_L.jpg")
        out_r = os.path.join(args.out_dir, sub_dir, f"{base}_R.jpg")
        crop_l.save(out_l, quality=95)
        crop_r.save(out_r, quality=95)

        # 現在の StereoColorizer で推論検証
        orig_rgb, pred_rgb, _ = run_colorizer(col_model, crop_l)
        orig_lab = rgb_to_lab(orig_rgb)
        pred_lab = rgb_to_lab(pred_rgb)

        if info["is_color"]:
            # 定量評価: ab 平面での色差 (Delta E_ab) と 彩度比
            de_ab = float(np.mean(np.sqrt((orig_lab[..., 1] - pred_lab[..., 1])**2 + (orig_lab[..., 2] - pred_lab[..., 2])**2)))
            orig_c = float(np.mean(np.sqrt(orig_lab[..., 1]**2 + orig_lab[..., 2]**2)))
            pred_c = float(np.mean(np.sqrt(pred_lab[..., 1]**2 + pred_lab[..., 2]**2)))
            delta_es.append(de_ab)
            chroma_ratios.append(pred_c / max(1e-3, orig_c))
            ht_records.append({"name": base, "de_ab": de_ab, "orig_c": orig_c, "pred_c": pred_c, **info})
            if len(ht_sheet_rows) < 6:
                gray_im = crop_l.convert("L").convert("RGB")
                pred_im = Image.fromarray((pred_rgb * 255).astype(np.uint8))
                ht_sheet_rows.append((f"{base} (GT vs AI, dE={de_ab:.1f})", gray_im, pred_im, crop_l))
        else:
            pred_c = float(np.mean(np.sqrt(pred_lab[..., 1]**2 + pred_lab[..., 2]**2)))
            mono_records.append({"name": base, "pred_c": pred_c, **info})
            if len(mono_sheet_rows) < 6:
                gray_im = crop_l.convert("L").convert("RGB")
                pred_im = Image.fromarray((pred_rgb * 255).astype(np.uint8))
                mono_sheet_rows.append((f"{base} (Input vs AI, meanC={pred_c:.1f})", gray_im, pred_im, None))

    ht_sheet_path = os.path.join(args.report_dir, "baseline_hand_tinted_eval.jpg")
    mono_sheet_path = os.path.join(args.report_dir, "baseline_monochrome_eval.jpg")
    make_contact_sheet(ht_sheet_rows, ht_sheet_path)
    make_contact_sheet(mono_sheet_rows, mono_sheet_path)

    summary = {
        "total_files": len(paths),
        "unique_cards": len(unique_items),
        "skipped_duplicates": skipped_dup,
        "skipped_seg_failed": skipped_seg,
        "hand_tinted_cards": len(ht_records),
        "hand_tinted_lr_crops": len(ht_records) * 2,
        "monochrome_cards": len(mono_records),
        "monochrome_lr_crops": len(mono_records) * 2,
        "baseline_mean_delta_e_ab": float(np.mean(delta_es)) if delta_es else None,
        "baseline_mean_chroma_ratio": float(np.mean(chroma_ratios)) if chroma_ratios else None,
        "baseline_mono_mean_chroma": float(np.mean([r["pred_c"] for r in mono_records])) if mono_records else None,
    }
    with open(os.path.join(args.out_dir, "dataset_summary.json"), "w", encoding="utf-8") as fp:
        json.dump(summary, fp, ensure_ascii=False, indent=2)

    print("\n=== SUMMARY ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
