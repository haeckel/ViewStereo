#!/usr/bin/env python3
"""
NAFNet (Nonlinear Activation Free Network) -> Core ML (.mlpackage / .mlmodelc) 変換スクリプト。

19世紀古写真・ステレオビューの露光微動ブレや湿板レンズの甘さを引き締めるため、
GAN を使わず構造忠実度の高い NAFNet-GoPro を 512x512 タイル推論用の
Apple Neural Engine (FP16) Core ML モデルに変換します。

使用例:
  # 1. 公式チェックポイント (NAFNet-GoPro-width32.pth / width64.pth) を変換してコンパイル
  python3 export_nafnet_coreml.py \
      --weights NAFNet-GoPro-width32.pth \
      --width 32 \
      --output ../Sources/ViewStereo/Resources/NAFNetDeblur.mlpackage \
      --compile

  # 2. 変換パイプラインのオフライン動作確認 (ダミー重みでトレース・変換テスト)
  python3 export_nafnet_coreml.py --smoke-test --output /tmp/NAFNetDeblur_test.mlpackage
"""

import argparse
import os
import subprocess
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


# ==============================================================================
# NAFNet Architecture (Self-contained)
# ==============================================================================


class LayerNorm2d(nn.Module):
    def __init__(self, channels: int, eps: float = 1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(1, channels, 1, 1))
        self.bias = nn.Parameter(torch.zeros(1, channels, 1, 1))
        self.eps = eps

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        mu = x.mean(dim=1, keepdim=True)
        var = (x - mu).pow(2).mean(dim=1, keepdim=True)
        x_norm = (x - mu) / torch.sqrt(var + self.eps)
        return x_norm * self.weight + self.bias


class SimpleGate(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x1, x2 = x.chunk(2, dim=1)
        return x1 * x2


class NAFBlock(nn.Module):
    def __init__(self, c: int, dw_expand: int = 2, ffn_expand: int = 2):
        super().__init__()
        dw_channel = c * dw_expand
        self.conv1 = nn.Conv2d(c, dw_channel, kernel_size=1, padding=0, stride=1, groups=1, bias=True)
        self.conv2 = nn.Conv2d(
            dw_channel, dw_channel, kernel_size=3, padding=1, stride=1, groups=dw_channel, bias=True
        )
        self.conv3 = nn.Conv2d(dw_channel // 2, c, kernel_size=1, padding=0, stride=1, groups=1, bias=True)

        # Simplified Channel Attention (SCA)
        self.sca = nn.Sequential(
            nn.AdaptiveAvgPool2d(1),
            nn.Conv2d(dw_channel // 2, dw_channel // 2, kernel_size=1, padding=0, stride=1, groups=1, bias=True),
        )

        self.sg = SimpleGate()

        ffn_channel = ffn_expand * c
        self.conv4 = nn.Conv2d(c, ffn_channel, kernel_size=1, padding=0, stride=1, groups=1, bias=True)
        self.conv5 = nn.Conv2d(ffn_channel // 2, c, kernel_size=1, padding=0, stride=1, groups=1, bias=True)

        self.norm1 = LayerNorm2d(c)
        self.norm2 = LayerNorm2d(c)

        self.beta = nn.Parameter(torch.zeros((1, c, 1, 1)), requires_grad=True)
        self.gamma = nn.Parameter(torch.zeros((1, c, 1, 1)), requires_grad=True)

    def forward(self, inp: torch.Tensor) -> torch.Tensor:
        x = self.norm1(inp)
        x = self.conv1(x)
        x = self.conv2(x)
        x = self.sg(x)
        x = x * self.sca(x)
        x = self.conv3(x)

        y = inp + x * self.beta

        x = self.conv4(self.norm2(y))
        x = self.sg(x)
        x = self.conv5(x)

        return y + x * self.gamma


class NAFNet(nn.Module):
    def __init__(
        self,
        img_channel: int = 3,
        width: int = 32,
        middle_blk_num: int = 1,
        enc_blk_nums=None,
        dec_blk_nums=None,
    ):
        super().__init__()
        if enc_blk_nums is None:
            enc_blk_nums = [1, 1, 1, 28]
        if dec_blk_nums is None:
            dec_blk_nums = [1, 1, 1, 1]

        self.intro = nn.Conv2d(img_channel, width, kernel_size=3, padding=1, stride=1, groups=1, bias=True)
        self.ending = nn.Conv2d(width, img_channel, kernel_size=3, padding=1, stride=1, groups=1, bias=True)

        self.encoders = nn.ModuleList()
        self.decoders = nn.ModuleList()
        self.middle_blks = nn.ModuleList()
        self.ups = nn.ModuleList()
        self.downs = nn.ModuleList()

        chan = width
        for num in enc_blk_nums:
            self.encoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(num)]))
            self.downs.append(nn.Conv2d(chan, 2 * chan, 2, 2))
            chan = chan * 2

        self.middle_blks = nn.Sequential(*[NAFBlock(chan) for _ in range(middle_blk_num)])

        for num in dec_blk_nums:
            self.ups.append(nn.Sequential(nn.Conv2d(chan, chan * 2, 1, bias=False), nn.PixelShuffle(2)))
            chan = chan // 2
            self.decoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(num)]))

    def forward(self, inp: torch.Tensor) -> torch.Tensor:
        x = self.intro(inp)
        encs = []

        for encoder, down in zip(self.encoders, self.downs):
            x = encoder(x)
            encs.append(x)
            x = down(x)

        x = self.middle_blks(x)

        for decoder, up, enc_skip in zip(self.decoders, self.ups, encs[::-1]):
            x = up(x)
            x = x + enc_skip
            x = decoder(x)

        x = self.ending(x)
        x = x + inp
        return torch.clamp(x, 0.0, 1.0)


