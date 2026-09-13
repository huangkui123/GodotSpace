"""Install official CUDA sherpa; build the same release on older glibc (WSL20.04).

Run only inside the dedicated GPU TTS venv. Never modifies system libraries.
Source/dependencies are build caches, not repository files or model weights.
"""
from __future__ import annotations

import os
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE_COMMIT = "11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf"
WHEEL_URL = ("https://huggingface.co/csukuangfj2/sherpa-onnx-wheels/resolve/main/cuda/1.13.8/"
             "sherpa_onnx-1.13.8%2Bcuda12.cudnn9.onnxruntime1.28.2-cp312-cp312-linux_x86_64.whl")


def main() -> None:
    if sys.platform != "linux" or platform.machine() != "x86_64" or sys.version_info[:2] != (3, 12):
        raise SystemExit("GPU TTS installer supports Linux x86_64 Python 3.12 only")
    if sys.prefix == sys.base_prefix:
        raise SystemExit("Use a dedicated GPU TTS virtualenv")
    libc, libc_version = platform.libc_ver()
    if libc != "glibc":
        raise SystemExit("Unsupported C runtime")
    pip = [sys.executable, "-m", "pip", "install"]
    if tuple(map(int, libc_version.split('.'))) >= (2, 32):
        subprocess.run(pip + [WHEEL_URL], check=True)
        return
    subprocess.run(pip + ["cmake==3.31.6", "ninja==1.11.1.3", "setuptools", "wheel"], check=True)
    source = ROOT / ".cache/tts-build/sherpa-onnx-1.13.8"
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", "v1.13.8",
                        "https://github.com/k2-fsa/sherpa-onnx.git", str(source)], check=True)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if commit != SOURCE_COMMIT:
        raise SystemExit("Unexpected build source revision; refusing to modify it")
    env = dict(os.environ)
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env["PATH"]
    env["SHERPA_ONNX_CMAKE_ARGS"] = (
        "-DCMAKE_BUILD_TYPE=Release -DSHERPA_ONNX_ENABLE_GPU=ON "
        "-DSHERPA_ONNX_ENABLE_BINARY=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF "
        "-DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF")
    env["SHERPA_ONNX_MAKE_ARGS"] = "-j4"
    env["SHERPA_ONNX_CUDA_VERSION"] = "12.cudnn9"
    subprocess.run([sys.executable, "setup.py", "bdist_wheel"], cwd=source, env=env, check=True)
    wheel = source / "dist/sherpa_onnx-1.13.8+cuda12.cudnn9-cp312-cp312-linux_x86_64.whl"
    if not wheel.is_file():
        raise SystemExit("Build did not produce the expected wheel")
    subprocess.run(pip + [str(wheel)], check=True)


if __name__ == "__main__":
    main()
