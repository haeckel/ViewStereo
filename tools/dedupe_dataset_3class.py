#!/usr/bin/env python3
"""
Phase 2-3 重複整理スクリプト:
dataset_3class/ 内の同一カード重複（リサイズ版・再保存版・_Card 版など）を
知覚ハッシュ (16x8 dHash) + ベース名正規化で検出し、
- 同色系重複: 最も高解像度（元画像優先）1枚のみ残し、他を _excluded_duplicates/ へ4ファイルセットごと移動
- 色表現違い (白黒版 vs =color版 等): 両方残し、Group Split 用のペア一覧を出力
"""

import argparse
import json
import os
import re
import shutil
from collections import defaultdict
import numpy as np
from PIL import Image

DATASET_ROOT = "/Users/okano/マイドライブ/DEV/ViewStereo/dataset_3class"


def compute_dhash_and_sat(img_path: str):
    with Image.open(img_path) as im:
        w, h = im.size
        rgb = im.convert("RGB")
        # 16x8 dHash (17x8 に縮小して横隣接差分を取る -> 128-bit)
        gray = rgb.convert("L").resize((17, 8), Image.Resampling.BILINEAR)
        g_arr = np.asarray(gray, dtype=np.int16)
        bits = (g_arr[:, 1:] > g_arr[:, :-1]).reshape(-1)

        # 中央領域 [15%..85%] の平均彩度 (max(RGB) - min(RGB))
        small = np.asarray(rgb.resize((96, 48), Image.Resampling.BILINEAR), dtype=np.float32)
        crop = small[7:41, 14:82]
        sat = float(np.mean(crop.max(axis=2) - crop.min(axis=2)))
        return w, h, bits, sat


def normalize_base_name(stem: str) -> str:
    s = stem.strip()
    # Flickr 系 <9〜12桁数値ID>_<8桁以上16進ハッシュ>_[obh](_Card)? （日付時刻 YYYYMMDD_HHMMSS は除外）
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


def read_meta(meta_path: str):
    if not os.path.exists(meta_path):
        return {}
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def is_color_variant_pair(item_a, item_b) -> bool:
    tag_a = "=color" in item_a["stem"].lower()
    tag_b = "=color" in item_b["stem"].lower()
    if tag_a != tag_b:
        return True
    sat_a, sat_b = item_a["sat"], item_b["sat"]
    if abs(sat_a - sat_b) >= 14.0 and min(sat_a, sat_b) < 20.0:
        return True
    return False


def choose_best_item(items):
    def rank_key(it):
        is_not_card_suffix = 0 if it["stem"].lower().endswith("_card") else 1
        is_manual = 1 if it["was_manual"] else 0
        pixels = it["w"] * it["h"]
        # 短い stem（無印）を同画素数では優先するためマイナス長
        return (is_not_card_suffix, is_manual, pixels, -len(it["stem"]))

    return max(items, key=rank_key)


