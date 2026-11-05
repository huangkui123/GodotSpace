"""Small deterministic CPU rasterizer for mesh QA and synthetic RGB templates.

The XYZ buffer is derived from CAD geometry, not from a real depth sensor.
Camera convention: OpenCV, x right, y down, z forward; object units: meters.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np
from numba import njit
from PIL import Image, ImageDraw

from geometry import load_mesh, transform_points


@njit(cache=True)
def _rasterize(vertices, original, faces, pixels, shades, width, height, background):
    image = np.full((height, width, 3), background, dtype=np.uint8)
    xyz = np.full((height, width, 3), np.nan, dtype=np.float32)
    zbuffer = np.full((height, width), np.inf, dtype=np.float32)
    for i in range(len(faces)):
        ia, ib, ic = faces[i]
        za, zb, zc = vertices[ia, 2], vertices[ib, 2], vertices[ic, 2]
        if min(za, zb, zc) <= 0.01:
            continue
        ax, ay = pixels[ia]
        bx, by = pixels[ib]
        cx, cy = pixels[ic]
        x0, x1 = max(0, int(np.floor(min(ax, bx, cx)))), min(width - 1, int(np.ceil(max(ax, bx, cx))))
        y0, y1 = max(0, int(np.floor(min(ay, by, cy)))), min(height - 1, int(np.ceil(max(ay, by, cy))))
        denominator = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if x0 > x1 or y0 > y1 or abs(denominator) < 1e-8:
            continue
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                a = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / denominator
                b = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / denominator
                c = 1 - a - b
                if min(a, b, c) < -1e-6:
                    continue
                pa, pb, pc = a / za, b / zb, c / zc
                depth = 1 / max(pa + pb + pc, 1e-12)
                if depth >= zbuffer[y, x]:
                    continue
                zbuffer[y, x] = depth
                for channel in range(3):
                    xyz[y, x, channel] = depth * (pa * original[ia, channel]
                                                  + pb * original[ib, channel]
                                                  + pc * original[ic, channel])
                    image[y, x, channel] = shades[i]
    return image, xyz


def camera_pose(center: np.ndarray, distance: float, yaw_deg: float,
                elevation_deg: float) -> np.ndarray:
    yaw, elevation = np.deg2rad([yaw_deg, elevation_deg])
    eye = center + distance * np.array([np.sin(yaw) * np.cos(elevation),
                                       np.sin(elevation), np.cos(yaw) * np.cos(elevation)])
    forward = (center - eye) / np.linalg.norm(center - eye)
    right = np.cross(forward, [0, 1, 0])
    right /= np.linalg.norm(right)
    down = np.cross(forward, right)
    rotation = np.array([right, down, forward])
    transform = np.eye(4)
    transform[:3, :3] = rotation
    transform[:3, 3] = -rotation @ eye
    return transform


def render(mesh, transform: np.ndarray, intrinsics: np.ndarray,
           size: tuple[int, int] = (640, 640), background: int = 48,
           light: tuple[float, float, float] = (-0.3, -0.7, -1.0)) -> tuple[np.ndarray, np.ndarray]:
    width, height = size
    if max(size) > 2048 or min(size) < 16:
        raise ValueError("Renderer dimensions must be in 16..2048")
    vertices = transform_points(mesh.vertices, transform)
    pixels_h = vertices @ intrinsics.T
    pixels = pixels_h[:, :2] / np.maximum(pixels_h[:, 2:], 1e-9)
    normals = mesh.face_normals @ transform[:3, :3].T
    lamp = np.asarray(light, dtype=float)
    lamp /= np.linalg.norm(lamp)
    # Double-sided shading tolerates inconsistent print STL winding.
    shades = np.clip(65 + 175 * np.abs(normals @ lamp), 0, 255).astype(np.uint8)
    return _rasterize(np.asarray(vertices), np.asarray(mesh.vertices), np.asarray(mesh.faces),
                      np.asarray(pixels), shades, width, height, background)


def comparison(first, second, output: Path) -> None:
    bounds = np.array([first.bounds, second.bounds])
    center = (bounds[:, 0].min(0) + bounds[:, 1].max(0)) / 2
    extent = np.max(bounds[:, 1].max(0) - bounds[:, 0].min(0))
    intrinsics = np.array([[650, 0, 320], [0, 650, 320], [0, 0, 1]], dtype=float)
    canvas = Image.new("RGB", (1920, 1370), "white")
    draw = ImageDraw.Draw(canvas)
    draw.text((20, 12), "PRINT MODEL (top) / GODOT REFERENCE (bottom) - same scale and camera", fill="black")
    for column, yaw in enumerate((0, 65, 180)):
        pose = camera_pose(center, extent * 1.5, yaw, 18)
        for row, mesh in enumerate((first, second)):
            rgb, _ = render(mesh, pose, intrinsics, background=235)
            canvas.paste(Image.fromarray(rgb), (column * 640, 45 + row * 660))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    comparison(load_mesh(args.first), load_mesh(args.second), args.output)
