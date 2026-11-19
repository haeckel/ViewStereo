#!/usr/bin/env python3
"""
StereoColorizer (ECCV16 / SIGGRAPH17 Lab 色度予測) -> Core ML (.mlpackage / .mlmodelc) 変換スクリプト。

19世紀〜20世紀初頭のモノクロ・鶏卵紙ステレオビューをオンデバイスでカラー化するため、
輝度 L (1ch, [0, 1]) から Lab 色度 (a, b: 2ch, [-1, 1] 正規化) を予測する
Apple Silicon (FP16) 向け Core ML モデルを生成します。

使用例:
  # 1. 公式 ECCV16 チェックポイントを変換してコンパイル (鮮やかで明瞭な発色・推奨)
  python3 export_colorizer_coreml.py \
      --arch eccv16 \
      --weights /tmp/eccv16.pth \
      --size 256 \
      --output ViewStereo/tools/StereoColorizer.mlpackage \
      --compile

  # 2. 公式 SIGGRAPH17 チェックポイントを変換
  python3 export_colorizer_coreml.py \
      --arch siggraph17 \
      --weights /tmp/siggraph17-df00044c.pth \
      --size 256 \
      --output ViewStereo/tools/StereoColorizer.mlpackage \
      --compile
"""

import argparse
import os
import subprocess
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn


# ==============================================================================
# ECCV16 Colorization Architecture (Zhang et al., 2016 - Class Rebalanced)
# ==============================================================================


