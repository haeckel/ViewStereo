#!/usr/bin/env python3
"""
Phase 2-3 隠れミス検品スクリプト（改良版）:
dataset_3class/masks/*.png と images/*.png から LR% では検知できないズレ
- 左右外周余白の非対称度 (margin_asym_pct)
- 中央境界位置の偏り (split_bias_pct)
- 左右マスクの高さ差 (top_diff_pct, bot_diff_pct)
- 外周各辺の「内側台紙はみ出し率」(worst_edge_inner_mount_pct)
- 外周各辺の「外側写真切り落とし率」(worst_edge_outer_photo_pct)
- 左右対応辺の非対称度 (lr_edge_asym_pct)
- ステレオ切り抜き同士の水平シフトズレ (stereo_shift_x_pct)
を算出し、怪しい順に anomaly_ranking.csv へ出力する。
"""

import csv
import glob
import os
import shutil
import numpy as np
from PIL import Image

DATASET_ROOT = "/Users/okano/マイドライブ/DEV/ViewStereo/dataset_3class"
EVAL_MAX_W = 640


def compute_stereo_shift_x(rgb: np.ndarray, mL: np.ndarray, mR: np.ndarray) -> float:
    ysL, xsL = np.where(mL)
    ysR, xsR = np.where(mR)
    if len(xsL) < 16 or len(xsR) < 16:
        return 0.0
    x0L, x1L, y0L, y1L = int(xsL.min()), int(xsL.max()) + 1, int(ysL.min()), int(ysL.max()) + 1
    x0R, x1R, y0R, y1R = int(xsR.min()), int(xsR.max()) + 1, int(ysR.min()), int(ysR.max()) + 1

    gray = rgb.mean(axis=2)
    cropL = Image.fromarray(gray[y0L:y1L, x0L:x1L].astype(np.uint8)).resize((128, 128), Image.Resampling.BILINEAR)
    cropR = Image.fromarray(gray[y0R:y1R, x0R:x1R].astype(np.uint8)).resize((128, 128), Image.Resampling.BILINEAR)
    a = np.asarray(cropL, dtype=np.float32)
    b = np.asarray(cropR, dtype=np.float32)

    # 中央帯 [y: 16..112] を使って上下のアーチ角丸の影響を減らす
    a_mid = a[16:112, :]
    b_mid = b[16:112, :]

    best_dx = 0
    best_ncc = -1e9
    for dx in range(-24, 25):
        if dx >= 0:
            subA = a_mid[:, dx:]
            subB = b_mid[:, :128 - dx]
        else:
            subA = a_mid[:, :128 + dx]
            subB = b_mid[:, -dx:]
        va = subA - subA.mean()
        vb = subB - subB.mean()
        denom = float(np.sqrt(np.sum(va * va) * np.sum(vb * vb)))
        ncc = float(np.sum(va * vb)) / denom if denom > 1e-6 else 0.0
        if ncc > best_ncc:
            best_ncc = ncc
            best_dx = dx

    return abs(best_dx) / 128.0 * 100.0


