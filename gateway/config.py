from __future__ import annotations
import os
from dataclasses import dataclass
from typing import Mapping, Optional


@dataclass(frozen=True)
class Settings:
    ollama_url: str
    model: str
    num_ctx: int
    rate_limit_rpm: int
    admin_token: str
    keyfile: str
    bootstrap_key: str
    bundle: int


def load_settings(env: Optional[Mapping[str, str]] = None) -> Settings:
    e = os.environ if env is None else env
    return Settings(
        ollama_url=e.get("OLLAMA_URL", "http://localhost:11434"),
        model=e.get("MODEL", "gemma-4-31B-it-GGUF"),
        num_ctx=int(e.get("OLLAMA_NUM_CTX", "8192")),
        rate_limit_rpm=int(e.get("RATE_LIMIT_RPM", "60")),
        admin_token=e.get("ADMIN_TOKEN", ""),
        keyfile=e.get("KEYFILE", "/data/keys.txt"),
        bootstrap_key=e.get("LLM_API_KEY", ""),
        bundle=int(e.get("BUNDLE", "2")),
    )
