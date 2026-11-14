"""Localhost HTTP API used by the Mac overlay and the Chrome extension."""

from __future__ import annotations

import secrets
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

from . import polish
from .nearai import AttestationFailed, NearAIClient, ResponseRejected, NoApiKey, NoCredits, NotPrivateModel, Offline, UpstreamError
from .store import Store
from .config import WalletConfigError
from .wallet import Wallet, Wallets

ALLOWED_HOSTS = {"127.0.0.1", "localhost"}


class HighlightIn(BaseModel):
    text: str = Field(min_length=1, max_length=polish.MAX_CHARS)
    url: str | None = Field(default=None, max_length=4096)
    title: str | None = Field(default=None, max_length=1000)
    fragment_url: str | None = Field(default=None, max_length=8192)
    folder: str | None = Field(default=None, max_length=200)


class MoveIn(BaseModel):
    folder: str | None = Field(default=None, max_length=200)


class PolishIn(BaseModel):
    pet: str | None = Field(default=None, max_length=32)   # which Pixl asks (and pays); Frogg when absent
    text: str = Field(min_length=1, max_length=polish.MAX_CHARS)
    instruction: str | None = Field(default=None, max_length=1000)
    model: str | None = None


class AskIn(BaseModel):
    pet: str | None = Field(default=None, max_length=32)   # which Pixl asks (and pays); Frogg when absent
    question: str = Field(min_length=1, max_length=4000)
    name: str = Field(default="Frogg", max_length=40)
    personality: str = Field(default="a friendly pixel frog", max_length=300)
    use_highlights: bool = True
    web: bool = False  # let the model search the web (NEAR AI web_context_search, billed per search)
    model: str | None = None


class LimitsIn(BaseModel):
    pet: str | None = Field(default=None, max_length=32)   # which Pixl asks (and pays); Frogg when absent
    per_day_near: str | None = Field(default=None, pattern=r"^\d+(\.\d{1,24})?$", max_length=40)
    per_week_near: str | None = Field(default=None, pattern=r"^\d+(\.\d{1,24})?$", max_length=40)
    paused: bool | None = None


class StatusIn(BaseModel):
    status: str