def compute_metrics_for_pair(img_path: str, mask_path: str):
    with Image.open(img_path) as im_raw, Image.open(mask_path) as mk_raw:
        im_rgb = im_raw.convert("RGB")
        mk_l = mk_raw.convert("L")
        orig_w, orig_h = mk_l.size
        if orig_w > EVAL_MAX_W:
            scale = EVAL_MAX_W / float(orig_w)
            ew = EVAL_MAX_W
            eh = max(32, int(round(orig_h * scale)))
            im_eval = im_rgb.resize((ew, eh), Image.Resampling.BILINEAR)
            mk_eval = mk_l.resize((ew, eh), Image.Resampling.NEAREST)
        else:
            ew, eh = orig_w, orig_h
            im_eval = im_rgb
            mk_eval = mk_l

        rgb = np.asarray(im_eval, dtype=np.float32)
        lbl = np.asarray(mk_eval, dtype=np.uint8)

    mL = (lbl == 1)
    mR = (lbl == 2)
    ysL, xsL = np.where(mL)
    ysR, xsR = np.where(mR)

    if len(xsL) < 16 or len(xsR) < 16:
        return {
            "anomaly_score": 999.0,
            "margin_asym_pct": 100.0,
            "split_bias_pct": 50.0,
            "width_asym_pct": 100.0,
            "top_diff_pct": 100.0,
            "bot_diff_pct": 100.0,
            "worst_edge_inner_mount_pct": 100.0,
            "worst_edge_outer_photo_pct": 100.0,
            "lr_edge_asym_pct": 100.0,
            "stereo_shift_x_pct": 50.0,
            "low_edge_pct": 100.0,
            "flags": "EMPTY_MASK",
        }

    minXL, maxXL = int(xsL.min()), int(xsL.max())
    minYL, maxYL = int(ysL.min()), int(ysL.max())
    minXR, maxXR = int(xsR.min()), int(xsR.max())
    minYR, maxYR = int(ysR.min()), int(ysR.max())

    left_margin = float(minXL)
    right_margin = float((ew - 1) - maxXR)
    margin_asym = abs(left_margin - right_margin) / float(ew)

    split_x = 0.5 * (float(maxXL) + float(minXR))
    split_bias = abs(split_x / float(ew) - 0.50)

    wL = max(1, maxXL - minXL + 1)
    wR = max(1, maxXR - minXR + 1)
    width_asym = abs(wL - wR) / float(max(wL, wR))

    top_diff_pct = abs(minYL - minYR) / float(eh) * 100.0
    bot_diff_pct = abs(maxYL - maxYR) / float(eh) * 100.0

    # 台紙代表色 + 分散推定（上下左右の外周背景帯のうちスキャン黒縁・極白を除いた画素）
    bg_mask = (lbl == 0)
    luma = rgb.mean(axis=2)
    outer_band = np.zeros_like(bg_mask)
    bx = max(4, int(ew * 0.055))
    by = max(4, int(eh * 0.075))
    outer_band[:by, :] = True
    outer_band[-by:, :] = True
    outer_band[:, :bx] = True
    outer_band[:, -bx:] = True
    mount_candidates = rgb[bg_mask & outer_band & (luma > 25.0) & (luma < 245.0)]
    if len(mount_candidates) >= 32:
        mount_rgb = np.median(mount_candidates, axis=0)
        mount_dists = np.linalg.norm(mount_candidates - mount_rgb, axis=1)
        mount_std = float(np.percentile(mount_dists, 75))
        has_mount_rgb = True
    else:
        mount_rgb = np.array([180.0, 170.0, 150.0], dtype=np.float32)
        mount_std = 12.0
        has_mount_rgb = False

    inner_mount_thresh = max(24.0, mount_std * 1.7)
    outer_photo_thresh = max(32.0, mount_std * 2.2)

    pad_lbl = np.pad(lbl, 1, mode="constant", constant_values=0)
    is_bL = mL & (
        (pad_lbl[:-2, 1:-1] != 1)
        | (pad_lbl[2:, 1:-1] != 1)
        | (pad_lbl[1:-1, :-2] != 1)
        | (pad_lbl[1:-1, 2:] != 1)
    )
    is_bR = mR & (
        (pad_lbl[:-2, 1:-1] != 2)
        | (pad_lbl[2:, 1:-1] != 2)
        | (pad_lbl[1:-1, :-2] != 2)
        | (pad_lbl[1:-1, 2:] != 2)
    )

    frame_pad_x = max(3, int(round(ew * 0.025)))
    frame_pad_y = max(3, int(round(eh * 0.025)))

    def eval_side_edges(side_id: int, bound_mask: np.ndarray, minX: int, maxX: int, minY: int, maxY: int):
        ys, xs = np.where(bound_mask)
        res = {
            "inner_mount": {},  # dir -> ratio
            "outer_photo": {},  # dir -> ratio
            "low_edge": [],
        }
        if len(xs) == 0:
            return res

        cx = 0.5 * (minX + maxX)
        cy = 0.5 * (minY + maxY)
        vx = xs - cx
        vy = ys - cy
        norm = np.maximum(1.0, np.hypot(vx, vy))
        ux = vx / norm
        uy = vy / norm

        # 内側 2px / 4px、外側 4px
        in2x = np.clip(np.round(xs - ux * 2.0).astype(np.int32), 0, ew - 1)
        in2y = np.clip(np.round(ys - uy * 2.0).astype(np.int32), 0, eh - 1)
        in4x = np.clip(np.round(xs - ux * 4.0).astype(np.int32), 0, ew - 1)
        in4y = np.clip(np.round(ys - uy * 4.0).astype(np.int32), 0, eh - 1)
        out4x = np.clip(np.round(xs + ux * 4.0).astype(np.int32), 0, ew - 1)
        out4y = np.clip(np.round(ys + uy * 4.0).astype(np.int32), 0, eh - 1)

        in_rgb = 0.5 * (rgb[in2y, in2x] + rgb[in4y, in4x])
        out4_rgb = rgb[out4y, out4x]
        delta4 = np.linalg.norm(in_rgb - out4_rgb, axis=1)

        valid_out4 = (
            (out4x >= frame_pad_x) & (out4x < ew - frame_pad_x)
            & (out4y >= frame_pad_y) & (out4y < eh - frame_pad_y)
            & (lbl[out4y, out4x] == 0)
        )
        if np.any(valid_out4):
            res["low_edge"] = (delta4[valid_out4] < 22.0).tolist()

        # 外側 5px, 10px, 15px (切り落とし検知用)
        out_samples = []
        out_valids = []
        for dist in (5.0, 10.0, 15.0):
            ox = np.clip(np.round(xs + ux * dist).astype(np.int32), 0, ew - 1)
            oy = np.clip(np.round(ys + uy * dist).astype(np.int32), 0, eh - 1)
            v = (
                (ox >= frame_pad_x) & (ox < ew - frame_pad_x)
                & (oy >= frame_pad_y) & (oy < eh - frame_pad_y)
                & (lbl[oy, ox] == 0)
            )
            out_samples.append((ox, oy))
            out_valids.append(v)

        dir_defs = {
            "top": (uy < -0.50),
            "bot": (uy > 0.55),
            "left": (ux < -0.55),
            "right": (ux > 0.55),
        }

        if has_mount_rgb:
            d_in_mount = np.linalg.norm(in_rgb - mount_rgb, axis=1)
            is_inner_mount = valid_out4 & (d_in_mount < inner_mount_thresh) & (delta4 < 26.0)

            # 外側5/10/15pxのうち有効な背景点で台紙色から大きく乖離（写真画素が残っている）かつスキャン黒枠でない
            photo_hits = np.zeros(len(xs), dtype=bool)
            valid_any_outer = np.zeros(len(xs), dtype=bool)
            for (ox, oy), v in zip(out_samples, out_valids):
                o_rgb = rgb[oy, ox]
                o_luma = o_rgb.mean(axis=1)
                d_out_mount = np.linalg.norm(o_rgb - mount_rgb, axis=1)
                v_non_scan = v & (o_luma > 22.0) & (o_luma < 246.0)
                valid_any_outer |= v_non_scan
                photo_hits |= (v_non_scan & (d_out_mount > outer_photo_thresh))

            for d_name, d_mask in dir_defs.items():
                m_in = d_mask & valid_out4
                if np.sum(m_in) >= 12:
                    res["inner_mount"][d_name] = float(np.mean(is_inner_mount[m_in])) * 100.0
                # 外周辺のみ（中央境界は反対側写真が近いので除外）
                is_outer_side_edge = (
                    (d_name == "top")
                    or (d_name == "left" and side_id == 1)
                    or (d_name == "right" and side_id == 2)
                )
                if is_outer_side_edge:
                    m_out = d_mask & valid_any_outer
                    if np.sum(m_out) >= 12:
                        res["outer_photo"][d_name] = float(np.mean(photo_hits[m_out])) * 100.0

        return res

    resL = eval_side_edges(1, is_bL, minXL, maxXL, minYL, maxYL)
    resR = eval_side_edges(2, is_bR, minXR, maxXR, minYR, maxYR)

    all_inner = list(resL["inner_mount"].values()) + list(resR["inner_mount"].values())
    worst_edge_inner_mount_pct = max(all_inner) if all_inner else 0.0

    all_outer = list(resL["outer_photo"].values()) + list(resR["outer_photo"].values())
    worst_edge_outer_photo_pct = max(all_outer) if all_outer else 0.0

    # 左右対応辺の非対称度（左プリントの外側左辺 vs 右プリントの外側右辺、上辺同士、内側辺同士）
    asym_diffs = []
    if "left" in resL["inner_mount"] and "right" in resR["inner_mount"]:
        asym_diffs.append(abs(resL["inner_mount"]["left"] - resR["inner_mount"]["right"]))
    if "top" in resL["inner_mount"] and "top" in resR["inner_mount"]:
        asym_diffs.append(abs(resL["inner_mount"]["top"] - resR["inner_mount"]["top"]))
    if "bot" in resL["inner_mount"] and "bot" in resR["inner_mount"]:
        asym_diffs.append(abs(resL["inner_mount"]["bot"] - resR["inner_mount"]["bot"]))
    if "left" in resL["outer_photo"] and "right" in resR["outer_photo"]:
        asym_diffs.append(abs(resL["outer_photo"]["left"] - resR["outer_photo"]["right"]))
    if "top" in resL["outer_photo"] and "top" in resR["outer_photo"]:
        asym_diffs.append(abs(resL["outer_photo"]["top"] - resR["outer_photo"]["top"]))
    lr_edge_asym_pct = max(asym_diffs) if asym_diffs else 0.0

    all_low = resL["low_edge"] + resR["low_edge"]
    low_edge_pct = (float(np.mean(all_low)) * 100.0) if all_low else 0.0

    stereo_shift_x_pct = compute_stereo_shift_x(rgb, mL, mR)

    anomaly_score = (
        margin_asym * 100.0 * 0.45
        + split_bias * 100.0 * 0.65
        + width_asym * 100.0 * 0.35
        + (top_diff_pct + bot_diff_pct) * 0.40
        + worst_edge_inner_mount_pct * 0.32
        + worst_edge_outer_photo_pct * 0.25
        + lr_edge_asym_pct * 0.28
        + max(0.0, stereo_shift_x_pct - 4.0) * 1.5
        + low_edge_pct * 0.12
    )

    flags = []
    if margin_asym >= 0.035:
        flags.append(f"margin_asym({margin_asym*100:.1f}%)")
    if split_bias >= 0.025:
        flags.append(f"split_bias({split_bias*100:.1f}%)")
    if width_asym >= 0.045:
        flags.append(f"width_asym({width_asym*100:.1f}%)")
    if top_diff_pct >= 2.5 or bot_diff_pct >= 2.5:
        flags.append(f"height_diff(T={top_diff_pct:.1f}%,B={bot_diff_pct:.1f}%)")
    if worst_edge_inner_mount_pct >= 22.0:
        flags.append(f"inner_mount({worst_edge_inner_mount_pct:.0f}%)")
    if worst_edge_outer_photo_pct >= 30.0:
        flags.append(f"outer_photo({worst_edge_outer_photo_pct:.0f}%)")
    if lr_edge_asym_pct >= 22.0:
        flags.append(f"lr_edge_asym({lr_edge_asym_pct:.0f}%)")
    if stereo_shift_x_pct >= 7.0:
        flags.append(f"stereo_shift({stereo_shift_x_pct:.1f}%)")

    return {
        "anomaly_score": anomaly_score,
        "margin_asym_pct": margin_asym * 100.0,
        "split_bias_pct": split_bias * 100.0,
        "width_asym_pct": width_asym * 100.0,
        "top_diff_pct": top_diff_pct,
        "bot_diff_pct": bot_diff_pct,
        "worst_edge_inner_mount_pct": worst_edge_inner_mount_pct,
        "worst_edge_outer_photo_pct": worst_edge_outer_photo_pct,
        "lr_edge_asym_pct": lr_edge_asym_pct,
        "stereo_shift_x_pct": stereo_shift_x_pct,
        "low_edge_pct": low_edge_pct,
        "flags": "; ".join(flags) if flags else "ok",
    }


