from __future__ import annotations
import json
import os
import httpx
from fastapi import FastAPI, Request, HTTPException, Depends, Body
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

from config import Settings, load_settings
from keystore import KeyStore
from ratelimit import RateLimiter


class QueryIn(BaseModel):
    prompt: str
    system: str | None = None
    temperature: float | None = None


class MintIn(BaseModel):
    label: str = ""


def create_app(settings: Settings, keystore: KeyStore, limiter: RateLimiter,
               http_client: httpx.AsyncClient) -> FastAPI:
    app = FastAPI(title="AGH LLM API Gateway")
    app.state.settings = settings
    app.state.keystore = keystore
    app.state.limiter = limiter
    app.state.http = http_client

    def require_key(request: Request) -> str:
        auth = request.headers.get("authorization", "")
        if not auth.lower().startswith("bearer "):
            raise HTTPException(status_code=401, detail="Missing bearer token")
        secret = auth.split(" ", 1)[1].strip()
        if not keystore.is_valid(secret):
            raise HTTPException(status_code=401, detail="Invalid API key")
        if not limiter.allow(secret):
            raise HTTPException(status_code=429, detail="Rate limit exceeded",
                                headers={"Retry-After": "1"})
        return secret

    def require_admin(request: Request) -> None:
        if request.headers.get("x-admin-token", "") != settings.admin_token or not settings.admin_token:
            raise HTTPException(status_code=403, detail="Admin auth required")

    @app.get("/health")
    async def health():
        ollama_up = False
        try:
            r = await http_client.get("/api/tags", timeout=3.0)
            ollama_up = r.status_code == 200
        except Exception:
            ollama_up = False
        return {"status": "ok", "model": settings.model, "ollama": ollama_up}

    _register_query(app, settings, require_key)
    _register_proxy(app, settings, require_key)
    if settings.bundle >= 2:
        _register_admin(app, keystore, require_admin)
    return app


def _register_query(app, settings, require_key):
    @app.post("/query")
    async def query(body: QueryIn = Body(...), _key: str = Depends(require_key)):
        messages = []
        if body.system:
            messages.append({"role": "system", "content": body.system})
        messages.append({"role": "user", "content": body.prompt})
        payload = {"model": settings.model, "messages": messages, "stream": False}
        if body.temperature is not None:
            payload["options"] = {"temperature": body.temperature}
        try:
            r = await app.state.http.post("/api/chat", json=payload, timeout=300.0)
        except Exception:
            raise HTTPException(status_code=503, detail="Ollama unreachable")
        if r.status_code != 200:
            raise HTTPException(status_code=503, detail="Ollama error")
        answer = r.json().get("message", {}).get("content", "")
        return {"answer": answer, "model": settings.model}

def _register_proxy(app, settings, require_key):
    @app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
    async def proxy(path: str, request: Request, _key: str = Depends(require_key)):
        body = await request.body()
        headers = dict(request.headers)
        headers.pop("host", None)
        headers.pop("content-length", None)
        try:
            upstream = await app.state.http.request(
                method=request.method,
                url=f"/v1/{path}",
                content=body,
                headers=headers,
                timeout=300.0,
            )
        except Exception:
            raise HTTPException(status_code=503, detail="Ollama unreachable")
        content_type = upstream.headers.get("content-type", "")
        if "text/event-stream" in content_type:
            return StreamingResponse(
                iter([upstream.content]),
                status_code=upstream.status_code,
                media_type="text/event-stream",
            )
        return JSONResponse(
            content=upstream.json(),
            status_code=upstream.status_code,
        )

def _register_admin(app, keystore, require_admin):
    @app.post("/admin/keys", status_code=201)
    async def mint_key(body: MintIn = Body(...), _: None = Depends(require_admin)):
        rec = keystore.mint(label=body.label)
        return {"id": rec["id"], "secret": rec["secret"], "label": rec["label"], "created": rec["created"]}

    @app.get("/admin/keys")
    async def list_keys(_: None = Depends(require_admin)):
        return keystore.list_ids()

    @app.delete("/admin/keys/{kid}", status_code=204)
    async def revoke_key(kid: str, _: None = Depends(require_admin)):
        if not keystore.revoke(kid):
            raise HTTPException(status_code=404, detail="Key not found")


def build_default_app() -> FastAPI:
    settings = load_settings()
    ks = KeyStore(settings.keyfile)
    ks.load()
    if settings.bootstrap_key:
        ks.add_existing(settings.bootstrap_key, label="bootstrap")
    limiter = RateLimiter(rpm=settings.rate_limit_rpm)
    client = httpx.AsyncClient(base_url=settings.ollama_url)
    return create_app(settings, ks, limiter, client)


app = build_default_app() if os.environ.get("LLM_API_KEY") or os.environ.get("_AGH_BUILD_APP") else None
