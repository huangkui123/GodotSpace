"""Download a fixed, hash-checked model; never download during normal service startup."""
from __future__ import annotations

import hashlib
from pathlib import Path
import tarfile
import urllib.request

NAME = "vits-icefall-zh-aishell3"
SHA256 = "ab468db3a3308cdd861495e0db2f25d79418a0c00639f74944c7cdf5dd8c6ec1"
URL = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/{NAME}.tar.bz2"


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "models" / "tts"
    root.mkdir(parents=True, exist_ok=True)
    archive = root / f"{NAME}.tar.bz2"
    if not archive.exists():
        partial = archive.with_suffix(".download")
        with urllib.request.urlopen(URL, timeout=120) as response, partial.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        partial.replace(archive)
    with archive.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != SHA256:
            raise RuntimeError("Model checksum mismatch. Remove the bad archive and retry.")
    with tarfile.open(archive, "r:bz2") as bundle:
        for member in bundle.getmembers():
            target = (root / member.name).resolve()
            if not target.is_relative_to(root.resolve()) or not (member.isfile() or member.isdir()):
                raise RuntimeError("Unsafe model archive member")
        # The archive also contains a 180 MB rule.far not used by inference.
        required = {"model.onnx", "tokens.txt", "lexicon.txt", "phone.fst", "date.fst", "number.fst", "speakers.txt"}
        selected = [member for member in bundle.getmembers()
                    if member.isfile() and member.name in {f"{NAME}/{name}" for name in required}]
        if len(selected) != len(required):
            raise RuntimeError("Model archive is incomplete")
        bundle.extractall(root, members=selected, filter="data")
    print(f"TTS model ready: {root / NAME}")


if __name__ == "__main__":
    main()
