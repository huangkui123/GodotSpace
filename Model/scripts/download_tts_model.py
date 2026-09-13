"""Download a fixed, hash-checked model; never download during normal service startup."""
from __future__ import annotations

import hashlib
import argparse
import os
from pathlib import Path
import tarfile
import urllib.request

MODELS = {
    "kokoro": ("kokoro-int8-multi-lang-v1_1", "a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6"),
    "kokoro-cuda": ("kokoro-multi-lang-v1_1", "a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad"),
    "vits": ("vits-icefall-zh-aishell3", "ab468db3a3308cdd861495e0db2f25d79418a0c00639f74944c7cdf5dd8c6ec1"),
}


def verify(path: Path, expected: str) -> None:
    with path.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != expected:
            raise RuntimeError(f"Model checksum mismatch: {path.name}; remove the bad archive before retrying.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=MODELS, default=os.getenv("LOCAL_TTS_MODEL", "kokoro"))
    args = parser.parse_args()
    name, checksum = MODELS[args.model]
    url = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/{name}.tar.bz2"
    root = Path(__file__).resolve().parents[1] / "models" / "tts"
    root.mkdir(parents=True, exist_ok=True)
    archive = root / f"{name}.tar.bz2"
    if not archive.exists():
        partial = archive.with_name(archive.name + ".download")
        if not partial.exists():
            with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
        verify(partial, checksum)
        partial.replace(archive)
    verify(archive, checksum)
    with tarfile.open(archive, "r:bz2") as bundle:
        for member in bundle.getmembers():
            target = (root / member.name).resolve()
            if not target.is_relative_to((root / name).resolve()) or not (member.isfile() or member.isdir()):
                raise RuntimeError("Unsafe model archive member")
        # The archive also contains a 180 MB rule.far not used by inference.
        required = {"model.onnx", "tokens.txt", "lexicon.txt", "phone.fst", "date.fst", "number.fst", "speakers.txt"}
        selected = [member for member in bundle.getmembers()
                    if member.isfile() and (args.model.startswith("kokoro") or member.name in {f"{name}/{filename}" for filename in required})]
        if args.model == "vits" and len(selected) != len(required):
            raise RuntimeError("Model archive is incomplete")
        bundle.extractall(root, members=selected, filter="data")
    print(f"TTS model ready: {root / name}")


if __name__ == "__main__":
    main()