def build_nafnet(preset: str, width_override: int | None = None) -> NAFNet:
    if preset == "gopro-width64":
        return NAFNet(width=width_override or 64, middle_blk_num=1, enc_blk_nums=[1, 1, 1, 28], dec_blk_nums=[1, 1, 1, 1])
    elif preset == "gopro-width32":
        return NAFNet(width=width_override or 32, middle_blk_num=1, enc_blk_nums=[1, 1, 1, 28], dec_blk_nums=[1, 1, 1, 1])
    elif preset == "smoke":
        return NAFNet(width=width_override or 16, middle_blk_num=1, enc_blk_nums=[1, 1, 1, 2], dec_blk_nums=[1, 1, 1, 1])
    else:
        raise ValueError(f"Unknown preset: {preset}")


def load_weights(model: NAFNet, weights_path: str) -> None:
    ckpt = torch.load(weights_path, map_location="cpu", weights_only=True)
    if isinstance(ckpt, dict):
        if "params" in ckpt:
            ckpt = ckpt["params"]
        elif "state_dict" in ckpt:
            ckpt = ckpt["state_dict"]
    # Strip optional "module." prefix
    cleaned = {k.replace("module.", ""): v for k, v in ckpt.items()}
    # LayerNorm2d weight/bias shape compatibility: (C,) -> (1, C, 1, 1)
    for k, v in list(cleaned.items()):
        if (k.endswith(".norm1.weight") or k.endswith(".norm1.bias") or
                k.endswith(".norm2.weight") or k.endswith(".norm2.bias")) and v.ndim == 1:
            cleaned[k] = v.view(1, -1, 1, 1)
    missing, unexpected = model.load_state_dict(cleaned, strict=False)
    print(f"Loaded weights: missing={len(missing)}, unexpected={len(unexpected)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert NAFNet-GoPro to Core ML (.mlpackage)")
    parser.add_argument("--weights", type=str, default=None, help="Path to PyTorch .pth checkpoint")
    parser.add_argument("--preset", type=str, default="gopro-width32", choices=["gopro-width32", "gopro-width64", "smoke"])
    parser.add_argument("--width", type=int, default=None, help="Override channel width")
    parser.add_argument("--tile-size", type=int, default=256, help="Input tile width/height (multiple of 16; 256 matches NAFNet training patch size)")
    parser.add_argument("--precision", type=str, default="fp32", choices=["fp32", "fp16"], help="Core ML compute precision (fp32 recommended for NAFNet SimpleGate stability)")
    parser.add_argument("--output", type=str, default="NAFNetDeblur.mlpackage", help="Output .mlpackage path")
    parser.add_argument("--compile", action="store_true", help="Compile .mlpackage into .mlmodelc via coremlcompiler")
    parser.add_argument("--smoke-test", action="store_true", help="Run offline conversion test with lightweight random weights")
    args = parser.parse_args()

    preset = "smoke" if args.smoke_test else args.preset
    if not args.smoke_test and not args.weights:
        print("Error: --weights is required unless --smoke-test is specified.", file=sys.stderr)
        return 1

    tile = args.tile_size
    if tile % 16 != 0:
        print("Error: --tile-size must be a multiple of 16.", file=sys.stderr)
        return 1

    model = build_nafnet(preset=preset, width_override=args.width)
    if args.weights:
        load_weights(model, args.weights)
    model.eval()

    example_input = torch.rand(1, 3, tile, tile)
    with torch.no_grad():
        traced = torch.jit.trace(model, example_input)

    prec = ct.precision.FLOAT32 if args.precision == "fp32" else ct.precision.FLOAT16
    print(f"Converting to Core ML (tile={tile}x{tile}, {args.precision.upper()})...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_rgb", shape=(1, 3, tile, tile), dtype=np.float32)],
        outputs=[ct.TensorType(name="output_rgb", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=prec,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.author = "ViewStereo (NAFNet-GoPro)"
    mlmodel.short_description = "Optical deblurring model for archival stereoview restoration (non-GAN, structure-preserving)."

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
