#!/usr/bin/env python3
"""Local HTTP wrapper for Apple Depth Pro point-depth prediction.

Run this beside the Godot server process, then the spatial calibration panel
can POST the current JPEG frame and clicked pixel to /predict.
"""

from __future__ import annotations

import argparse
import base64
import copy
import importlib
import json
import math
import os
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class DepthProPredictor:
    def __init__(self, device: str, depth_pro_path: str = "", checkpoint_path: str = "") -> None:
        self.requested_device = device
        self.depth_pro_path = depth_pro_path
        self.checkpoint_path = checkpoint_path
        self.device = "cpu"
        self.model: Any = None
        self.transform: Any = None
        self.depth_pro: Any = None
        self.torch: Any = None
        self.lock = threading.Lock()

    def preload(self) -> None:
        with self.lock:
            self._load_model()

    def _load_model(self) -> None:
        if self.model is not None:
            return

        load_start = time.perf_counter()
        if self.depth_pro_path:
            sys.path.insert(0, self.depth_pro_path)
            sys.path.insert(0, os.path.join(self.depth_pro_path, "src"))

        self._log("Importing Depth Pro and PyTorch...")
        import depth_pro  # type: ignore
        import torch  # type: ignore
        depth_pro_impl = importlib.import_module("depth_pro.depth_pro")

        cuda_available = bool(torch.cuda.is_available())
        cuda_device_count = int(torch.cuda.device_count()) if cuda_available else 0
        cuda_device_name = torch.cuda.get_device_name(0) if cuda_available else "none"
        self._log(
            "Torch CUDA status: "
            f"available={cuda_available}, device_count={cuda_device_count}, device0={cuda_device_name}"
        )

        if self.requested_device == "auto":
            self.device = "cuda" if torch.cuda.is_available() else "cpu"
        else:
            self.device = self.requested_device
        if self.device == "cuda" and not cuda_available:
            raise RuntimeError(
                "CUDA was requested but this PyTorch environment cannot see a CUDA GPU. "
                "Install a CUDA-enabled torch build in the depth-pro conda environment, "
                "or run with --device cpu."
            )

        checkpoint_path = self._resolve_checkpoint_path()
        self._log(f"Loading Depth Pro checkpoint: {checkpoint_path}")
        self._log(f"Using device: {self.device}")
        default_config = getattr(
            depth_pro,
            "DEFAULT_MONODEPTH_CONFIG_DICT",
            getattr(depth_pro_impl, "DEFAULT_MONODEPTH_CONFIG_DICT"),
        )
        config = copy.copy(default_config)
        config.checkpoint_uri = checkpoint_path

        create_model_and_transforms = getattr(
            depth_pro,
            "create_model_and_transforms",
            getattr(depth_pro_impl, "create_model_and_transforms"),
        )
        self.model, self.transform = create_model_and_transforms(
            config=config,
            device=self.device,
        )
        self.model.eval()
        self.depth_pro = depth_pro
        self.torch = torch
        self._log(f"Depth Pro model loaded in {(time.perf_counter() - load_start):.1f}s")

    def _resolve_checkpoint_path(self) -> str:
        candidates: list[str] = []
        if self.checkpoint_path:
            candidates.append(self.checkpoint_path)
        if self.depth_pro_path:
            candidates.append(os.path.join(self.depth_pro_path, "checkpoints", "depth_pro.pt"))
            candidates.append(os.path.join(os.path.dirname(self.depth_pro_path), "checkpoints", "depth_pro.pt"))
        candidates.append(os.path.abspath(os.path.join("checkpoints", "depth_pro.pt")))

        for candidate in candidates:
            absolute_candidate = os.path.abspath(candidate)
            if os.path.isfile(absolute_candidate):
                return absolute_candidate

        searched = "\n  ".join(os.path.abspath(candidate) for candidate in candidates)
        raise FileNotFoundError(
            "Depth Pro checkpoint not found. Download depth_pro.pt and pass "
            f"--checkpoint-path, or put it under <depth-pro-path>/checkpoints/depth_pro.pt. Searched:\n  {searched}"
        )

    def predict_point(
        self,
        jpeg_bytes: bytes,
        x: float,
        y: float,
        patch_radius: int,
        min_depth_m: float,
        max_depth_m: float,
    ) -> dict[str, Any]:
        with self.lock:
            start = time.perf_counter()
            self._load_model()

            image_path = self._write_temp_jpeg(jpeg_bytes)
            try:
                self._log(f"Predicting point ({x:.1f}, {y:.1f}) from JPEG {len(jpeg_bytes)} bytes")
                image, _, f_px = self.depth_pro.load_rgb(image_path)
                source_width, source_height = self._get_image_size(image)
                self._log(f"Loaded RGB image: {source_width}x{source_height}")
                image_tensor = self.transform(image).to(self.device)
                with self.torch.no_grad():
                    prediction = self.model.infer(image_tensor, f_px=f_px)
                depth = prediction["depth"].detach().float().cpu().numpy()
            finally:
                try:
                    os.remove(image_path)
                except OSError:
                    pass

        result = self._sample_depth(
            depth,
            x,
            y,
            int(source_width),
            int(source_height),
            patch_radius,
            min_depth_m,
            max_depth_m,
            (time.perf_counter() - start) * 1000.0,
        )
        self._log(
            "Prediction sampled: "
            f"depth={float(result['depth_m']):.3f}m "
            f"samples={int(result['sample_count'])} "
            f"elapsed={float(result['elapsed_ms']):.1f}ms"
        )
        return result

    @staticmethod
    def _log(message: str) -> None:
        print(f"depth_pro_server: {message}", file=sys.stderr, flush=True)

    @staticmethod
    def _get_image_size(image: Any) -> tuple[int, int]:
        shape = getattr(image, "shape", None)
        if shape is not None and len(shape) >= 2:
            return int(shape[1]), int(shape[0])

        width = getattr(image, "width", None)
        height = getattr(image, "height", None)
        if width is not None and height is not None:
            return int(width), int(height)

        size = getattr(image, "size", None)
        if isinstance(size, tuple) and len(size) >= 2:
            return int(size[0]), int(size[1])

        raise ValueError(f"Unable to read image size from {type(image).__name__}")

    @staticmethod
    def _write_temp_jpeg(jpeg_bytes: bytes) -> str:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as temp_file:
            temp_file.write(jpeg_bytes)
            return temp_file.name

    def _sample_depth(
        self,
        depth: Any,
        x: float,
        y: float,
        source_width: int,
        source_height: int,
        patch_radius: int,
        min_depth_m: float,
        max_depth_m: float,
        elapsed_ms: float,
    ) -> dict[str, Any]:
        import numpy as np  # type: ignore

        depth_map = np.asarray(depth, dtype=np.float32)
        while depth_map.ndim > 2:
            depth_map = depth_map.squeeze()
        if depth_map.ndim != 2:
            raise ValueError(f"Unexpected depth map shape: {depth_map.shape}")

        depth_height, depth_width = depth_map.shape
        if source_width <= 0 or source_height <= 0 or depth_width <= 0 or depth_height <= 0:
            raise ValueError("Invalid image or depth-map dimensions")

        depth_x = int(round(float(x) * float(depth_width - 1) / float(max(1, source_width - 1))))
        depth_y = int(round(float(y) * float(depth_height - 1) / float(max(1, source_height - 1))))
        depth_x = min(max(depth_x, 0), depth_width - 1)
        depth_y = min(max(depth_y, 0), depth_height - 1)

        radius = max(0, int(patch_radius))
        left = max(0, depth_x - radius)
        right = min(depth_width, depth_x + radius + 1)
        top = max(0, depth_y - radius)
        bottom = min(depth_height, depth_y + radius + 1)
        patch = depth_map[top:bottom, left:right]
        finite = patch[np.isfinite(patch)]
        finite = finite[finite > 0.0]
        if min_depth_m > 0.0:
            finite = finite[finite >= min_depth_m]
        if max_depth_m > 0.0:
            finite = finite[finite <= max_depth_m]
        if finite.size == 0:
            raise ValueError("No valid depth samples near the clicked pixel")

        depth_m = float(np.median(finite))
        return {
            "ok": True,
            "model": "depth_pro",
            "depth_m": depth_m,
            "mean_depth_m": float(np.mean(finite)),
            "min_depth_m": float(np.min(finite)),
            "max_depth_m": float(np.max(finite)),
            "sample_count": int(finite.size),
            "patch_radius": radius,
            "source_size": [source_width, source_height],
            "depth_map_size": [int(depth_width), int(depth_height)],
            "sample_pixel": [int(depth_x), int(depth_y)],
            "elapsed_ms": elapsed_ms,
        }


