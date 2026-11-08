"""Localhost HTTP API used by the Mac overlay and the Chrome extension."""

from __future__ import annotations

import secrets
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import polish
from .nearai import AttestationFailed, NearAIClient, NoApiKey, NotPrivateModel, UpstreamError
from .store import Store

ALLOWED_HOSTS = {"127.0.0.1", "localhost"}


class HighlightIn(BaseModel):
    text: str = Field(min_length=1, max_length=polish.MAX_CHARS)
    url: str | None = Field(default=None, max_length=4096)
    title: str | None = Field(default=None, max_length=1000)
    fragment_url: str | None = Field(default=None, max_length=8192)


class PolishIn(BaseModel):
    text: str = Field(min_length=1, max_length=polish.MAX_CHARS)
    instruction: str | None = Field(default=None, max_length=1000)
    model: str | None = None


class StatusIn(BaseModel):
    status: str


def create_app(store: Store, client: NearAIClient, token: str, default_model: str) -> FastAPI:
    app = FastAPI(title="Pixl Memory", version="0.1.0", docs_url=None, redoc_url=None)
    app.add_middleware(
        CORSMiddleware,
        allow_origin_regex=r"chrome-extension://[a-p]{32}",
        allow_methods=["GET", "POST", "DELETE"],
        allow_headers=["Authorization", "Content-Type"],
    )

    @app.middleware("http")
    async def host_guard(request: Request, call_next):
        # Blocks DNS-rebinding: a web page can't reach us through a hostname it controls.
        host = (request.headers.get("host") or "").rsplit(":", 1)[0].strip("[]")
        if host not in ALLOWED_HOSTS and host != "testserver":
            return JSONResponse({"error": "bad host"}, status_code=421)
        return await call_next(request)

    def auth(request: Request) -> None:
        given = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
        if not secrets.compare_digest(given.encode(), token.encode()):
            raise HTTPException(401, "missing or wrong token (see `pixl-memory token`)")

    guarded = [Depends(auth)]

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"ok": True, "model": default_model, "has_api_key": bool(client.api_key)}

    # -- verification --

    @app.get("/attestation", dependencies=guarded)
    def attestation(model: str | None = None) -> dict[str, Any]:
        m = model or default_model
        try:
            client.require_private(m)
            return client.attest(m).to_dict()
        except NotPrivateModel as e:
            raise HTTPException(400, str(e))
        except UpstreamError as e:
            raise HTTPException(502, str(e))

    @app.get("/models", dependencies=guarded)
    def models() -> dict[str, Any]:
        try:
            return {"default": default_model, "private": client.private_models()}
        except UpstreamError as e:
            raise HTTPException(502, str(e))

    # -- highlights --

    @app.post("/highlights", dependencies=guarded, status_code=201)
    def add_highlight(h: HighlightIn) -> dict[str, Any]:
        return store.add_highlight(h.text, h.url, h.title, h.fragment_url).to_dict()

    @app.get("/highlights", dependencies=guarded)
    def list_highlights(q: str | None = None, limit: int = 50) -> dict[str, Any]:
        return {"highlights": [h.to_dict() for h in store.list_highlights(q, min(max(limit, 1), 500))]}

    @app.delete("/highlights/{hid}", dependencies=guarded, status_code=204)
    def delete_highlight(hid: str) -> None:
        if not store.delete_highlight(hid):
            raise HTTPException(404, "no such highlight")

    # -- polish --

    @app.post("/polish", dependencies=guarded)
    def do_polish(p: PolishIn) -> JSONResponse:
        model = p.model or default_model
        try:
            comp = client.chat(polish.messages(p.text, p.instruction), model, temperature=0.3, max_tokens=4096)
        except NoApiKey as e:
            return JSONResponse({"error": "no_api_key", "message": str(e)}, status_code=412)
        except NotPrivateModel as e:
            return JSONResponse({"error": "not_private", "message": str(e)}, status_code=400)
        except AttestationFailed as e:
            # The text was never sent. Show the user why.
            return JSONResponse({"error": "attestation_failed", "message": str(e),
                                 "verification": e.verification.to_dict()}, status_code=409)
        except UpstreamError as e:
            return JSONResponse({"error": "upstream", "message": str(e)}, status_code=502)

        suggestion = polish.clean(comp.content, p.text)
        ops = polish.word_diff(p.text, suggestion)
        verification = comp.verification.to_dict()
        draft = store.add_draft(model=comp.model, chat_id=comp.chat_id, source=p.text,
                                instruction=p.instruction or polish.DEFAULT_INSTRUCTION,
                                suggestion=suggestion, verification=verification)
        return JSONResponse({
            "draft_id": draft.id,
            "suggestion": suggestion,
            "diff": ops,
            "stats": polish.diff_stats(ops),
            "verification": verification,
            "usage": comp.usage,
            "inference_id": comp.inference_id,
        })

    # -- drafts --

    @app.get("/drafts", dependencies=guarded)
    def list_drafts(limit: int = 50) -> dict[str, Any]:
        return {"drafts": [d.to_dict() for d in store.list_drafts(min(max(limit, 1), 500))]}

    @app.get("/drafts/{did}", dependencies=guarded)
    def get_draft(did: str) -> dict[str, Any]:
        d = store.get_draft(did)
        if not d:
            raise HTTPException(404, "no such draft")
        return d.to_dict()

    @app.post("/drafts/{did}/status", dependencies=guarded)
    def set_status(did: str, s: StatusIn) -> dict[str, Any]:
        try:
            ok = store.set_draft_status(did, s.status)
        except ValueError as e:
            raise HTTPException(400, str(e))
        if not ok:
            raise HTTPException(404, "no such draft")
        return {"ok": True}

    return app
