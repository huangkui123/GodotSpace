from __future__ import annotations

import argparse
from pathlib import Path


REPLACEMENTS = {
	b"BaseColor.<UDIM>.png": b"BaseColor.1002xx.png",
	b"Roughness.<UDIM>.png": b"Roughness.1002xx.png",
	b"Normal.<UDIM>.png": b"Normal.1002xx.png",
	b"Metallic.<UDIM>.png": b"Metallic.1002xx.png",
}


def main() -> int:
	parser = argparse.ArgumentParser(description="Patch unsupported FBX UDIM tokens without changing binary offsets.")
	parser.add_argument("fbx", type=Path)
	args = parser.parse_args()

	data = args.fbx.read_bytes()
	for source, replacement in REPLACEMENTS.items():
		if len(source) != len(replacement):
			raise ValueError(f"Replacement changes FBX string length: {source!r}")
		if source not in data:
			raise ValueError(f"Expected FBX texture token is missing: {source.decode()}")
		data = data.replace(source, replacement)
	args.fbx.write_bytes(data)
	print(f"Patched Godot-compatible UDIM aliases in {args.fbx.name}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