class DepthPredictionHandler(BaseHTTPRequestHandler):
    predictor: DepthProPredictor
    max_body_bytes: int = 16 * 1024 * 1024

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json({
                "ok": True,
                "service": "depth_pro_server",
                "model_loaded": self.predictor.model is not None,
                "device": self.predictor.device,
                "depth_pro_path": self.predictor.depth_pro_path,
                "checkpoint_path": self.predictor.checkpoint_path,
            })
            return
        self._send_json({"ok": False, "error": "not_found"}, status=404)

    def do_POST(self) -> None:
        if self.path != "/predict":
            self._send_json({"ok": False, "error": "not_found"}, status=404)
            return

        request_id: Any = None
        try:
            payload = self._read_json_body()
            request_id = payload.get("request_id")
            self.log_message("predict request %s received", request_id)
            image_b64 = str(payload.get("image_jpeg_base64", ""))
            if "," in image_b64:
                image_b64 = image_b64.split(",", 1)[1]
            jpeg_bytes = base64.b64decode(image_b64, validate=True)
            result = self.predictor.predict_point(
                jpeg_bytes=jpeg_bytes,
                x=float(payload.get("x", 0.0)),
                y=float(payload.get("y", 0.0)),
                patch_radius=int(payload.get("patch_radius", 5)),
                min_depth_m=float(payload.get("min_depth_m", 0.0)),
                max_depth_m=float(payload.get("max_depth_m", 0.0)),
            )
            result["request_id"] = request_id
            self.log_message(
                "predict request %s ok: depth=%.3fm samples=%s elapsed=%.1fms",
                request_id,
                float(result.get("depth_m", 0.0)),
                result.get("sample_count", "?"),
                float(result.get("elapsed_ms", 0.0)),
            )
            self._send_json(result)
        except Exception as error:  # noqa: BLE001 - service must report model failures.
            self.log_message("predict request %s failed: %s", request_id, error)
            traceback.print_exc()
            self._send_json(
                {
                    "ok": False,
                    "request_id": request_id,
                    "error": str(error),
                    "error_type": type(error).__name__,
                },
                status=500,
            )

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("depth_pro_server: " + format % args + "\n")

    def _read_json_body(self) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            raise ValueError("Missing request body")
        if content_length > self.max_body_bytes:
            raise ValueError(f"Request body too large: {content_length} bytes")
        raw_body = self.rfile.read(content_length)
        parsed = json.loads(raw_body.decode("utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError("Expected JSON object")
        return parsed

    def _send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            self.log_message("client disconnected before response could be written")


def main() -> int:
    parser = argparse.ArgumentParser(description="Depth Pro point-depth prediction server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    parser.add_argument(
        "--depth-pro-path",
        default="",
        help="Optional path to the cloned apple/ml-depth-pro repository or installed package root.",
    )
    parser.add_argument(
        "--checkpoint-path",
        default="",
        help="Optional absolute path to depth_pro.pt. Overrides --depth-pro-path checkpoint discovery.",
    )
    parser.add_argument(
        "--no-preload",
        action="store_true",
        help="Do not load the model during service startup; load it on the first prediction request instead.",
    )
    parser.add_argument("--max-body-mb", type=int, default=16)
    args = parser.parse_args()

    predictor = DepthProPredictor(
        args.device,
        args.depth_pro_path,
        args.checkpoint_path,
    )
    if not args.no_preload:
        print("Preloading Depth Pro model before accepting requests...")
        predictor.preload()
        print("Depth Pro model is ready.")

    DepthPredictionHandler.predictor = predictor
    DepthPredictionHandler.max_body_bytes = max(1, args.max_body_mb) * 1024 * 1024
    server = ThreadingHTTPServer((args.host, args.port), DepthPredictionHandler)
    print(f"Depth Pro server listening on http://{args.host}:{args.port}")
    print("POST /predict with image_jpeg_base64, x, y, patch_radius")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Depth Pro server")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
