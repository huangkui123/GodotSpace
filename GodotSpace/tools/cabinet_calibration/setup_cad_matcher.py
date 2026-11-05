"""Install the checksum-pinned official LoFTR weights; no camera input is read."""
from pathlib import Path
import urllib.request

from cad_learned_matcher import WEIGHT_URL, WEIGHT_SHA256, weight_path
from geometry import sha256


def main():
    target = weight_path()
    if target.is_file() and sha256(target) == WEIGHT_SHA256:
        print(f'CAD matcher ready: {target}')
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.download')
    try:
        with urllib.request.urlopen(WEIGHT_URL, timeout=60) as source, temporary.open('wb') as dest:
            while block := source.read(1024 * 1024):
                dest.write(block)
        if sha256(temporary) != WEIGHT_SHA256:
            raise ValueError('Downloaded CAD matcher checksum mismatch')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'CAD matcher ready: {target}')


if __name__ == '__main__':
    main()
