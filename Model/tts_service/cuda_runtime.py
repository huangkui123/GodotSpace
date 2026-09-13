"""Load isolated pip CUDA libraries before sherpa imports ONNX Runtime.

Fail fast rather than silently advertising CUDA on a CPU-only installation.
No torch dependency and no machine-specific LD_LIBRARY_PATH are needed.
"""
from __future__ import annotations

import ctypes
from importlib.metadata import version
from pathlib import Path
import sysconfig

_LIBRARIES: list[ctypes.CDLL] = []


def prepare_cuda() -> None:
    if "cuda12.cudnn9" not in version("sherpa-onnx"):
        raise RuntimeError("CUDA TTS requires the isolated CUDA wheel; run scripts/bootstrap_local_tts_gpu.sh")
    root = Path(sysconfig.get_paths()["purelib"]) / "nvidia"
    for relative in ("cuda_runtime/lib/libcudart.so.12", "cuda_nvrtc/lib/libnvrtc.so.12",
                     "nvjitlink/lib/libnvJitLink.so.12", "cublas/lib/libcublasLt.so.12",
                     "cublas/lib/libcublas.so.12", "cufft/lib/libcufft.so.11",
                     "curand/lib/libcurand.so.10",
                     "cudnn/lib/libcudnn.so.9"):
        _LIBRARIES.append(ctypes.CDLL(str(root / relative), mode=ctypes.RTLD_GLOBAL))
    runtime = _LIBRARIES[0]
    count = ctypes.c_int()
    if runtime.cudaGetDeviceCount(ctypes.byref(count)) != 0 or count.value < 1:
        raise RuntimeError("CUDA TTS has no usable NVIDIA GPU; select LOCAL_TTS_DEVICE=cpu explicitly")