class ECCV16Generator(nn.Module):
    def __init__(self, norm_layer=nn.BatchNorm2d, temperature: float = 0.5):
        super().__init__()
        self.temperature = temperature

        model1 = [
            nn.Conv2d(1, 64, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(64, 64, kernel_size=3, stride=2, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(64),
        ]
        model2 = [
            nn.Conv2d(64, 128, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(128, 128, kernel_size=3, stride=2, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(128),
        ]
        model3 = [
            nn.Conv2d(128, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=2, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(256),
        ]
        model4 = [
            nn.Conv2d(256, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model5 = [
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model6 = [
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model7 = [
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model8 = [
            nn.ConvTranspose2d(512, 256, kernel_size=4, stride=2, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 313, kernel_size=1, stride=1, padding=0, bias=True),
        ]

        self.model1 = nn.Sequential(*model1)
        self.model2 = nn.Sequential(*model2)
        self.model3 = nn.Sequential(*model3)
        self.model4 = nn.Sequential(*model4)
        self.model5 = nn.Sequential(*model5)
        self.model6 = nn.Sequential(*model6)
        self.model7 = nn.Sequential(*model7)
        self.model8 = nn.Sequential(*model8)
        self.softmax = nn.Softmax(dim=1)
        self.model_out = nn.Conv2d(313, 2, kernel_size=1, padding=0, dilation=1, stride=1, bias=False)
        self.upsample4 = nn.Upsample(scale_factor=4, mode="bilinear", align_corners=False)

    def forward(self, input_luma: torch.Tensor) -> torch.Tensor:
        # input_luma: [B, 1, H, W] in [0, 1] -> ECCV16 expects (L - 50) in [-50, 50]
        # Wait: official ECCV16 normalize_l is (L - 50) / 100 = input_luma - 0.5
        l_centered = input_luma - 0.5
        conv1_2 = self.model1(l_centered)
        conv2_2 = self.model2(conv1_2)
        conv3_3 = self.model3(conv2_2)
        conv4_3 = self.model4(conv3_3)
        conv5_3 = self.model5(conv4_3)
        conv6_3 = self.model6(conv5_3)
        conv7_3 = self.model7(conv6_3)
        conv8_3 = self.model8(conv7_3)
        # Temperature-sharpened softmax produces vivid, clear chroma instead of washed-out gray
        probs = self.softmax(conv8_3 / self.temperature)
        out_ab = self.upsample4(self.model_out(probs))
        return torch.clamp(out_ab, -1.0, 1.0)


# ==============================================================================
# SIGGRAPH17 Colorization Architecture (Zhang et al., 2017)
# ==============================================================================


class SIGGRAPHGenerator(nn.Module):
    def __init__(self, norm_layer=nn.BatchNorm2d):
        super().__init__()

        model1 = [
            nn.Conv2d(4, 64, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(64, 64, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(64),
        ]
        model2 = [
            nn.Conv2d(64, 128, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(128, 128, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(128),
        ]
        model3 = [
            nn.Conv2d(128, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(256),
        ]
        model4 = [
            nn.Conv2d(256, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model5 = [
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model6 = [
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, dilation=2, stride=1, padding=2, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]
        model7 = [
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(512, 512, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(512),
        ]

        model8up = [nn.ConvTranspose2d(512, 256, kernel_size=4, stride=2, padding=1, bias=True)]
        model3short8 = [nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True)]
        model8 = [
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(256),
        ]
        model9up = [nn.ConvTranspose2d(256, 128, kernel_size=4, stride=2, padding=1, bias=True)]
        model2short9 = [nn.Conv2d(128, 128, kernel_size=3, stride=1, padding=1, bias=True)]
        model9 = [
            nn.ReLU(True),
            nn.Conv2d(128, 128, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(True),
            norm_layer(128),
        ]
        model10up = [nn.ConvTranspose2d(128, 128, kernel_size=4, stride=2, padding=1, bias=True)]
        model1short10 = [nn.Conv2d(64, 128, kernel_size=3, stride=1, padding=1, bias=True)]
        model10 = [
            nn.ReLU(True),
            nn.Conv2d(128, 128, kernel_size=3, dilation=1, stride=1, padding=1, bias=True),
            nn.LeakyReLU(negative_slope=0.2),
        ]

        self.model_class = nn.Sequential(nn.Conv2d(256, 529, kernel_size=1, padding=0, dilation=1, stride=1, bias=True))
        self.model_out = nn.Sequential(nn.Conv2d(128, 2, kernel_size=1, padding=0, dilation=1, stride=1, bias=True), nn.Tanh())

        self.model1 = nn.Sequential(*model1)
        self.model2 = nn.Sequential(*model2)
        self.model3 = nn.Sequential(*model3)
        self.model4 = nn.Sequential(*model4)
        self.model5 = nn.Sequential(*model5)
        self.model6 = nn.Sequential(*model6)
        self.model7 = nn.Sequential(*model7)
        self.model8up = nn.Sequential(*model8up)
        self.model8 = nn.Sequential(*model8)
        self.model9up = nn.Sequential(*model9up)
        self.model9 = nn.Sequential(*model9)
        self.model10up = nn.Sequential(*model10up)
        self.model10 = nn.Sequential(*model10)
        self.model3short8 = nn.Sequential(*model3short8)
        self.model2short9 = nn.Sequential(*model2short9)
        self.model1short10 = nn.Sequential(*model1short10)

    def forward(self, input_luma: torch.Tensor) -> torch.Tensor:
        l_centered = input_luma - 0.5
        zeros_hint = torch.zeros_like(input_luma)
        inp = torch.cat((l_centered, zeros_hint, zeros_hint, zeros_hint), dim=1)

        conv1_2 = self.model1(inp)
        conv2_2 = self.model2(conv1_2[:, :, ::2, ::2])
        conv3_3 = self.model3(conv2_2[:, :, ::2, ::2])
        conv4_3 = self.model4(conv3_3[:, :, ::2, ::2])
        conv5_3 = self.model5(conv4_3)
        conv6_3 = self.model6(conv5_3)
        conv7_3 = self.model7(conv6_3)

        conv8_up = self.model8up(conv7_3) + self.model3short8(conv3_3)
        conv8_3 = self.model8(conv8_up)

        conv9_up = self.model9up(conv8_3) + self.model2short9(conv2_2)
        conv9_3 = self.model9(conv9_up)

        conv10_up = self.model10up(conv9_3) + self.model1short10(conv1_2)
        conv10_2 = self.model10(conv10_up)

        return self.model_out(conv10_2)


def load_weights(model: nn.Module, weights_path: str) -> None:
    ckpt = torch.load(weights_path, map_location="cpu", weights_only=True)
    if isinstance(ckpt, dict):
        if "params" in ckpt:
            ckpt = ckpt["params"]
        elif "state_dict" in ckpt:
            ckpt = ckpt["state_dict"]
    cleaned = {k.replace("module.", ""): v for k, v in ckpt.items()}
    missing, unexpected = model.load_state_dict(cleaned, strict=True)
    print(f"Loaded weights: missing={len(missing)}, unexpected={len(unexpected)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert ECCV16 / SIGGRAPH17 Colorizer to Core ML (.mlpackage)")
    parser.add_argument("--arch", type=str, default="eccv16", choices=["eccv16", "siggraph17"])
    parser.add_argument("--weights", type=str, default=None, help="Path to PyTorch .pth checkpoint")
    parser.add_argument("--size", type=int, default=256, help="Input square resolution (multiple of 16; default 256)")
    parser.add_argument("--temperature", type=float, default=0.38, help="Softmax temperature for eccv16 (lower = more vivid)")
    parser.add_argument("--precision", type=str, default="fp16", choices=["fp16", "fp32"])
    parser.add_argument("--output", type=str, default="StereoColorizer.mlpackage", help="Output .mlpackage path")
    parser.add_argument("--compile", action="store_true", help="Compile .mlpackage into .mlmodelc via coremlcompiler")
    parser.add_argument("--smoke-test", action="store_true", help="Run offline conversion test with uninitialized weights")
    args = parser.parse_args()

    if not args.smoke_test and not args.weights:
        print("Error: --weights is required unless --smoke-test is specified.", file=sys.stderr)
        return 1

    size = args.size
    if size % 16 != 0:
        print("Error: --size must be a multiple of 16.", file=sys.stderr)
        return 1

    if args.arch == "eccv16":
        model = ECCV16Generator(temperature=args.temperature)
    else:
        model = SIGGRAPHGenerator()

    if args.weights:
        load_weights(model, args.weights)
    else:
        with torch.no_grad():
            if args.arch == "eccv16":
                nn.init.zeros_(model.model_out.weight)
            else:
                nn.init.zeros_(model.model_out[0].weight)
                nn.init.zeros_(model.model_out[0].bias)
    model.eval()

    example_input = torch.rand(1, 1, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(model, example_input)

    prec = ct.precision.FLOAT32 if args.precision == "fp32" else ct.precision.FLOAT16
    print(f"Converting {args.arch.upper()} StereoColorizer to Core ML ({size}x{size}, {args.precision.upper()})...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_luma", shape=(1, 1, size, size), dtype=np.float32)],
        outputs=[ct.TensorType(name="output_ab", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=prec,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.author = f"ViewStereo ({args.arch.upper()} Colorizer)"
    mlmodel.short_description = "Lab chrominance (a, b) prediction model for archival stereoview colorization."

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    mlmodel.save(args.output)
    print(f"Saved Core ML package: {args.output}")

    if args.compile:
        out_dir = os.path.dirname(os.path.abspath(args.output))
        subprocess.run(["xcrun", "coremlcompiler", "compile", args.output, out_dir], check=True)
        print(f"Compiled .mlmodelc into: {out_dir}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
