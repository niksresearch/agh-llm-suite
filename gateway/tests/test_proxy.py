import httpx
import respx
from fastapi.testclient import TestClient
from config import Settings
from keystore import KeyStore
from ratelimit import RateLimiter
from app import create_app


def make_client(tmp_path, mock_router):
    s = Settings(ollama_url="http://localhost:11434", model="gemma-test",
                 num_ctx=8192, rate_limit_rpm=60, admin_token="admin-tok",
                 keyfile=str(tmp_path / "keys.txt"), bootstrap_key="", bundle=2)
    ks = KeyStore(s.keyfile)
    ks.load()
    ks.add_existing("test-secret", label="test")
    limiter = RateLimiter(rpm=60)
    transport = httpx.MockTransport(mock_router.handler)
    http_client = httpx.AsyncClient(base_url="http://localhost:11434", transport=transport)
    app = create_app(s, ks, limiter, http_client)
    return TestClient(app)


def test_proxy_non_streaming(tmp_path):
    mock_router = respx.MockRouter()
    ollama_resp = {"id": "chatcmpl-1", "choices": [{"message": {"role": "assistant", "content": "Hello"}}]}
    mock_router.post("http://localhost:11434/v1/chat/completions").mock(
        return_value=httpx.Response(200, json=ollama_resp)
    )
    c = make_client(tmp_path, mock_router)
    r = c.post(
        "/v1/chat/completions",
        json={"model": "gemma-test", "messages": [{"role": "user", "content": "hi"}], "stream": False},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert r.status_code == 200
    assert r.json() == ollama_resp


def test_proxy_streaming(tmp_path):
    mock_router = respx.MockRouter()
    sse_body = b'data: {"id":"1","choices":[{"delta":{"content":"Hi"}}]}\n\ndata: [DONE]\n\n'
    mock_router.post("http://localhost:11434/v1/chat/completions").mock(
        return_value=httpx.Response(
            200,
            content=sse_body,
            headers={"content-type": "text/event-stream"},
        )
    )
    c = make_client(tmp_path, mock_router)
    r = c.post(
        "/v1/chat/completions",
        json={"model": "gemma-test", "messages": [{"role": "user", "content": "hi"}], "stream": True},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert r.status_code == 200
    assert "text/event-stream" in r.headers["content-type"]
    assert b"[DONE]" in r.content


def test_proxy_auth_required(tmp_path):
    mock_router = respx.MockRouter()
    c = make_client(tmp_path, mock_router)
    r = c.post(
        "/v1/chat/completions",
        json={"model": "gemma-test", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert r.status_code == 401
