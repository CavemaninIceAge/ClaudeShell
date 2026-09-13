#!/usr/bin/env python3
"""画 app 图标：深色圆角方块 + 陶土橙的 ›_ 提示符。输出 1024 母图和 AppIcon.appiconset。
纯几何，不依赖字体；用 Quartz（PyObjC）。"""
import os
import subprocess
import sys

from Quartz import (CGBitmapContextCreate, CGBitmapContextCreateImage, CGColorSpaceCreateDeviceRGB,
                    CGContextAddLineToPoint, CGContextAddPath, CGContextFillPath, CGContextMoveToPoint,
                    CGContextSetLineCap, CGContextSetLineJoin, CGContextSetLineWidth,
                    CGContextSetRGBFillColor, CGContextSetRGBStrokeColor, CGContextStrokePath,
                    CGContextDrawLinearGradient, CGContextSaveGState, CGContextRestoreGState, CGContextClip,
                    CGGradientCreateWithColorComponents, CGPathCreateWithRoundedRect, CGPointMake, CGRectMake,
                    kCGImageAlphaPremultipliedLast, kCGLineCapRound, kCGLineJoinRound,
                    CGImageDestinationCreateWithURL, CGImageDestinationAddImage, CGImageDestinationFinalize)
from Foundation import NSURL

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
iconset = os.path.join(root, "App/Resources/Assets.xcassets/AppIcon.appiconset")
os.makedirs(iconset, exist_ok=True)
master = os.path.join(iconset, "icon_1024.png")

S = 1024
cs = CGColorSpaceCreateDeviceRGB()
ctx = CGBitmapContextCreate(None, S, S, 8, S * 4, cs, kCGImageAlphaPremultipliedLast)

# macOS 图标：留 ~10% 边距的圆角方块。
inset = 100
rect = CGRectMake(inset, inset, S - 2 * inset, S - 2 * inset)
path = CGPathCreateWithRoundedRect(rect, 186, 186, None)
CGContextSaveGState(ctx)
CGContextAddPath(ctx, path)
CGContextClip(ctx)
grad = CGGradientCreateWithColorComponents(cs, [0.18, 0.18, 0.19, 1.0, 0.09, 0.09, 0.10, 1.0], [0.0, 1.0], 2)
CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, S - inset), CGPointMake(0, inset), 0)
CGContextRestoreGState(ctx)

# ›_ ：陶土橙 #D97757
CGContextSetRGBStrokeColor(ctx, 0.851, 0.467, 0.341, 1.0)
CGContextSetLineWidth(ctx, 78)
CGContextSetLineCap(ctx, kCGLineCapRound)
CGContextSetLineJoin(ctx, kCGLineJoinRound)
CGContextMoveToPoint(ctx, 318, 700)
CGContextAddLineToPoint(ctx, 486, 512)
CGContextAddLineToPoint(ctx, 318, 324)
CGContextStrokePath(ctx)
CGContextMoveToPoint(ctx, 546, 324)
CGContextAddLineToPoint(ctx, 736, 324)
CGContextStrokePath(ctx)

img = CGBitmapContextCreateImage(ctx)
dest = CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(master), "public.png", 1, None)
CGImageDestinationAddImage(dest, img, None)
CGImageDestinationFinalize(dest)

sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
images = []
for pt, scale in sizes:
    px = pt * scale
    name = f"icon_{pt}x{pt}@{scale}x.png"
    out = os.path.join(iconset, name)
    if px == 1024:
        subprocess.run(["cp", master, out], check=True)
    else:
        subprocess.run(["sips", "-z", str(px), str(px), master, "--out", out], check=True, capture_output=True)
    images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})

import json
with open(os.path.join(iconset, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
os.remove(master)
print(iconset)
