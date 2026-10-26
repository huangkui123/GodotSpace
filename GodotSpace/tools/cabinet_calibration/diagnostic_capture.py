"""One local replayable scan, replaced atomically; no image upload or history."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path


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
            os.replace(temporary, path)
        return str(path)
    except (OSError, ValueError, TypeError):
        # Diagnostic storage must not turn a recognition result into a crash.
        return None