def move_four_files(dataset_root: str, excl_root: str, stem: str):
    rel_paths = [
        ("images", f"{stem}.png"),
        ("masks", f"{stem}.png"),
        ("previews", f"{stem}_vis.png"),
        ("metadata", f"{stem}.json"),
    ]
    moved = []
    for sub, fname in rel_paths:
        src = os.path.join(dataset_root, sub, fname)
        dst_dir = os.path.join(excl_root, sub)
        dst = os.path.join(dst_dir, fname)
        if os.path.exists(src):
            os.makedirs(dst_dir, exist_ok=True)
            shutil.move(src, dst)
            moved.append(os.path.join(sub, fname))
    return moved


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default=DATASET_ROOT)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    dataset_root = args.dataset
    images_dir = os.path.join(dataset_root, "images")
    excl_root = os.path.join(dataset_root, "_excluded_duplicates")

    img_files = sorted(f for f in os.listdir(images_dir) if f.lower().endswith(".png") and not f.startswith("."))
    items = []
    for fname in img_files:
        stem = os.path.splitext(fname)[0]
        img_path = os.path.join(images_dir, fname)
        meta_path = os.path.join(dataset_root, "metadata", f"{stem}.json")
        w, h, bits, sat = compute_dhash_and_sat(img_path)
        meta = read_meta(meta_path)
        items.append({
            "stem": stem,
            "w": w,
            "h": h,
            "bits": bits,
            "sat": sat,
            "norm_base": normalize_base_name(stem),
            "was_manual": bool(meta.get("wasManuallyEdited", False)),
        })

    n = len(items)
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
            dist = int(np.sum(items[i]["bits"] != items[j]["bits"]))
            same_base = (items[i]["norm_base"] == items[j]["norm_base"])
            if dist <= 10 or (same_base and dist <= 45):
                union(i, j)

    clusters = defaultdict(list)
    for i in range(n):
        clusters[find(i)].append(items[i])

    moved_records = []
    color_variant_groups = []
    kept_total = 0

    for root_id, members in sorted(clusters.items(), key=lambda kv: kv[1][0]["stem"]):
        if len(members) == 1:
            kept_total += 1
            continue

        # 同一クラスタ内を色表現サブグループに分ける
        m = len(members)
        sub_parent = list(range(m))

        def sfind(x):
            while sub_parent[x] != x:
                sub_parent[x] = sub_parent[sub_parent[x]]
                x = sub_parent[x]
            return x

        def sunion(a, b):
            ra, rb = sfind(a), sfind(b)
            if ra != rb:
                sub_parent[rb] = ra

        for a in range(m):
            for b in range(a + 1, m):
                if not is_color_variant_pair(members[a], members[b]):
                    sunion(a, b)

        subgroups = defaultdict(list)
        for a in range(m):
            subgroups[sfind(a)].append(members[a])

        kept_in_cluster = []
        for sg_members in subgroups.values():
            winner = choose_best_item(sg_members)
            kept_in_cluster.append(winner)
            kept_total += 1
            for loser in sg_members:
                if loser["stem"] == winner["stem"]:
                    continue
                dist = int(np.sum(winner["bits"] != loser["bits"]))
                rec = {
                    "kept_stem": winner["stem"],
                    "kept_size": f"{winner['w']}x{winner['h']}",
                    "moved_stem": loser["stem"],
                    "moved_size": f"{loser['w']}x{loser['h']}",
                    "dhash_dist": dist,
                    "norm_base": winner["norm_base"],
                }
                if not args.dry_run:
                    rec["moved_files"] = move_four_files(dataset_root, excl_root, loser["stem"])
                moved_records.append(rec)

        if len(kept_in_cluster) > 1:
            color_variant_groups.append([
                {"stem": it["stem"], "size": f"{it['w']}x{it['h']}", "sat": round(it["sat"], 1)}
                for it in kept_in_cluster
            ])

    report = {
        "initial_count": n,
        "moved_duplicate_count": len(moved_records),
        "remaining_unique_count": kept_total,
        "color_variant_groups_kept": color_variant_groups,
        "moved_records": moved_records,
    }

    if not args.dry_run:
        os.makedirs(excl_root, exist_ok=True)
        report_path = os.path.join(excl_root, "dedupe_report.json")
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)

    mode_tag = "DRY-RUN" if args.dry_run else "APPLIED"
    print(f"[Dedupe {mode_tag}] initial={n} moved={len(moved_records)} remaining={kept_total}")
    print(f"Color-variant groups kept (both preserved for Group Split): {len(color_variant_groups)}")
    for grp in color_variant_groups:
        print("  COLOR_GROUP:", grp)
    print(f"Moved duplicates ({len(moved_records)}):")
    for r in moved_records:
        print(f"  MOVE {r['moved_stem']} ({r['moved_size']}) -> keep {r['kept_stem']} ({r['kept_size']}) [dHash={r['dhash_dist']}]")


if __name__ == "__main__":
    main()
