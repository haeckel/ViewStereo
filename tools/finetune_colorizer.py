#!/usr/bin/env python3
"""
施策 4: 教師データの『鶏卵紙ホワイトバランス補正（脱黄変）』+ DDColor 知識保持アンカー正則化による
StereoColorizer (103ch -> 2ch 最終層) のファインチューニング & Core ML モデル統合スクリプト。
"""

import argparse
import glob
import os
import random
import shutil
import subprocess
from typing import List, Tuple

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageOps

from prepare_and_eval_colorizer import rgb_to_lab, lab_to_rgb, make_contact_sheet


def extract_head_weights_raw(src_mlpackage: str) -> Tuple[np.ndarray, np.ndarray]:
    """StereoColorizer.mlpackage から現在の 103->2 重みとバイアスを取得 (既に 1/110 スケール済み)"""
    m = ct.models.MLModel(src_mlpackage)
    spec = m.get_spec()
    block = spec.mlProgram.functions["main"].block_specializations["CoreML7"]
    bias = None
    weight = None
    for op in block.operations:
        for out in op.outputs:
            if out.name == "core_refine_net_0_0_bias":
                bias = np.array(list(op.attributes["val"].immediateValue.tensor.floats.values), dtype=np.float32)
            elif out.name == "weight_193":
                offset = op.attributes["val"].blobFileValue.offset
                wpath = os.path.join(src_mlpackage, "Data/com.apple.CoreML/weights/weight.bin")
                with open(wpath, "rb") as wf:
                    wf.seek(offset + 64)
                    weight = np.frombuffer(wf.read(2 * 103 * 4), dtype=np.float32).copy().reshape(2, 103, 1, 1)
    assert bias is not None and weight is not None
    # 万が一まだ 1/110 されていなければ自動で正規化
    if np.abs(weight).max() > 0.02:
        weight = weight / 110.0
        bias = bias / 110.0
    return weight, bias


def write_head_weights_to_mlpackage(mlpackage_path: str, weight: np.ndarray, bias: np.ndarray) -> None:
    """学習済み 103->2 重み ([-1, 1] スケール) を StereoColorizer.mlpackage に書き戻す"""
    m = ct.models.MLModel(mlpackage_path)
    spec = m.get_spec()
    block = spec.mlProgram.functions["main"].block_specializations["CoreML7"]
    w_flat = weight.astype(np.float32).reshape(2 * 103)
    b_list = [float(x) for x in bias.astype(np.float32).reshape(2)]

    for op in block.operations:
        for out in op.outputs:
            if out.name == "core_refine_net_0_0_bias":
                op.attributes["val"].immediateValue.tensor.floats.values[:] = b_list
            elif out.name == "weight_193":
                offset = op.attributes["val"].blobFileValue.offset
                wpath = os.path.join(mlpackage_path, "Data/com.apple.CoreML/weights/weight.bin")
                with open(wpath, "r+b") as wf:
                    wf.seek(offset + 64)
                    wf.write(w_flat.tobytes())

    ct.models.utils.save_spec(spec, os.path.join(mlpackage_path, "Data/com.apple.CoreML/model.mlmodel"))


