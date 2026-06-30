import json
import httpx
import respx
from fastapi.testclient import TestClient
from config import Settings
from keystore import KeyStore
from ratelimit import RateLimiter
from app import create_app


def make_client(tmp_path):
    s = Settings(ollama_url="http://localhost:11434", model="gemma-4-31B-it-GGUF",
                 num_ctx=8192, rate_limit_rpm=60, admin_token="admintok",
                 keyfile=str(tmp_path / "keys.txt"), bootstrap_key="", bundle=2)
    ks = KeyStore(s.keyfile); ks.load()
    secret = ks.mint()["secret"]
    app = create_app(s, ks, RateLimiter(rpm=60), httpx.AsyncClient(base_url=s.ollama_url))
    return TestClient(app), secret


@respx.mock
def test_query_returns_answer(tmp_path):
    route = respx.post("http://localhost:11434/api/chat").mock(
        return_value=httpx.Response(200, json={"message": {"content": "Paris."}})
    )
    c, secret = make_client(tmp_path)
    r = c.post("/query", json={"prompt": "Capital of France?"},
               headers={"Authorization": f"Bearer {secret}"})
    assert r.status_code == 200
    assert r.json() == {"answer": "Paris.", "model": "gemma-4-31B-it-GGUF"}
    sent = json.loads(route.calls.last.request.content)
    assert sent["model"] == "gemma-4-31B-it-GGUF"
    assert sent["stream"] is False
    assert sent["messages"][-1] == {"role": "user", "content": "Capital of France?"}


@respx.mock
def test_query_includes_system_prompt(tmp_path):
    route = respx.post("http://localhost:11434/api/chat").mock(
        return_value=httpx.Response(200, json={"message": {"content": "ok"}})
    )
    c, secret = make_client(tmp_path)
    c.post("/query", json={"prompt": "hi", "system": "Be terse."},
           headers={"Authorization": f"Bearer {secret}"})
    sent = json.loads(route.calls.last.request.content)
    assert sent["messages"][0] == {"role": "system", "content": "Be terse."}


@respx.mock
def test_query_ollama_error_is_503(tmp_path):
    respx.post("http://localhost:11434/api/chat").mock(return_value=httpx.Response(500))
    c, secret = make_client(tmp_path)
    r = c.post("/query", json={"prompt": "hi"}, headers={"Authorization": f"Bearer {secret}"})
    assert r.status_code == 503
