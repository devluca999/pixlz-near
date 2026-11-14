"""NEAR AI Cloud client that refuses to send text to an enclave it hasn't verified.

Order per request (docs.near.ai/cloud/verification):
  1. attestation preflight with a fresh nonce — if it fails, nothing is sent;
  2. chat completion, keeping the exact request and response bytes (non-streaming; streamed
     only for web search, which NEAR AI runs server-side and requires streaming for);
  3. response signature, checked against those bytes and the attested signer.
"""

from __future__ import annotations

import json
import secrets
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import httpx

from .verify import (
    Check,
    DcapQuoteVerifier,
    Status,
    Verdict,
    GpuVerifier,
    NrasGpuVerifier,
    QuoteVerifier,
    Verification,
    combine,
    verify_attestation,
    verify_signature,
)

DEFAULT_BASE_URL = "https://cloud-api.near.ai/v1"
DEFAULT_MODEL = "z-ai/glm-5.3-flash"
PRIVATE_OWNER = "nearai"  # models served from NEAR AI's own attested TEE fleet


class NearAIError(Exception):
    pass


class NoApiKey(NearAIError):
    pass


class NotPrivateModel(NearAIError):
    pass


class UpstreamError(NearAIError):
    pass


class Offline(UpstreamError):
    """NEAR AI Cloud can't be reached at all (no internet, DNS, connection refused)."""


def _unreachable(e: httpx.HTTPError, what: str) -> UpstreamError:
    if isinstance(e, (httpx.ConnectError, httpx.ConnectTimeout)):
        return Offline(f"no internet: {what} unreachable ({e})")
    return UpstreamError(f"{what} unreachable: {e}")


class NoCredits(NearAIError):
    """NEAR AI returned 402: no credits or no spending limit on the account."""


class AttestationFailed(NearAIError):
    def __init__(self, verification: Verification):
        super().__init__(verification.to_dict()["summary"])
        self.verification = verification


class ResponseRejected(NearAIError):
    """The text was sent to an attested enclave, but the reply failed its signature or binding
    checks (forged, tampered, wrong signer, wrong model). The reply is discarded, never shown as a result."""

    def __init__(self, verification: Verification):
        super().__init__(verification.to_dict()["summary"])
        self.verification = verification


def _refused(model: str, nonce: str, check_id: str, label: str, detail: str) -> Verification:
    return Verification(verdict=Verdict.FAILED, checks=[Check(check_id, label, Status.FAIL, detail)],
                        model=model, nonce=nonce)


@dataclass
class VerifiedCompletion:
    content: str
    chat_id: str
    inference_id: str | None
    model: str
    usage: dict[str, Any]
    verification: Verification
    # web_context_search results NEAR AI fed to the model (one per search), if it searched
    tool_results: list[dict[str, Any]] = field(default_factory=list)


WEB_SEARCH = {"type": "web_context_search"}


def parse_stream(raw: bytes) -> dict[str, Any]:
    """Folds a streamed (SSE) chat completion into its id, model, answer text, usage and the
    server-side tool results. The signature covers `raw` itself, so nothing here is trusted
    more than the bytes are."""
    out: dict[str, Any] = {"id": None, "model": None, "content": "", "usage": {}, "tool_results": []}
    parts: list[str] = []
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            chunk = json.loads(data)
        except ValueError:
            continue
        out["id"] = out["id"] or chunk.get("id")
        out["model"] = out["model"] or chunk.get("model")
        if chunk.get("usage"):
            out["usage"] = chunk["usage"]
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            if delta.get("content"):
                parts.append(delta["content"])
            if isinstance(delta.get("nearai_tool_result"), dict):
                out["tool_results"].append(delta["nearai_tool_result"])
    out["content"] = "".join(parts)
    return out


def encode_body(body: dict[str, Any]) -> bytes:
    """The bytes we hash are the bytes we send, so serialize once, here."""
    return json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()