def deyellow_paper_ab(L: np.ndarray, a: np.ndarray, b: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """
    明治期の鶏卵紙手彩色カードから『紙自体の黄変・セピア地色』を推定して差し引き、
    職人が塗った水彩染料（赤・青・緑・肌色）の純粋な色度成分を抽出する。
    """
    # 外周 8% を除いた内側領域で推定
    h, w = L.shape
    mh, mw = int(h * 0.08), int(w * 0.08)
    L_in = L[mh:h - mh, mw:w - mw]
    a_in = a[mh:h - mh, mw:w - mw]
    b_in = b[mh:h - mh, mw:w - mw]

    # 中間〜明部 (L in [35, 88]) のうち、彩度が比較的低い（紙の地色が支配的な下位 35%）画素の中央値を紙の地色とする
    c_in = np.sqrt(a_in**2 + b_in**2)
    mask_mid = (L_in >= 35.0) & (L_in <= 88.0)
    if np.sum(mask_mid) >= 64:
        c_thresh = np.percentile(c_in[mask_mid], 35)
        paper_mask = mask_mid & (c_in <= max(4.0, c_thresh))
        if np.sum(paper_mask) >= 16:
            paper_a = float(np.median(a_in[paper_mask]))
            paper_b = float(np.median(b_in[paper_mask]))
        else:
            paper_a = float(np.median(a_in[mask_mid])) * 0.7
            paper_b = float(np.median(b_in[mask_mid])) * 0.7
    else:
        paper_a = float(np.median(a_in)) * 0.7
        paper_b = float(np.median(b_in)) * 0.7

    # 紙の黄変除去: a >= -1.0 (肌・背景・暖色) の画素が負 (緑) に反転するのを厳密に防ぎ、元の緑・青領域はそのまま保持する
    shift_a = max(0.0, paper_a - 3.5) * 0.45
    shift_b = max(0.0, paper_b - 4.0) * 0.65
    clean_a = np.where(a >= -1.0, np.maximum(0.5, a - shift_a), a)
    clean_b = np.where(b >= -1.0, np.maximum(1.0, b - shift_b), b)

    # 脱黄変後の P90 彩度が手彩色の理想レンジ (24〜28) になるよう緩やかにゲイン補正
    c_clean = np.sqrt(clean_a[mh:h - mh, mw:w - mw]**2 + clean_b[mh:h - mh, mw:w - mw]**2)
    p90 = float(np.percentile(c_clean, 90))
    if p90 > 4.0:
        target_p90 = 25.0
        gain = min(1.65, max(0.75, target_p90 / p90))
        clean_a = np.clip(clean_a * gain, -100.0, 100.0)
        clean_b = np.clip(clean_b * gain, -100.0, 100.0)

    return clean_a.astype(np.float32), clean_b.astype(np.float32)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/colorizer_dataset/hand_tinted")
    parser.add_argument("--src-model", default="/Users/okano/マイドライブ/DEV/ViewStereo/tools/StereoColorizer.mlpackage")
    parser.add_argument("--res-dir", default="/Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Resources")
    parser.add_argument("--scratch-dir", default="/Users/okano/.gemini/antigravity/brain/a8507f4e-e2bc-4a0a-854e-047b4ff462b6/scratch")
    parser.add_argument("--report-dir", default="/Users/okano/.gemini/antigravity/brain/a8507f4e-e2bc-4a0a-854e-047b4ff462b6")
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--lr", type=float, default=4e-4)
    args = parser.parse_args()

    cache_dir = os.path.join(args.scratch_dir, "feat_cache")
    clean_base_pkg = os.path.join(args.scratch_dir, "StereoColorizer_scaled.mlpackage")
    weight_src = clean_base_pkg if os.path.exists(clean_base_pkg) else args.src_model
    init_w, init_b = extract_head_weights_raw(weight_src)
    print(f"Loaded initial 103->2 weights from {os.path.basename(weight_src)}: w_std={init_w.std():.6f}, b={init_b}")

    all_files = sorted(glob.glob(os.path.join(args.data_dir, "*.jpg")))
    items = []
    for fpath in all_files:
        base = os.path.splitext(os.path.basename(fpath))[0]
        cpath = os.path.join(cache_dir, f"{base}.npz")
        if not os.path.exists(cpath):
            continue
        im_chk = Image.open(fpath).convert("RGB").resize((256, 256), Image.Resampling.BILINEAR)
        lab_chk = rgb_to_lab(np.asarray(im_chk, dtype=np.float32) / 255.0)
        a_c = lab_chk[25:230, 25:230, 1]
        b_c = lab_chk[25:230, 25:230, 2]
        neg_ratio = float(np.mean((a_c < -3.0) | (b_c < -3.0)))
        ab_std = float(np.std(a_c) + np.std(b_c))
        if neg_ratio > 0.05 or ab_std > 14.0:
            clean_a, clean_b = deyellow_paper_ab(lab_chk[..., 0], lab_chk[..., 1], lab_chk[..., 2])
            clean_ab_norm = np.stack([clean_a / 110.0, clean_b / 110.0], axis=0)  # [2, 256, 256]
            items.append((base, fpath, cpath, clean_ab_norm))

    print(f"Selected {len(items)} de-yellowed multi-hue hand-tinted crops.")

    card_names = sorted(list({b[:-2] for b, _, _, _ in items}))
    rng = random.Random(42)
    rng.shuffle(card_names)
    val_count = max(6, int(len(card_names) * 0.15))
    val_cards = set(card_names[:val_count])
    train_items = [it for it in items if it[0][:-2] not in val_cards]
    val_items = [it for it in items if it[0][:-2] in val_cards]

    def load_split(item_list):
        feats, abs_clean = [], []
        for _, _, cp, cab in item_list:
            d = np.load(cp)
            feats.append(torch.from_numpy(d["feat"].astype(np.float32)))
            abs_clean.append(torch.from_numpy(cab.astype(np.float32)))
        return torch.stack(feats), torch.stack(abs_clean)

    tr_x, tr_y = load_split(train_items)
    va_x, va_y = load_split(val_items)

    # 元の DDColor ヘッドを教師アンカーとして保持
    orig_head = nn.Conv2d(103, 2, kernel_size=1, bias=True)
    head = nn.Conv2d(103, 2, kernel_size=1, bias=True)
    with torch.no_grad():
        orig_head.weight.copy_(torch.from_numpy(init_w))
        orig_head.bias.copy_(torch.from_numpy(init_b))
        head.weight.copy_(torch.from_numpy(init_w))
        head.bias.copy_(torch.from_numpy(init_b))
    orig_head.eval()
    for p in orig_head.parameters():
        p.requires_grad_(False)

    optimizer = torch.optim.AdamW(head.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    def eval_split(x_t, y_t):
        head.eval()
        with torch.no_grad():
            pred = torch.clamp(head(x_t), -1.0, 1.0)
            m = 16
            p_c = pred[:, :, m:-m, m:-m] * 110.0
            y_c = y_t[:, :, m:-m, m:-m] * 110.0
            de = torch.sqrt((p_c - y_c).pow(2).sum(dim=1)).mean().item()
            pc = torch.sqrt(p_c.pow(2).sum(dim=1)).mean().item()
            gc = torch.sqrt(y_c.pow(2).sum(dim=1)).mean().item()
        return de, pc / max(1e-3, gc)

    base_de, base_cr = eval_split(va_x, va_y)
    print(f"Baseline (De-yellowed Val): dE_ab = {base_de:.2f}, chroma_ratio = {base_cr:.2f}")

    batch_size = 16
    for epoch in range(1, args.epochs + 1):
        head.train()
        perm = torch.randperm(tr_x.size(0))
        for i in range(0, tr_x.size(0), batch_size):
            idx = perm[i:i + batch_size]
            bx, by = tr_x[idx], tr_y[idx]
            if random.random() < 0.5:
                bx = torch.flip(bx, dims=[3])
                by = torch.flip(by, dims=[3])

            pred = torch.clamp(head(bx), -1.0, 1.0)
            with torch.no_grad():
                orig_pred = torch.clamp(orig_head(bx), -1.0, 1.0)

            m = 16
            p_c = pred[:, :, m:-m, m:-m]
            y_c = by[:, :, m:-m, m:-m]
            o_c = orig_pred[:, :, m:-m, m:-m]

            # 1. 脱黄変した手彩色染料データとの一致ロス（彩度がある部分ほど重視）
            gt_c = torch.sqrt(y_c.pow(2).sum(dim=1, keepdim=True) + 1e-6)
            pred_c = torch.sqrt(p_c.pow(2).sum(dim=1, keepdim=True) + 1e-6)
            w_map = 1.0 + 3.5 * torch.clamp(gt_c * 3.0, 0.0, 1.0)
            loss_data = (F.smooth_l1_loss(p_c, y_c, beta=0.04, reduction="none") * w_map).mean()
            loss_chroma = F.l1_loss(pred_c, gt_c)

            # 2. DDColor の広範な色知識（青空・植物など orig_pred が強く反応している箇所）を忘れないためのアンカー正則化
            orig_c = torch.sqrt(o_c.pow(2).sum(dim=1, keepdim=True) + 1e-6)
            anchor_w = torch.clamp(orig_c * 4.0, 0.25, 1.0)
            loss_anchor = (F.mse_loss(p_c, o_c, reduction="none") * anchor_w).mean()
            loss_w_reg = F.mse_loss(head.weight, orig_head.weight)

            # 3. 肖像の肌や背景が不自然に緑被り (a < -2) しないためのソフトペナルティ (緑が正解の箇所を除く)
            unwanted_green = F.relu(-p_c[:, 0:1] - 0.04) * (y_c[:, 0:1] >= -0.01).float()
            loss_anti_green = unwanted_green.mean()

            loss = loss_data + 0.25 * loss_chroma + 0.85 * loss_anchor + 18.0 * loss_w_reg + 0.40 * loss_anti_green

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
        scheduler.step()

        if epoch % 15 == 0 or epoch == args.epochs:
            val_de, val_cr = eval_split(va_x, va_y)
            print(f"Epoch {epoch:02d}/{args.epochs} | Val dE_ab={val_de:.2f}, chroma_ratio={val_cr:.2f}")

    # 元の DDColor 重みと学習済み重みを 50:50 ブレンドして汎用性と古写真発色を両立
    with torch.no_grad():
        blended_w = (0.45 * orig_head.weight + 0.55 * head.weight).cpu().numpy()
        blended_b = (0.45 * orig_head.bias + 0.55 * head.bias).cpu().numpy()
        # バイアスによる大域色カブリをゼロにリセット（紙の温かみは Swift 側の paperWarmth で付与するため）
        blended_b[:] = 0.0

    write_head_weights_to_mlpackage(args.src_model, blended_w, blended_b)
    print("Updated Core ML model with de-yellowed finetuned weights:", args.src_model)
    subprocess.run(["xcrun", "coremlcompiler", "compile", args.src_model, args.res_dir], check=True)
    print("Compiled to:", args.res_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
