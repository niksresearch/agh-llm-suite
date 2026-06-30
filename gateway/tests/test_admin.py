import pytest
import httpx
import respx
from fastapi.testclient import TestClient
from config import load_settings
from keystore import KeyStore
from ratelimit import RateLimiter
from app import create_app


@pytest.fixture
def app_and_client(tmp_path):
    settings = load_settings({
        "MODEL": "gemma-test",
        "ADMIN_TOKEN": "admin-tok",
        "RATE_LIMIT_RPM": "60",
        "OLLAMA_NUM_CTX": "8192",
        "LLM_API_KEY": "",
        "KEYFILE": str(tmp_path / "keys.txt"),
    })
    ks = KeyStore(str(tmp_path / "keys.txt"))
    ks.load()
    limiter = RateLimiter(rpm=60)
    mock_router = respx.MockRouter()
    http_client = httpx.AsyncClient(
        base_url="http://ollama:11434",
        transport=httpx.MockTransport(mock_router.handler),
    )
    mock_router.get("/api/tags").mock(return_value=httpx.Response(200, json={"models": []}))
    app = create_app(settings, ks, limiter, http_client)
    return app, ks, TestClient(app)


def test_admin_mint_returns_key(app_and_client):
    app, ks, client = app_and_client
    r = client.post(
        "/admin/keys",
        json={"label": "test-user"},
        headers={"X-Admin-Token": "admin-tok"},
    )
    assert r.status_code == 201
    body = r.json()
    assert "id" in body
    assert "secret" in body
    assert "label" in body
    assert "created" in body
    assert isinstance(body["secret"], str) and body["secret"] != ""


def test_admin_mint_key_is_usable(app_and_client):
    app, ks, client = app_and_client
    r = client.post(
        "/admin/keys",
        json={"label": "test-user"},
        headers={"X-Admin-Token": "admin-tok"},
    )
    assert r.status_code == 201
    secret = r.json()["secret"]
    r2 = client.get("/health", headers={"Authorization": f"Bearer {secret}"})
    assert r2.status_code == 200


def test_admin_list_keys(app_and_client):
    app, ks, client = app_and_client
    # Mint a key so there's something to list
    client.post(
        "/admin/keys",
        json={"label": "list-test"},
        headers={"X-Admin-Token": "admin-tok"},
    )
    r = client.get("/admin/keys", headers={"X-Admin-Token": "admin-tok"})
    assert r.status_code == 200
    items = r.json()
    assert isinstance(items, list)
    assert len(items) >= 1
    for item in items:
        assert "id" in item
        assert "label" in item
        assert "created" in item
        assert "secret" not in item


def test_admin_revoke_key(app_and_client):
    app, ks, client = app_and_client
    # Mint a key
    r = client.post(
        "/admin/keys",
        json={"label": "revoke-test"},
        headers={"X-Admin-Token": "admin-tok"},
    )
    assert r.status_code == 201
    body = r.json()
    kid = body["id"]
    secret = body["secret"]

    # Revoke it
    r2 = client.delete(f"/admin/keys/{kid}", headers={"X-Admin-Token": "admin-tok"})
    assert r2.status_code == 204

    # Verify the key is no longer valid (use /query which requires auth)
    r3 = client.post("/query", json={"prompt": "hi"}, headers={"Authorization": f"Bearer {secret}"})
    assert r3.status_code == 401


def test_admin_revoke_nonexistent(app_and_client):
    app, ks, client = app_and_client
    r = client.delete("/admin/keys/nonexistent-id", headers={"X-Admin-Token": "admin-tok"})
    assert r.status_code == 404


def test_admin_requires_token(app_and_client):
    app, ks, client = app_and_client
    r = client.post("/admin/keys", json={"label": "no-auth"})
    assert r.status_code == 403
