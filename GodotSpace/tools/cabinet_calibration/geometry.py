"""Mesh IO and deterministic rigid registration; all computations use meters.

Transforms are row-major 4x4 matrices acting on column vectors: p_target=T@p_source.
Never estimate anisotropic scale to hide manufacturing or assembly differences.
"""
from __future__ import annotations

import hashlib
import itertools
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
from scipy.spatial.transform import Rotation
import trimesh


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_mesh(path: Path) -> trimesh.Trimesh:
    mesh = trimesh.load_mesh(path, process=False)
    if not isinstance(mesh, trimesh.Trimesh) or not len(mesh.faces):
        raise ValueError(f"Not a triangle mesh: {path.name}")
    if not np.isfinite(mesh.vertices).all():
        raise ValueError(f"Non-finite vertices: {path.name}")
    return mesh


def sample_surface(mesh: trimesh.Trimesh, count: int, seed: int = 42) -> np.ndarray:
    """Area-weighted sampling, independent of the CAD tessellation density."""
    triangles = mesh.triangles
    areas = mesh.area_faces
    if not np.isfinite(areas).all() or areas.sum() <= 0:
        raise ValueError("Mesh has no finite positive surface area")
    rng = np.random.default_rng(seed)
    selected = triangles[rng.choice(len(triangles), count, p=areas / areas.sum())]
    uv = rng.random((count, 2))
    uv[uv.sum(axis=1) > 1] = 1 - uv[uv.sum(axis=1) > 1]
    return (selected[:, 0] + uv[:, :1] * (selected[:, 1] - selected[:, 0])
            + uv[:, 1:] * (selected[:, 2] - selected[:, 0]))


def transform_points(points: np.ndarray, transform: np.ndarray) -> np.ndarray:
    return points @ transform[:3, :3].T + transform[:3, 3]


def rigid_fit(source: np.ndarray, target: np.ndarray) -> np.ndarray:
    """Kabsch rigid fit with reflection rejection."""
    a, b = source.mean(axis=0), target.mean(axis=0)
    u, _, vt = np.linalg.svd((source - a).T @ (target - b))
    correction = np.eye(3)
    correction[2, 2] = np.linalg.det(vt.T @ u.T)
    rotation = vt.T @ correction @ u.T
    result = np.eye(4)
    result[:3, :3] = rotation
    result[:3, 3] = b - rotation @ a
    return result


def axis_rotations() -> list[np.ndarray]:
    """24 right-handed axis permutations; STL print packing is usually axial."""
    rotations = []
    for permutation in itertools.permutations(range(3)):
        for signs in itertools.product((-1, 1), repeat=3):
            rotation = np.eye(3)[:, permutation] @ np.diag(signs)
            if np.linalg.det(rotation) > 0:
                rotations.append(rotation)
    return rotations


def icp(source: np.ndarray, target: np.ndarray, initial: np.ndarray,
        iterations: int = 50, trim: float = 0.8) -> np.ndarray:
    tree = cKDTree(target)
    transform = initial.copy()
    for _ in range(iterations):
        moved = transform_points(source, transform)
        distances, indices = tree.query(moved)
        keep = distances <= np.quantile(distances, trim)
        if keep.sum() < 6:
            raise ValueError("Insufficient ICP correspondences")
        delta = rigid_fit(moved[keep], target[indices[keep]])
        transform = delta @ transform
        if np.linalg.norm(delta - np.eye(4)) < 1e-8:
            break
    return transform


def distance_metrics(source: np.ndarray, target: np.ndarray,
                     transform: np.ndarray, tolerance_m: float = 0.005) -> dict:
    moved = transform_points(source, transform)
    forward = cKDTree(target).query(moved)[0]
    reverse = cKDTree(moved).query(target)[0]
    combined = np.concatenate([forward, reverse])
    trimmed = combined[combined <= np.quantile(combined, 0.8)]
    return {
        "trimmed_rms_m": float(np.sqrt(np.mean(trimmed ** 2))),
        "full_rms_m": float(np.sqrt(np.mean(combined ** 2))),
        "p50_m": float(np.median(combined)),
        "p95_m": float(np.quantile(combined, 0.95)),
        "source_overlap": float(np.mean(forward <= tolerance_m)),
        "target_overlap": float(np.mean(reverse <= tolerance_m)),
        "overlap_tolerance_m": tolerance_m,
        "measurement": "bidirectional_sampled_surface_distance_not_device_accuracy",
    }


def register(source: np.ndarray, target: np.ndarray, top_k: int = 4) -> list[dict]:
    if min(len(source), len(target)) < 20:
        raise ValueError("Registration needs at least 20 points per mesh")
    a = source[::max(1, len(source) // 3000)]
    b = target[::max(1, len(target) // 5000)]
    # Both object axes and PCA axes are tested. Retain distinct solutions so
    # bilateral or rotational symmetry is visible instead of silently accepted.
    _, _, va = np.linalg.svd(a - a.mean(0), full_matrices=False)
    _, _, vb = np.linalg.svd(b - b.mean(0), full_matrices=False)
    va[-1] *= np.linalg.det(va)
    vb[-1] *= np.linalg.det(vb)
    candidates = []
    for rotation in axis_rotations() + [vb.T @ r @ va for r in axis_rotations()]:
        initial = np.eye(4)
        initial[:3, :3] = rotation
        initial[:3, 3] = ((b.min(0) + b.max(0)) / 2
                         - rotation @ ((a.min(0) + a.max(0)) / 2))
        fitted = icp(a, b, initial, iterations=35)
        metrics = distance_metrics(a, b, fitted)
        candidates.append((metrics["trimmed_rms_m"], fitted))
    candidates.sort(key=lambda item: item[0])
    distinct = []
    for _, transform in candidates:
        if any(Rotation.from_matrix(other[:3, :3].T @ transform[:3, :3]).magnitude()
               < np.deg2rad(8) and np.linalg.norm(other[:3, 3] - transform[:3, 3]) < 0.02
               for other in distinct):
            continue
        distinct.append(transform)
        if len(distinct) == top_k:
            break
    results = []
    for transform in distinct:
        refined = icp(source, target, transform, iterations=70)
        results.append({"source_m_to_reference_m": refined.tolist(),
                        "quality": distance_metrics(source, target, refined)})
    return sorted(results, key=lambda item: item["quality"]["trimmed_rms_m"])