class NearAIClient:
    def __init__(
        self,
        api_key: str | None,
        base_url: str = DEFAULT_BASE_URL,
        http: httpx.Client | None = None,
        quote_verifier: QuoteVerifier | None = None,
        gpu_verifier: GpuVerifier | None = None,
        signature_wait: float = 8.0,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.http = http or httpx.Client(timeout=httpx.Timeout(120, connect=10))
        self.quote_verifier = quote_verifier or DcapQuoteVerifier()
        self.gpu_verifier = gpu_verifier if gpu_verifier is not None else NrasGpuVerifier(self.http)
        self.signature_wait = signature_wait
        self.sleep = sleep
        self._models: dict[str, dict[str, Any]] | None = None

    # -- helpers --

    def _headers(self, auth: bool) -> dict[str, str]:
        h = {"Accept": "application/json", "Accept-Encoding": "identity", "x-no-aliasing": "true"}
        if auth:
            if not self.api_key:
                raise NoApiKey("set NEAR_AI_API_KEY in .env (copy .env.example; key from cloud.near.ai → API Keys)")
            h["Authorization"] = f"Bearer {self.api_key}"
        return h

    def _get(self, path: str, params: dict[str, Any] | None = None, auth: bool = False) -> httpx.Response:
        try:
            return self.http.get(f"{self.base_url}{path}", params=params, headers=self._headers(auth))
        except httpx.HTTPError as e:
            raise _unreachable(e, "NEAR AI Cloud") from e

    # -- models --

    def models(self) -> dict[str, dict[str, Any]]:
        if self._models is None:
            r = self._get("/models")
            if r.status_code != 200:
                raise UpstreamError(f"/models returned {r.status_code}")
            self._models = {m["id"]: m for m in r.json().get("data", [])}
        return self._models

    def private_models(self) -> list[str]:
        return sorted(i for i, m in self.models().items() if m.get("owned_by") == PRIVATE_OWNER)

    def require_private(self, model: str) -> None:
        m = self.models().get(model)
        if m is None:
            raise NotPrivateModel(f"{model} is not offered by NEAR AI Cloud")
        if m.get("owned_by") != PRIVATE_OWNER:
            raise NotPrivateModel(
                f"{model} is owned by {m.get('owned_by')!r}, not served from NEAR AI's own TEEs; refusing to send text to it"
            )

    # -- attestation --

    def attest(self, model: str, nonce: str | None = None) -> Verification:
        nonce = nonce or secrets.token_hex(32)
        r = self._get(
            "/attestation/report",
            params={"model": model, "provider": "near", "signing_algo": "ecdsa", "nonce": nonce},
            auth=bool(self.api_key),
        )
        if r.status_code != 200:
            raise UpstreamError(f"attestation report returned {r.status_code}: {r.text[:200]}")
        try:
            body = r.json()
        except ValueError:
            return _refused(model, nonce, "report.format", "Attestation report readable", "the report is not JSON")
        if not isinstance(body, dict) or not body:
            return _refused(model, nonce, "report.format", "Attestation report readable", "the report is empty or not an object")
        try:
            return verify_attestation(body, nonce, model, self.quote_verifier, self.gpu_verifier)
        except Exception as e:   # malformed evidence anywhere: refuse, never crash open
            return _refused(model, nonce, "report.format", "Attestation report readable", f"malformed evidence: {type(e).__name__}: {e}")

    # -- inference --

    def chat(self, messages: list[dict[str, Any]], model: str, *, web: bool = False, **params: Any) -> VerifiedCompletion:
        """One verified completion. `web=True` lets the model search the web (NEAR AI's
        web_context_search, run server-side); that reply streams, and the streamed bytes are what
        the signature covers."""
        self._headers(auth=True)  # fail fast without a key, before any network call
        self.require_private(model)

        attestation = self.attest(model)
        if not attestation.attestation_ok or not attestation.model_signing_address:
            raise AttestationFailed(attestation)

        body = {"model": model, "messages": messages, "stream": web, **params}
        if web:
            body["tools"] = [WEB_SEARCH]
        req_bytes = encode_body(body)
        headers = self._headers(auth=True) | {"Content-Type": "application/json"}
        try:
            r = self.http.post(f"{self.base_url}/chat/completions", content=req_bytes, headers=headers)
        except httpx.HTTPError as e:
            raise _unreachable(e, "NEAR AI completion") from e
        if r.status_code == 402:
            try:
                msg = r.json()["error"]["message"]
            except (ValueError, KeyError, TypeError):
                msg = r.text[:200]
            raise NoCredits(f"NEAR AI account can't pay for this request: {msg} "
                            "(add credits and a spend limit at cloud.near.ai)")
        if r.status_code != 200:
            raise UpstreamError(f"completion returned {r.status_code}: {r.text[:300]}")
        resp_bytes = r.content
        if web:
            folded = parse_stream(resp_bytes)
            if not folded["id"]:
                raise UpstreamError("streamed completion had no id")
            content, chat_id, usage, tools = folded["content"], folded["id"], folded["usage"], folded["tool_results"]
            got_model = folded["model"] or model
        else:
            data = json.loads(resp_bytes)
            chat_id = data["id"]
            content = ((data.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
            usage, tools, got_model = data.get("usage") or {}, [], data.get("model", model)

        sig = self._fetch_signature(chat_id, model)
        sig_checks, kind = verify_signature(sig, model, req_bytes, resp_bytes, attestation)
        # x-no-aliasing is set, so the reply must name the exact model whose enclave we attested.
        if str(got_model).strip().lower() != model.lower():
            sig_checks.append(Check("response.model", "Reply is from the attested model", Status.FAIL,
                                    f"reply names {got_model!r}, we attested {model!r}"))
        verification = combine(attestation, sig_checks, kind)
        if verification.signature_failed:
            # A forged, tampered or mis-signed reply never becomes a usable result.
            raise ResponseRejected(verification)
        return VerifiedCompletion(
            content=content,
            chat_id=chat_id,
            inference_id=r.headers.get("inference-id"),
            model=got_model,
            usage=usage,
            verification=verification,
            tool_results=tools,
        )

    def _fetch_signature(self, chat_id: str, model: str) -> dict[str, Any] | None:
        """Signatures can take a moment to appear; retry 404s for a bounded time."""
        deadline = time.monotonic() + self.signature_wait
        delay = 0.5
        last: dict[str, Any] | None = None
        while True:
            r = self._get(f"/signature/{chat_id}", params={"model": model, "signing_algo": "ecdsa"}, auth=True)
            if r.status_code == 200:
                last = r.json()
                if not last.get("error_code"):
                    return last
            elif r.status_code != 404:
                return {"error_code": str(r.status_code), "message": f"signature endpoint returned {r.status_code}"}
            if time.monotonic() + delay > deadline:
                return last or {"error_code": "not_found", "message": "signature not available yet"}
            self.sleep(delay)
            delay = min(delay * 2, 2.0)

    # -- billing --

    def request_cost_nano_usd(self, inference_id: str) -> int | None:
        """Cost of one request in nano-USD, or None if billing hasn't caught up."""
        try:
            r = self.http.post(f"{self.base_url}/billing/costs", json={"requestIds": [inference_id]},
                               headers=self._headers(auth=True))
        except httpx.HTTPError:
            return None
        if r.status_code != 200:
            return None
        for item in r.json().get("requests", []):
            if item.get("requestId") == inference_id and item.get("costNanoUsd"):
                return int(item["costNanoUsd"])
        return None
