from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def main() -> int:
	parser = argparse.ArgumentParser(description="Create mobile-sized astronaut texture copies.")
	parser.add_argument("source", type=Path)
	parser.add_argument("destination", type=Path)
	parser.add_argument("--max-size", type=int, default=1024)
	args = parser.parse_args()

	if args.max_size < 64:
		raise ValueError("--max-size must be at least 64 pixels")
	if not args.source.is_file():
		raise FileNotFoundError(args.source)

	args.destination.parent.mkdir(parents=True, exist_ok=True)
	with Image.open(args.source) as image:
		image.thumbnail((args.max_size, args.max_size), Image.Resampling.LANCZOS)
		image.save(args.destination, optimize=True)
	print(f"{args.source.name}: {image.width}x{image.height}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
