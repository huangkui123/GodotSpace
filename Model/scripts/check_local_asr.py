#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import urllib.request


endpoint = os.getenv("LOCAL_ASR_HEALTH_URL", "http://127.0.0.1:8765/health")
with urllib.request.urlopen(endpoint, timeout=5) as response:
    payload = json.load(response)
print(json.dumps(payload, ensure_ascii=False, indent=2))
