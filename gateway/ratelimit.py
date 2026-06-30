from __future__ import annotations
import time
import threading
from typing import Callable


class RateLimiter:
    def __init__(self, rpm: int, now: Callable[[], float] = time.monotonic):
        self.capacity = float(rpm)
        self.refill_per_sec = rpm / 60.0
        self._now = now
        self._lock = threading.Lock()
        self._buckets: dict[str, tuple[float, float]] = {}  # key -> (tokens, last_ts)

    def allow(self, key: str) -> bool:
        with self._lock:
            now = self._now()
            tokens, last = self._buckets.get(key, (self.capacity, now))
            tokens = min(self.capacity, tokens + (now - last) * self.refill_per_sec)
            if tokens >= 1.0:
                tokens -= 1.0
                self._buckets[key] = (tokens, now)
                return True
            self._buckets[key] = (tokens, now)
            return False