def main():
    summary_csv = os.path.join(DATASET_ROOT, "review_summary.csv")
    meta_by_stem = {}
    if os.path.exists(summary_csv):
        with open(summary_csv, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                meta_by_stem[r["stem"]] = r

    mask_paths = sorted(glob.glob(os.path.join(DATASET_ROOT, "masks", "*.png")))
    results = []
    aspect_outliers = []
    for mp in mask_paths:
        stem = os.path.splitext(os.path.basename(mp))[0]
        ip = os.path.join(DATASET_ROOT, "images", f"{stem}.png")
        if not os.path.exists(ip):
            continue
        with Image.open(ip) as im_sz:
            iw, ih = im_sz.size
            ar = iw / float(max(1, ih))
            if ar < 1.35 or ar > 2.45 or "default" in stem.lower():
                aspect_outliers.append((stem, iw, ih, ar))
        m = compute_metrics_for_pair(ip, mp)
        meta = meta_by_stem.get(stem, {})
        results.append({
            "stem": stem,
            "filename": meta.get("filename", f"{stem}.png"),
            "is_priority": meta.get("is_priority", "false"),
            "lr_pct": meta.get("lr_pct", ""),
            **m,
        })

    results.sort(key=lambda x: x["anomaly_score"], reverse=True)

    # 上位40件のシンボリックリンクフォルダ _review_top40 を再生成
    top40_dir = os.path.join(DATASET_ROOT, "_review_top40")
    if os.path.exists(top40_dir):
        shutil.rmtree(top40_dir)
    os.makedirs(top40_dir, exist_ok=True)
    for rank, r in enumerate(results[:40], start=1):
        vis_name = f"{r['stem']}_vis.png"
        src_rel = os.path.join("..", "previews", vis_name)
        src_abs = os.path.join(DATASET_ROOT, "previews", vis_name)
        if os.path.exists(src_abs):
            dst_link = os.path.join(top40_dir, f"{rank:03d}_{vis_name}")
            os.symlink(src_rel, dst_link)

    out_csv = os.path.join(DATASET_ROOT, "anomaly_ranking.csv")
    fieldnames = [
        "rank", "stem", "filename", "is_priority", "anomaly_score",
        "margin_asym_pct", "split_bias_pct", "width_asym_pct",
        "top_diff_pct", "bot_diff_pct",
        "worst_edge_inner_mount_pct", "worst_edge_outer_photo_pct",
        "lr_edge_asym_pct", "stereo_shift_x_pct", "low_edge_pct",
        "lr_pct", "flags"
    ]
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for rank, row in enumerate(results, start=1):
            row_out = dict(row)
            row_out["rank"] = rank
            for k in [
                "anomaly_score", "margin_asym_pct", "split_bias_pct", "width_asym_pct",
                "top_diff_pct", "bot_diff_pct",
                "worst_edge_inner_mount_pct", "worst_edge_outer_photo_pct",
                "lr_edge_asym_pct", "stereo_shift_x_pct", "low_edge_pct",
            ]:
                row_out[k] = f"{row_out[k]:.2f}"
            w.writerow(row_out)

    print(f"RANKED_TOTAL={len(results)} -> {out_csv}")
    print("=== TOP 30 ANOMALIES ===")
    for rank, r in enumerate(results[:30], start=1):
        print(
            f"#{rank:2d} {r['stem']} | score={r['anomaly_score']:.2f} | prio={r['is_priority']} | "
            f"inM={r['worst_edge_inner_mount_pct']:.0f}% outP={r['worst_edge_outer_photo_pct']:.0f}% "
            f"lrE={r['lr_edge_asym_pct']:.0f}% shiftX={r['stereo_shift_x_pct']:.1f}% "
            f"mAsym={r['margin_asym_pct']:.1f}% split={r['split_bias_pct']:.1f}% | {r['flags']}"
        )

    known = {
        "11410-5653",
        "11409-6066",
        "11602-7575-1",
        "5416ea6e-aa81-423c-aca2-aa267b353b83_6439",
    }
    print("=== KNOWN 4 CASES RANKS ===")
    for rank, r in enumerate(results, start=1):
        if r["stem"] in known:
            print(
                f"#{rank:3d} {r['stem']} | score={r['anomaly_score']:.2f} | "
                f"inM={r['worst_edge_inner_mount_pct']:.0f}% outP={r['worst_edge_outer_photo_pct']:.0f}% "
                f"lrE={r['lr_edge_asym_pct']:.0f}% shiftX={r['stereo_shift_x_pct']:.1f}% "
                f"mAsym={r['margin_asym_pct']:.1f}% split={r['split_bias_pct']:.1f}% | {r['flags']}"
            )

    flagged = [r for r in results if r["flags"] != "ok"]
    print(f"FLAGGED_COUNT={len(flagged)} / {len(results)}")
    print(f"TOP40_SYMLINKS_CREATED={min(40, len(results))} -> {top40_dir}")
    print(f"ASPECT_OR_SPECIAL_OUTLIERS={len(aspect_outliers)}")
    for stem, iw, ih, ar in aspect_outliers:
        print(f"  OUTLIER: {stem} | size={iw}x{ih} | aspect={ar:.3f}")


if __name__ == "__main__":
    main()
