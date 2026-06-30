from __future__ import annotations
import os
import secrets
import sys
import threading
from datetime import datetime, timezone


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class KeyStore:
    def __init__(self, keyfile: str):
        self.keyfile = keyfile
        self._lock = threading.Lock()
        self._secrets: set[str] = set()
        self._records: dict[str, dict] = {}

    def load(self) -> None:
        with self._lock:
            self._secrets.clear()
            self._records.clear()
            if not os.path.exists(self.keyfile):
                return
            with open(self.keyfile, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    parts = line.split(":", 3)
                    if len(parts) != 4:
                        print(f"[keystore] WARNING: skipping malformed keyfile line: {line!r}", file=sys.stderr)
                        continue
                    kid, secret, label, created = parts
                    self._records[kid] = {"id": kid, "secret": secret, "label": label, "created": created}
                    self._secrets.add(secret)

    def _append_line(self, rec: dict) -> None:
        os.makedirs(os.path.dirname(self.keyfile) or ".", exist_ok=True)
        with open(self.keyfile, "a", encoding="utf-8") as fh:
            fh.write(f"{rec['id']}:{rec['secret']}:{rec['label']}:{rec['created']}\n")

    def _rewrite(self) -> None:
        os.makedirs(os.path.dirname(self.keyfile) or ".", exist_ok=True)
        with open(self.keyfile, "w", encoding="utf-8") as fh:
            for rec in self._records.values():
                fh.write(f"{rec['id']}:{rec['secret']}:{rec['label']}:{rec['created']}\n")

    def is_valid(self, secret: str) -> bool:
        with self._lock:
            return secret in self._secrets

    def mint(self, label: str = "") -> dict:
        with self._lock:
            kid = "k_" + secrets.token_hex(8)
            while kid in self._records:
                kid = "k_" + secrets.token_hex(8)
            secret = "sk-" + secrets.token_urlsafe(32)
            rec = {"id": kid, "secret": secret, "label": label, "created": _now_iso()}
            self._records[kid] = rec
            self._secrets.add(secret)
            self._append_line(rec)
            return dict(rec)

    def add_existing(self, secret: str, label: str = "") -> dict:
        with self._lock:
            if secret in self._secrets:
                for r in self._records.values():
                    if r["secret"] == secret:
                        return dict(r)
            kid = "k_" + secrets.token_hex(8)
            rec = {"id": kid, "secret": secret, "label": label, "created": _now_iso()}
            self._records[kid] = rec
            self._secrets.add(secret)
            self._append_line(rec)
            return dict(rec)

    def revoke(self, key_id: str) -> bool:
        with self._lock:
            rec = self._records.pop(key_id, None)
            if rec is None:
                return False
            self._secrets.discard(rec["secret"])
            self._rewrite()
            return True

    def list_ids(self) -> list[dict]:
        with self._lock:
            return [{"id": r["id"], "label": r["label"], "created": r["created"]}
                    for r in self._records.values()]
