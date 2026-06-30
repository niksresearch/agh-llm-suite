import httpx
import respx
import pytest
from fastapi.testclient import TestClient
from config import Settings
from keystore import KeyStore
from ratelimit import RateLimiter
from app import create_app


def make_client(tmp_path, rpm=60):
    s = Settings(
        ollama_url="http://localhost:11434", model="gemma-4-31B-it-GGUF",
        num_ctx=8192, rate_limit_rpm=rpm, admin_token="admintok",
        keyfile=str(tmp_path / "keys.txt"), bootstrap_key="", bundle=2,
    )
    ks = KeyStore(s.keyfile); ks.load()
    rec = ks.mint(label="test")
    limiter = RateLimiter(rpm=rpm)
    client = httpx.AsyncClient(base_url=s.ollama_url)
    app = create_app(s, ks, limiter, client)
    return TestClient(app), rec["secret"]


@respx.mock
def test_health_reports_ollama_up(tmp_path):
    respx.get("http://localhost:11434/api/tags").mock(return_value=httpx.Response(200, json={"models": []}))
    c, _ = make_client(tmp_path)
    r = c.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["ollama"] is True
    assert body["model"] == "gemma-4-31B-it-GGUF"


def test_missing_key_is_401(tmp_path):
    c, _ = make_client(tmp_path)
    r = c.post("/query", json={"prompt": "hi"})
    assert r.status_code == 401


def test_bad_key_is_401(tmp_path):
    c, _ = make_client(tmp_path)
    r = c.post("/query", json={"prompt": "hi"}, headers={"Authorization": "Bearer wrong"})
    assert r.status_code == 401


def test_rate_limit_returns_429(tmp_path):
    c, secret = make_client(tmp_path, rpm=1)
    h = {"Authorization": f"Bearer {secret}"}
    with respx.mock:
        respx.post("http://localhost:11434/api/chat").mock(
            return_value=httpx.Response(200, json={"message": {"content": "ok"}})
        )
        r1 = c.post("/query", json={"prompt": "hi"}, headers=h)
        r2 = c.post("/query", json={"prompt": "hi"}, headers=h)
    assert r1.status_code == 200
    assert r2.status_code == 429
    assert "Retry-After" in r2.headers
