"""Bounded local scan history and atomic latest scan; no image upload."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

MAX_RECENT_SCANS = 5


def _archive_scan(folder, identifier, source):
    # Never use a request-supplied identifier as a filesystem path.
    digest = hashlib.sha256(identifier.encode('utf-8')).hexdigest()[:24]
    target = folder / (digest + '.json')
    temporary = target.with_suffix('.tmp')
    shutil.copyfile(source, temporary)
    os.replace(temporary, target)


def _retain_recent(path, temporary, request):
    folder = path.with_name(path.stem + '_history')
    identifier = request.get('request_id')
    if not isinstance(identifier, str) or not identifier:
        return
    initialize = not folder.exists()
    folder.mkdir(exist_ok=True)
    if initialize and path.is_file() and path.stat().st_size <= 64 * 1024 * 1024:
        # Preserve the last scan from installations that previously kept only
        # one file, before the next request replaces it.
        try:
            prior_case = json.loads(path.read_text(encoding='utf-8'))
            prior_request = prior_case.get('request') if isinstance(prior_case, dict) else None
            prior = prior_request.get('request_id') if isinstance(prior_request, dict) else None
        except (ValueError, TypeError):
            prior = None
        if isinstance(prior, str) and prior and prior != identifier:
            _archive_scan(folder, prior, path)
    _archive_scan(folder, identifier, temporary)
    # Processing and final results update the same slot. Only files owned by
    # this writer are pruned; unrelated files and subdirectories are untouched.
    cases = [p for p in folder.iterdir() if p.is_file() and re.fullmatch(r'[0-9a-f]{24}\.json', p.name)]
    cases.sort(key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
    for old in cases[MAX_RECENT_SCANS:]:
        old.unlink()


def save_case(destination, request, result):
    if destination is None or request.get('mode') != 'live':
        return None
    path = Path(destination)
    temporary = path.with_suffix('.tmp')
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # A persistent one-byte OS lock is released even if a worker is killed.
        # Concurrent clients must not interleave writes to the bounded temp file.
        with path.with_suffix('.lock').open('a+b') as guard:
            if guard.tell() == 0:
                guard.write(b'0')
                guard.flush()
            guard.seek(0)
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(guard.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(guard.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with temporary.open('w', encoding='utf-8') as stream:
                json.dump({'schema_version': 1, 'recorded_utc': datetime.now(timezone.utc).isoformat(),
                           'request': request, 'result': result}, stream, allow_nan=False)
            _retain_recent(path, temporary, request)
            os.replace(temporary, path)
        return str(path)
    except (OSError, ValueError, TypeError):
        # Diagnostic storage must not turn a recognition result into a crash.
        return None
