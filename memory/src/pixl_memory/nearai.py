"""NEAR AI Cloud client that refuses to send text to an enclave it hasn't verified.

Order per request (docs.near.ai/cloud/verification):
  1. attestation preflight with a fresh nonce — if it fails, nothing is sent;
  2. non-streaming chat completion, keeping the exact request and response bytes;
  3. response signature, checked against those bytes and the attested signer.
"""

from __future__ import annotations

import json
import secrets
import time
from dataclasses import dataclass
from typing import Any, Callable

import httpx

from .verify import (
    DcapQuoteVerifier,
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


class NoCredits(NearAIError):
    """NEAR AI returned 402: no credits or no spending limit on the account."""


class AttestationFailed(NearAIError):
    def __init__(self, verification: Verification):
        super().__init__(verification.to_dict()["summary"])
        self.verification = verification


@dataclass
class VerifiedCompletion:
    content: str
    chat_id: str
    inference_id: str | None
    model: str
    usage: dict[str, Any]
    verification: Verification


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
            raise UpstreamError(f"NEAR AI Cloud unreachable: {e}") from e

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
        return verify_attestation(r.json(), nonce, model, self.quote_verifier, self.gpu_verifier)

    # -- inference --

    def chat(self, messages: list[dict[str, Any]], model: str, **params: Any) -> VerifiedCompletion:
        self._headers(auth=True)  # fail fast without a key, before any network call
        self.require_private(model)

        attestation = self.attest(model)
        if not attestation.attestation_ok or not attestation.model_signing_address:
            raise AttestationFailed(attestation)

        body = {"model": model, "messages": messages, "stream": False, **params}
        req_bytes = encode_body(body)
        headers = self._headers(auth=True) | {"Content-Type": "application/json"}
        try:
            r = self.http.post(f"{self.base_url}/chat/completions", content=req_bytes, headers=headers)
        except httpx.HTTPError as e:
            raise UpstreamError(f"completion failed: {e}") from e
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
        data = json.loads(resp_bytes)
        chat_id = data["id"]

        sig = self._fetch_signature(chat_id, model)
        sig_checks, kind = verify_signature(sig, model, req_bytes, resp_bytes, attestation)
        message = (data.get("choices") or [{}])[0].get("message") or {}
        return VerifiedCompletion(
            content=message.get("content") or "",
            chat_id=chat_id,
            inference_id=r.headers.get("inference-id"),
            model=data.get("model", model),
            usage=data.get("usage") or {},
            verification=combine(attestation, sig_checks, kind),
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
