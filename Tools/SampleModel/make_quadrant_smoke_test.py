"""Builds a small, fully deterministic YOLOv8-shaped Core ML detector.

The network is hand-wired, not trained: it reports one box per image quadrant,
with the confidence of each box set to that quadrant's mean brightness. That
makes every prediction predictable from the input, which is what a smoke test
of the decode -> overlay -> capture path needs.
"""
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct

INPUT = 640
ANCHORS = 4          # one per quadrant
CLASSES = 2          # "bright" and "dark"
CHANNELS = 4 + CLASSES

# Normalised centre boxes, one per quadrant, each covering 40% of the frame.
BOXES = torch.tensor([
    [0.25, 0.25, 0.40, 0.40],
    [0.75, 0.25, 0.40, 0.40],
    [0.25, 0.75, 0.40, 0.40],
    [0.75, 0.75, 0.40, 0.40],
], dtype=torch.float32)


class QuadrantDetector(nn.Module):
    def forward(self, image):
        # image: 1x3xHxW in 0...1
        half = INPUT // 2
        quadrants = torch.stack([
            image[:, :, :half, :half].mean(),
            image[:, :, :half, half:].mean(),
            image[:, :, half:, :half].mean(),
            image[:, :, half:, half:].mean(),
        ]).reshape(ANCHORS)

        boxes = BOXES.t()                              # 4 x ANCHORS
        bright = quadrants.reshape(1, ANCHORS)          # 1 x ANCHORS
        dark = (1.0 - quadrants).reshape(1, ANCHORS)
        out = torch.cat([boxes, bright, dark], dim=0)   # CHANNELS x ANCHORS
        return out.reshape(1, CHANNELS, ANCHORS)


model = QuadrantDetector().eval()
example = torch.rand(1, 3, INPUT, INPUT)
traced = torch.jit.trace(model, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name="image", shape=(1, 3, INPUT, INPUT), scale=1 / 255.0, color_layout=ct.colorlayout.RGB
    )],
    outputs=[ct.TensorType(name="predictions")],
    minimum_deployment_target=ct.target.iOS16,
    convert_to="mlprogram",
)
mlmodel.author = "Lincode"
mlmodel.short_description = (
    "Smoke-test detector: one box per image quadrant, confidence = quadrant brightness."
)
mlmodel.user_defined_metadata["names"] = "{0: 'bright', 1: 'dark'}"
mlmodel.save("QuadrantSmokeTest.mlpackage")
print("saved QuadrantSmokeTest.mlpackage")

# Sanity check against the torch reference.
import PIL.Image
canvas = np.zeros((INPUT, INPUT, 3), dtype=np.uint8)
canvas[:INPUT // 2, :INPUT // 2] = 255          # top-left fully bright
canvas[INPUT // 2:, INPUT // 2:] = 128          # bottom-right mid
image = PIL.Image.fromarray(canvas)
result = mlmodel.predict({"image": image})["predictions"]
print("output shape:", result.shape)
print("class scores per anchor:\n", np.round(result[0, 4:, :], 4))
