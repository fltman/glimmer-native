#!/usr/bin/env python3
"""Converts Real-ESRGAN's compact general model (realesr-general-x4v3, BSD-3-Clause,
https://github.com/xinntao/Real-ESRGAN) to a Core ML program for Glimmer's on-device upscale.

    python realesrgan.py <realesr-general-x4v3.pth> <output dir>

Needs torch, coremltools and numpy. Writes RealESRGAN.mlpackage taking a 1×3×256×256
RGB tensor (0…1) and returning 1×3×1024×1024. Compile it with
`xcrun coremlcompiler compile RealESRGAN.mlpackage <dir>` to get the .mlmodelc the app bundles.
"""
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

TILE = 256


class SRVGGNetCompact(nn.Module):
    """The architecture from Real-ESRGAN (realesrgan/archs/srvgg_arch.py)."""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


def main():
    weights, out_dir = sys.argv[1], sys.argv[2]
    model = SRVGGNetCompact()
    state = torch.load(weights, map_location="cpu", weights_only=True)
    model.load_state_dict(state.get("params_ema", state.get("params", state)))
    model.eval()

    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = "Real-ESRGAN realesr-general-x4v3 (BSD-3-Clause, xinntao/Real-ESRGAN), 4× upscale of 256 px tiles."
    mlmodel.save(f"{out_dir}/RealESRGAN.mlpackage")

    # Sanity check against PyTorch.
    with torch.no_grad():
        expected = model(example).numpy()
    got = mlmodel.predict({"input": example.numpy()})["output"]
    print("max abs difference vs PyTorch:", float(np.abs(expected - got).max()))


if __name__ == "__main__":
    main()
