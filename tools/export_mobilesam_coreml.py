#!/usr/bin/env python3
"""
MobileSAM (vit_t) の Image Encoder と Prompt/Mask Decoder を
Core ML (.mlpackage) にエクスポートし、PyTorch 版との一致を検証するスクリプト。
"""

import argparse
import os
import warnings

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from mobile_sam import SamPredictor, sam_model_registry
from PIL import Image

warnings.filterwarnings("ignore")


class MobileSAMEncoderWrapper(nn.Module):
    def __init__(self, sam_model):
        super().__init__()
        self.image_encoder = sam_model.image_encoder
        self.register_buffer("mean", torch.tensor([123.675, 116.28, 103.53]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([58.395, 57.12, 57.375]).view(1, 3, 1, 1))

    def forward(self, image):
        # image: (1, 3, 1024, 1024) in [0, 255]
        x = (image - self.mean) / self.std
        return self.image_encoder(x)


class MobileSAMDecoderWrapper(nn.Module):
    def __init__(self, sam_model):
        super().__init__()
        self.prompt_encoder = sam_model.prompt_encoder
        self.mask_decoder = sam_model.mask_decoder
        self.register_buffer("image_pe", sam_model.prompt_encoder.get_dense_pe())

    def forward(self, image_embeddings, box):
        # image_embeddings: (1, 256, 64, 64), box: (1, 4) [x0, y0, x1, y1] in 1024x1024
        sparse_emb, dense_emb = self.prompt_encoder(points=None, boxes=box, masks=None)
        low_res_masks, iou_preds = self.mask_decoder(
            image_embeddings=image_embeddings,
            image_pe=self.image_pe,
            sparse_prompt_embeddings=sparse_emb,
            dense_prompt_embeddings=dense_emb,
            multimask_output=True,
        )
        return low_res_masks


def export_models(ckpt_path: str, out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    sam = sam_model_registry["vit_t"](checkpoint=ckpt_path).to("cpu").eval()

    # 1. Encoder エクスポート
    print("[1/3] MobileSAMEncoder をトレース & Core ML 変換中...")
    enc_wrap = MobileSAMEncoderWrapper(sam).eval()
    dummy_img = torch.rand(1, 3, 1024, 1024) * 255.0
    with torch.no_grad():
        traced_enc = torch.export.export(enc_wrap, (dummy_img,)).run_decompositions({})

    ml_enc = ct.convert(
        traced_enc,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 1024, 1024), scale=1.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="image_embeddings", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml_enc.author = "StereoWindow Project (MobileSAM vit_t)"
    enc_path = os.path.join(out_dir, "MobileSAMEncoder.mlpackage")
    ml_enc.save(enc_path)
    print(f"  保存完了: {enc_path}")

    # 2. Decoder エクスポート
    print("[2/3] MobileSAMDecoder をトレース & Core ML 変換中...")
    dec_wrap = MobileSAMDecoderWrapper(sam).eval()
    dummy_emb = torch.randn(1, 256, 64, 64)
    dummy_box = torch.tensor([[100.0, 100.0, 500.0, 800.0]], dtype=torch.float32)
    with torch.no_grad():
        traced_dec = torch.export.export(dec_wrap, (dummy_emb, dummy_box)).run_decompositions({})

    ml_dec = ct.convert(
        traced_dec,
        inputs=[
            ct.TensorType(name="image_embeddings", shape=(1, 256, 64, 64), dtype=np.float32),
            ct.TensorType(name="box", shape=(1, 4), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="masks", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml_dec.author = "StereoWindow Project (MobileSAM vit_t)"
    dec_path = os.path.join(out_dir, "MobileSAMDecoder.mlpackage")
    ml_dec.save(dec_path)
    print(f"  保存完了: {dec_path}")

    # 3. PyTorch vs Core ML 一致検証 (16646-3.jpg)
    print("[3/3] PyTorch vs Core ML 推論一致検証...")
    test_img_path = "StereoWindow/学習用データ/16646-3.jpg"
    with Image.open(test_img_path) as im:
        im_rgb = im.convert("RGB")
        ow, oh = im_rgb.size
        scale = 1024.0 / max(ow, oh)
        nw, nh = int(round(ow * scale)), int(round(oh * scale))
        resized = im_rgb.resize((nw, nh), Image.Resampling.BILINEAR)
        canvas = Image.new("RGB", (1024, 1024), (0, 0, 0))
        canvas.paste(resized, (0, 0))

        # PyTorch
        predictor = SamPredictor(sam)
        predictor.set_image(np.asarray(resized))
        box_test = np.array([60.0, 30.0, 480.0, nh - 30.0], dtype=np.float32)
        pt_masks, _, pt_low = predictor.predict(box=box_test[None, :], multimask_output=True)

        # Core ML
        enc_out = ml_enc.predict({"image": canvas})["image_embeddings"]
        dec_out = ml_dec.predict({
            "image_embeddings": enc_out.astype(np.float32),
            "box": box_test[None, :].astype(np.float32),
        })["masks"][0]  # (3, 256, 256)

        for k in range(3):
            pt_bin = pt_low[k] > 0.0
            cm_bin = dec_out[k] > 0.0
            inter = np.logical_and(pt_bin, cm_bin).sum()
            union = np.logical_or(pt_bin, cm_bin).sum()
            iou = inter / max(1, union)
            print(f"  Mask candidate {k}: PyTorch vs CoreML IoU = {iou:.4f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ckpt", default="/tmp/mobile_sam.pt")
    parser.add_argument("--out", default="StereoWindow/tools")
    args = parser.parse_args()
    export_models(args.ckpt, args.out)