def create_app(store: Store, client: NearAIClient, token: str, default_model: str,
               wallet: Wallet | Wallets | None = None) -> FastAPI:
    # every Pixl pays from its own account (<pet>.<owner>); a lone Wallet is Frogg's, as before
    wallets: Wallets | None = Wallets.of(wallet) if isinstance(wallet, Wallet) else wallet

    def pet_wallet(pet: str | None) -> Wallet | None:
        if wallets is None:
            return None
        try:
            return wallets.for_pet(pet)
        except WalletConfigError as e:
            raise HTTPException(400, str(e)) from None

    app = FastAPI(title="Pixl Memory", version="0.1.0", docs_url=None, redoc_url=None)
    app.state.near_client = client
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

    def refused(e: AttestationFailed) -> JSONResponse:
        return JSONResponse({"error": "attestation_failed", "message": str(e), "text_sent": False,
                             "verification": e.verification.to_dict()}, status_code=409)

    def untrusted(e: ResponseRejected) -> JSONResponse:
        # The text did reach an attested enclave, but the reply failed its signature checks: it is
        # discarded (not returned, not saved as a draft, not paid for from the Pixl's wallet).
        return JSONResponse({"error": "response_untrusted", "message": str(e), "text_sent": True,
                             "verification": e.verification.to_dict()}, status_code=502)

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
        return store.add_highlight(h.text, h.url, h.title, h.fragment_url, h.folder).to_dict()

    @app.get("/highlights", dependencies=guarded)
    def list_highlights(q: str | None = None, limit: int = 50, folder: str | None = None) -> dict[str, Any]:
        return {"highlights": [h.to_dict() for h in store.list_highlights(q, min(max(limit, 1), 500), folder)]}

    @app.get("/folders", dependencies=guarded)
    def list_folders() -> dict[str, Any]:
        return {"folders": store.folders()}

    @app.patch("/highlights/{hid}", dependencies=guarded)
    def move_highlight(hid: str, m: MoveIn) -> dict[str, Any]:
        if not store.move_highlight(hid, m.folder):
            raise HTTPException(404, "no such highlight")
        h = store.get_highlight(hid)
        assert h is not None
        return h.to_dict()

    @app.delete("/highlights/{hid}", dependencies=guarded, status_code=204)
    def delete_highlight(hid: str) -> None:
        if not store.delete_highlight(hid):
            raise HTTPException(404, "no such highlight")

    # -- polish --

    @app.post("/polish", dependencies=guarded)
    def do_polish(p: PolishIn) -> JSONResponse:
        model = p.model or default_model
        wallet = pet_wallet(p.pet)
        if wallet and (why := wallet.blocked()):
            return JSONResponse({"error": "frogg_out_of_allowance", "message": why}, status_code=402)
        try:
            comp = client.chat(polish.messages(p.text, p.instruction), model, temperature=0.3, max_tokens=4096)
        except NoApiKey as e:
            return JSONResponse({"error": "no_api_key", "message": str(e)}, status_code=412)
        except NotPrivateModel as e:
            return JSONResponse({"error": "not_private", "message": str(e)}, status_code=400)
        except AttestationFailed as e:
            # The text was never sent. Show the user why.
            return refused(e)
        except ResponseRejected as e:
            return untrusted(e)
        except NoCredits as e:
            return JSONResponse({"error": "no_credits", "message": str(e)}, status_code=402)
        except Offline as e:
            return JSONResponse({"error": "offline", "message": str(e)}, status_code=503)
        except UpstreamError as e:
            return JSONResponse({"error": "upstream", "message": str(e)}, status_code=502)

        suggestion = polish.clean(comp.content, p.text)
        ops = polish.word_diff(p.text, suggestion)
        verification = comp.verification.to_dict()
        draft = store.add_draft(model=comp.model, chat_id=comp.chat_id, source=p.text,
                                instruction=p.instruction or polish.DEFAULT_INSTRUCTION,
                                suggestion=suggestion, verification=verification)
        receipt = None
        if wallet:
            # The Pixl pays for its own inference, from its own account, after the result is stored.
            cost = client.request_cost_nano_usd(comp.inference_id) if comp.inference_id else None
            receipt = wallet.pay(cost, {"draft_id": draft.id, "model": comp.model, "verdict": verification["verdict"],
                                        "inference_id": comp.inference_id})
            store.set_draft_receipt(draft.id, receipt)
        return JSONResponse({
            "receipt": receipt,
            "draft_id": draft.id,
            "suggestion": suggestion,
            "diff": ops,
            "stats": polish.diff_stats(ops),
            "verification": verification,
            "usage": comp.usage,
            "inference_id": comp.inference_id,
        })

    @app.post("/ask", dependencies=guarded)
    def do_ask(a: AskIn) -> JSONResponse:
        """Ask the Pixl anything: same attest-before-send flow as polish; the user's recent
        highlights (decrypted locally) go along as context, only to the attested enclave."""
        model = a.model or default_model
        wallet = pet_wallet(a.pet)
        if wallet and (why := wallet.blocked()):
            return JSONResponse({"error": "frogg_out_of_allowance", "message": why}, status_code=402)
        picked, matched = polish.rank_highlights(a.question, store.list_highlights(limit=500)) if a.use_highlights else ([], False)
        notes = [h.text for h in picked]
        try:
            comp = client.chat(polish.ask_messages(a.question, a.name, a.personality, notes, web=a.web), model,
                               web=a.web, temperature=0.5, max_tokens=1024)
        except NoApiKey as e:
            return JSONResponse({"error": "no_api_key", "message": str(e)}, status_code=412)
        except NotPrivateModel as e:
            return JSONResponse({"error": "not_private", "message": str(e)}, status_code=400)
        except AttestationFailed as e:
            return refused(e)
        except ResponseRejected as e:
            return untrusted(e)
        except NoCredits as e:
            return JSONResponse({"error": "no_credits", "message": str(e)}, status_code=402)
        except Offline as e:
            if not matched:
                return JSONResponse({"error": "offline", "message": str(e)}, status_code=503)
            # No internet: nothing was sent, but what you saved is on this Mac. Show the matches.
            return JSONResponse({"answer": "I'm offline, so I can't think it through. Here's what you saved that matches.",
                                 "verification": {"verdict": "offline", "summary": "Offline: nothing was sent.",
                                                  "checks": [], "model": model},
                                 "receipt": None, "used_highlights": 0, "offline": True,
                                 "highlights": [{"id": h.id, "text": h.text[:280], "title": h.title, "url": h.url,
                                                 "fragment_url": h.fragment_url} for h in picked],
                                 "inference_id": None})
        except UpstreamError as e:
            return JSONResponse({"error": "upstream", "message": str(e)}, status_code=502)
        answer = polish.clean(comp.content, "")
        verification = comp.verification.to_dict()
        receipt = None
        if wallet:
            cost = client.request_cost_nano_usd(comp.inference_id) if comp.inference_id else None
            receipt = wallet.pay(cost, {"kind": "ask", "model": comp.model, "verdict": verification["verdict"],
                                        "searched": bool(comp.tool_results),
                                        "inference_id": comp.inference_id})
        # The ones that matched the question come back as sources, each with its backlink.
        sources = [{"id": h.id, "text": h.text[:280], "title": h.title, "url": h.url, "fragment_url": h.fragment_url}
                   for h in picked] if matched else []
        web = polish.web_sources(comp.tool_results)
        return JSONResponse({"answer": answer, "verification": verification, "receipt": receipt,
                             "used_highlights": len(notes), "highlights": sources, "inference_id": comp.inference_id,
                             "searched": bool(comp.tool_results), "web_sources": web})

    # -- Frogg's wallet --

    @app.get("/wallet", dependencies=guarded)
    def wallet_status(pet: str | None = None) -> dict[str, Any]:
        wallet = pet_wallet(pet)
        return wallet.status() if wallet else {"configured": False,
                                               "setup": "set PIXL_PARENT_ACCOUNT (the owner's testnet account) in .env"}

    @app.post("/wallet/limits", dependencies=guarded)
    def wallet_limits(body: LimitsIn) -> JSONResponse:
        """The user tightens (or relaxes, up to the owner's ceilings) Frogg's daily and weekly
        limits, or pauses spending. Enforced before anything is signed."""
        wallet = pet_wallet(body.pet)
        if not wallet:
            return JSONResponse({"error": "no_wallet", "message": "the wallet isn't configured"}, status_code=409)
        try:
            wallet.limits.update(body.per_day_near, body.per_week_near, body.paused)
        except ValueError as e:
            return JSONResponse({"error": "bad_limit", "message": str(e)}, status_code=400)
        return JSONResponse(wallet.status())

    @app.get("/wallet/payments", dependencies=guarded)
    def wallet_payments(limit: int = 20, pet: str | None = None) -> dict[str, Any]:
        wallet = pet_wallet(pet)
        n = min(max(limit, 1), 200)
        return {"payments": wallet.payments(n) if wallet else store.list_payments(n)}

    @app.get("/wallet/setup", response_class=HTMLResponse)
    def wallet_setup(pet: str | None = None) -> HTMLResponse:
        # No token: the page shows only public names and Frogg's public key, and is
        # served to localhost only (host guard). The owner signs in Meteor, not here.
        wallet = pet_wallet(pet)
        if not wallet:
            return HTMLResponse("<p>Set PIXL_PARENT_ACCOUNT in .env, then restart.</p>", 503)
        from .setup_page import render

        key = wallet.key()
        return HTMLResponse(render(wallet.cfg, key.public_key if key else None),
                            headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})

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
