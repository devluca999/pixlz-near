"""Verification of NEAR AI Cloud attestation reports and response signatures.

Follows docs.near.ai/cloud/verification (read 2026-11-08). Each step becomes a
named Check so the UI can show the user exactly what was proven and what wasn't.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import time
from dataclasses import asdict, dataclass, field
from enum import StrEnum
from typing import Any, Protocol

import httpx

from . import tdx

NRAS_URL = "https://nras.attestation.nvidia.com/v3/attest/gpu"

# Intel TCB statuses. dcap-qvl rejects bad signatures and revoked keys itself.
TCB_PASS = {"UpToDate"}
TCB_WARN = {"OutOfDate", "SWHardeningNeeded", "ConfigurationAndSWHardeningNeeded", "ConfigurationNeeded",
            "OutOfDateConfigurationNeeded"}


class Status(StrEnum):
    PASS = "pass"
    WARN = "warn"  # passed, with a caveat the user should see
    FAIL = "fail"
    SKIP = "skip"  # could not be checked


class Verdict(StrEnum):
    VERIFIED = "verified"
    PARTIAL = "partial"
    FAILED = "failed"


@dataclass
class Check:
    id: str
    label: str
    status: Status
    detail: str = ""


@dataclass
class Verification:
    verdict: Verdict
    checks: list[Check]
    model: str
    nonce: str
    gateway_signing_address: str | None = None
    model_signing_address: str | None = None
    signature_kind: str | None = None
    images: list[str] = field(default_factory=list)
    verified_at: float = field(default_factory=time.time)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["summary"] = summarize(self)
        return d

    @property
    def attestation_ok(self) -> bool:
        """True when no attestation check failed (signature checks excluded)."""
        return not any(c.status is Status.FAIL for c in self.checks if not c.id.startswith("signature."))


def compute_verdict(checks: list[Check], signature_kind: str | None, *, need_signature: bool) -> Verdict:
    if any(c.status is Status.FAIL for c in checks):
        return Verdict.FAILED
    if any(c.status is Status.SKIP for c in checks):
        return Verdict.PARTIAL
    if need_signature and signature_kind != "provider_tee":
        return Verdict.PARTIAL
    return Verdict.VERIFIED


def summarize(v: Verification) -> str:
    if v.verdict is Verdict.FAILED:
        bad = next(c for c in v.checks if c.status is Status.FAIL)
        return f"Not verified: {bad.label.lower()} failed. Treat this result as untrusted."
    if v.verdict is Verdict.PARTIAL:
        if v.signature_kind == "gateway":
            return "Partly verified: signed by NEAR's attested gateway, not by the model enclave itself."
        skipped = [c.label.lower() for c in v.checks if c.status is Status.SKIP]
        return "Partly verified: could not check " + ", ".join(skipped) + "."
    if v.signature_kind == "provider_tee":
        return "Verified: the reply was signed inside an attested Intel TDX + NVIDIA GPU enclave running this model."
    return "Verified: the model enclave is attested (Intel TDX + NVIDIA GPU) and bound to this session's nonce."


# --- pluggable external verifiers (faked in tests) -------------------------------------------


@dataclass
class QuoteResult:
    status: str
    advisories: list[str]


class QuoteVerifier(Protocol):
    def verify(self, raw_quote: bytes) -> QuoteResult: ...


class DcapQuoteVerifier:
    """Verifies the quote's signature chain and TCB status with Phala's dcap-qvl."""

    def __init__(self, pccs_url: str | None = None):
        self.pccs_url = pccs_url or os.environ.get("PIXL_PCCS_URL")

    def verify(self, raw_quote: bytes) -> QuoteResult:
        import dcap_qvl

        async def run() -> Any:
            return await dcap_qvl.get_collateral_and_verify(raw_quote, self.pccs_url)

        res = asyncio.run(run())
        return QuoteResult(status=str(res.status), advisories=list(res.advisory_ids))


@dataclass
class GpuResult:
    ok: bool
    detail: str


class GpuVerifier(Protocol):
    def verify(self, payload: dict[str, Any]) -> GpuResult: ...


class NrasGpuVerifier:
    """Posts the GPU evidence unchanged to NVIDIA's Remote Attestation Service."""

    def __init__(self, http: httpx.Client, url: str = NRAS_URL):
        self.http, self.url = http, url

    def verify(self, payload: dict[str, Any]) -> GpuResult:
        r = self.http.post(self.url, json=payload, timeout=60)
        r.raise_for_status()
        return check_nras_response(r.json(), str(payload.get("nonce", "")), time.time())


def check_nras_response(body: Any, nonce: str, now: float) -> GpuResult:
    """Checks from NEAR's near-ai-cloud agent skill: overall result, nonce on every
    token, and per GPU: secure boot on, debug disabled, every x-nvidia-* boolean
    check true, no attestation warning, token not expired.
    The JWTs arrive over TLS from NVIDIA; their ES384 signatures are not re-checked here."""
    if not isinstance(body, list) or not body:
        return GpuResult(False, "NRAS returned an unexpected response")
    token = next((item[1] for item in body if isinstance(item, list) and item[:1] == ["JWT"]), None)
    if not token:
        return GpuResult(False, "NRAS returned no JWT")
    overall = _jwt_claims(token)
    if overall.get("x-nvidia-overall-att-result") is not True:
        return GpuResult(False, "NVIDIA reported the GPU attestation as failed")
    if overall.get("eat_nonce") != nonce:
        return GpuResult(False, "NRAS token nonce does not match ours")
    if float(overall.get("exp", 0)) <= now:
        return GpuResult(False, "NRAS token expired")
    gpus = body[1] if len(body) > 1 and isinstance(body[1], dict) else {}
    if not gpus:
        return GpuResult(False, "NRAS returned no per-GPU results")
    models = set()
    for name, gtoken in gpus.items():
        g = _jwt_claims(gtoken)
        models.add(str(g.get("hwmodel", "?")))
        problems = []
        if g.get("eat_nonce") != nonce:
            problems.append("nonce")
        if g.get("secboot") is not True:
            problems.append("secure boot off")
        if g.get("dbgstat") != "disabled":
            problems.append("debug enabled")
        if g.get("x-nvidia-attestation-warning") is not None:
            problems.append(f"warning: {g.get('x-nvidia-attestation-warning')}")
        problems += [k for k, v in g.items() if k.startswith("x-nvidia-") and isinstance(v, bool) and v is not True]
        if float(g.get("exp", 0)) <= now:
            problems.append("expired")
        if problems:
            return GpuResult(False, f"{name}: {', '.join(problems)}")
    return GpuResult(True, f"NVIDIA NRAS: {len(gpus)} × {'/'.join(sorted(models))}, secure boot on, debug off, all checks true")


def _jwt_claims(token: str) -> dict[str, Any]:
    part = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


# --- report verification ----------------------------------------------------------------------


def _addr_bytes(signing_address: str, algo: str) -> bytes:
    raw = bytes.fromhex(signing_address.removeprefix("0x"))
    expected = 20 if algo == "ecdsa" else 32
    if len(raw) != expected:
        raise ValueError(f"{algo} signing address should be {expected} bytes, got {len(raw)}")
    return raw


def verify_report(
    report: dict[str, Any],
    nonce: str,
    role: str,
    quote_verifier: QuoteVerifier,
    gpu_verifier: GpuVerifier | None,
) -> tuple[list[Check], str | None]:
    """Verify one gateway or model attestation. Returns the checks and, if the
    signer is bound inside a valid quote, the attested signing address."""
    p = f"{role}."
    who = "Gateway" if role == "gateway" else "Model"
    checks: list[Check] = []
    bound: str | None = None

    quote_hex = report.get("intel_quote") or ""
    try:
        raw = bytes.fromhex(quote_hex)
        fields = tdx.parse_td_quote(raw)
    except ValueError as e:
        return [Check(p + "quote", f"{who} Intel TDX quote", Status.FAIL, f"unreadable quote: {e}")], None

    # 1. Quote signature chain and TCB status.
    try:
        qr = quote_verifier.verify(raw)
        adv = f" (advisories: {', '.join(qr.advisories)})" if qr.advisories else ""
        if qr.status in TCB_PASS:
            checks.append(Check(p + "quote", f"{who} Intel TDX quote", Status.PASS, f"signed by Intel, TCB {qr.status}{adv}"))
        elif qr.status in TCB_WARN:
            checks.append(Check(p + "quote", f"{who} Intel TDX quote", Status.WARN, f"signed by Intel, TCB {qr.status}{adv}"))
        else:
            checks.append(Check(p + "quote", f"{who} Intel TDX quote", Status.FAIL, f"TCB status {qr.status}{adv}"))
    except Exception as e:  # network, collateral, or signature failure
        checks.append(Check(p + "quote", f"{who} Intel TDX quote", Status.FAIL, f"quote verification failed: {e}"))

    # 2. Not a debug TD.
    checks.append(
        Check(p + "debug", f"{who} production TD", Status.FAIL if fields.debug else Status.PASS,
              "debug bit set: host can read enclave memory" if fields.debug else "TD debug bit off")
    )

    # 3. Our nonce is inside the signed report_data (freshness, no replay).
    rd_nonce = fields.report_data[32:].hex()
    nonce_ok = rd_nonce == nonce.lower() and (report.get("request_nonce") or nonce).lower() == nonce.lower()
    checks.append(Check(p + "nonce", f"{who} fresh for this request", Status.PASS if nonce_ok else Status.FAIL,
                        "our nonce is in the signed report data" if nonce_ok else f"report data carries nonce {rd_nonce[:16]}…, not ours"))

    # 4. The signing key is inside the signed report_data.
    algo = report.get("signing_algo", "ecdsa")
    addr = report.get("signing_address") or ""
    try:
        want = _addr_bytes(addr, algo).ljust(32, b"\x00")
        signer_ok = fields.report_data[:32] == want
        detail = f"{addr} is bound in the quote" if signer_ok else f"{addr} is not the key in the quote"
    except ValueError as e:
        signer_ok, detail = False, str(e)
    checks.append(Check(p + "signer", f"{who} signing key bound", Status.PASS if signer_ok else Status.FAIL, detail))

    # 5. RTMR3 replay: the runtime event log is what the quote measured.
    try:
        events = tdx.parse_event_log(report.get("event_log"))
        rtmr_ok = tdx.replay_rtmr3(events) == fields.rtmr[3]
        rt_events = tdx.runtime_events(events)
        checks.append(Check(p + "rtmr3", f"{who} event log replay", Status.PASS if rtmr_ok else Status.FAIL,
                            f"{sum(1 for e in events if e.get('imr') == 3)} runtime events reproduce RTMR3" if rtmr_ok else "replayed RTMR3 differs from the quote"))
    except (ValueError, KeyError, TypeError) as e:
        rtmr_ok, rt_events = False, {}
        checks.append(Check(p + "rtmr3", f"{who} event log replay", Status.FAIL, f"bad event log: {e}"))

    # 6. The docker-compose the enclave runs is the one shown to us.
    app_compose = ((report.get("info") or {}).get("tcb_info") or {}).get("app_compose")
    if isinstance(app_compose, str):
        compose_hash = hashlib.sha256(app_compose.encode()).hexdigest()
        cfg_ok = fields.mr_config_id == tdx.expected_mr_config_id(app_compose)
        ev_ok = rt_events.get("compose-hash", compose_hash) == compose_hash
        ok = cfg_ok and ev_ok
        checks.append(Check(p + "compose", f"{who} app config measured", Status.PASS if ok else Status.FAIL,
                            f"compose sha256 {compose_hash[:16]}… matches MRCONFIGID" if ok else "app_compose does not match the measured config"))
    else:
        checks.append(Check(p + "compose", f"{who} app config measured", Status.FAIL, "no app_compose in report"))

    # 7. NVIDIA GPU evidence (model only).
    if role == "model":
        payload_s = report.get("nvidia_payload")
        if not payload_s:
            checks.append(Check(p + "gpu", "NVIDIA GPU attestation", Status.FAIL, "no GPU evidence in the model report"))
        else:
            try:
                payload = json.loads(payload_s) if isinstance(payload_s, str) else payload_s
                if str(payload.get("nonce", "")).lower() != nonce.lower():
                    checks.append(Check(p + "gpu", "NVIDIA GPU attestation", Status.FAIL, "GPU evidence is for a different nonce"))
                elif gpu_verifier is None:
                    checks.append(Check(p + "gpu", "NVIDIA GPU attestation", Status.SKIP, "GPU verifier disabled"))
                else:
                    g = gpu_verifier.verify(payload)
                    checks.append(Check(p + "gpu", "NVIDIA GPU attestation", Status.PASS if g.ok else Status.FAIL, g.detail))
            except Exception as e:
                checks.append(Check(p + "gpu", "NVIDIA GPU attestation", Status.SKIP, f"NRAS unreachable: {e}"))

    # 8. Compose manager (model only, when present): the log of what was deployed in this TD.
    cm = report.get("compose_manager_attestation") if role == "model" else None
    if cm:
        checks.append(_verify_compose_manager(cm, nonce, fields, quote_verifier))

    quote_ok = checks[0].status in (Status.PASS, Status.WARN)
    if quote_ok and signer_ok and nonce_ok and not fields.debug:
        bound = addr.lower()
    return checks, bound


def _verify_compose_manager(cm: dict[str, Any], nonce: str, model_fields: tdx.TdQuoteFields,
                            quote_verifier: QuoteVerifier) -> Check:
    label = "Model deployment log"
    try:
        raw = bytes.fromhex(cm.get("quote") or "")
        f = tdx.parse_td_quote(raw)
        qr = quote_verifier.verify(raw)
    except Exception as e:
        return Check("model.deploy", label, Status.FAIL, f"deployment log quote invalid: {e}")
    if qr.status not in TCB_PASS | TCB_WARN:
        return Check("model.deploy", label, Status.FAIL, f"deployment log quote TCB {qr.status}")
    if (f.mr_td, f.rtmr) != (model_fields.mr_td, model_fields.rtmr):
        return Check("model.deploy", label, Status.FAIL, "deployment log comes from a different enclave")
    actions = cm.get("actions") or []
    h = tdx.actions_hash(actions)
    if f.report_data.hex() != h + nonce.lower():
        return Check("model.deploy", label, Status.FAIL, "deployment log hash or nonce not in its quote")
    ups = [a for a in actions if a.get("action") == "compose_up"]
    last = ups[-1] if ups else {}
    where = f"{last.get('file', '?')} @ {str(last.get('commit', '?'))[:8]}" if last else "no deployments"
    return Check("model.deploy", label, Status.PASS, f"{len(actions)} signed actions, last deploy {where}")


def verify_attestation(
    response: dict[str, Any],
    nonce: str,
    model: str,
    quote_verifier: QuoteVerifier,
    gpu_verifier: GpuVerifier | None,
) -> Verification:
    """Verify a full /v1/attestation/report response for `model`."""
    checks: list[Check] = []
    gw = response.get("gateway_attestation")
    gw_addr = None
    if gw:
        c, gw_addr = verify_report(gw, nonce, "gateway", quote_verifier, None)
        checks += c
    else:
        checks.append(Check("gateway.quote", "Gateway Intel TDX quote", Status.FAIL, "no gateway attestation"))

    candidates = [m for m in response.get("model_attestations") or [] if m.get("model_name", model) == model]
    model_addr = None
    images: list[str] = []
    if not candidates:
        checks.append(Check("model.quote", "Model Intel TDX quote", Status.FAIL,
                            f"no model attestation for {model}: it may not run in a NEAR TEE"))
    else:
        verified: list[tuple[list[Check], str]] = []
        first: list[Check] | None = None
        for cand in candidates:
            c, addr = verify_report(cand, nonce, "model", quote_verifier, gpu_verifier)
            first = first or c
            if addr and not any(x.status is Status.FAIL for x in c):
                verified.append((c, addr))
                images = tdx.compose_images(((cand.get("info") or {}).get("tcb_info") or {}).get("app_compose", ""))
        if len(verified) == 1:
            checks += verified[0][0]
            model_addr = verified[0][1]
        elif not verified:
            checks += first or []
        else:
            checks += verified[0][0]
            addrs = {a for _, a in verified}
            if len(addrs) == 1:
                model_addr = verified[0][1]
            else:
                checks.append(Check("model.unique", "One model signer", Status.FAIL,
                                    f"{len(addrs)} different verified model signers; cannot tell which signed"))

    return Verification(
        verdict=compute_verdict(checks, None, need_signature=False),
        checks=checks,
        model=model,
        nonce=nonce,
        gateway_signing_address=gw_addr,
        model_signing_address=model_addr,
        images=images,
    )


# --- response signatures ----------------------------------------------------------------------


def recover_ecdsa(text: str, signature: str) -> str:
    from eth_account import Account
    from eth_account.messages import encode_defunct

    return Account.recover_message(encode_defunct(text=text), signature=signature).lower()


def verify_signature(
    sig: dict[str, Any] | None,
    model: str,
    request_bytes: bytes,
    response_bytes: bytes,
    attestation: Verification,
) -> tuple[list[Check], str | None]:
    """Check a /v1/signature response against the exact bytes we sent and received
    and against the signers proven by the preflight attestation."""
    if not sig or "signature" not in sig or sig.get("error_code"):
        why = (sig or {}).get("message") or "signature not available"
        return [Check("signature.available", "Response signature", Status.SKIP, why)], None

    kind = sig.get("signature_kind") or "provider_tee"
    req_h = hashlib.sha256(request_bytes).hexdigest()
    resp_h = hashlib.sha256(response_bytes).hexdigest()
    expected = f"{model}:{req_h}:{resp_h}" if kind == "provider_tee" else f"{req_h}:{resp_h}"
    checks = []

    text_ok = sig.get("text") == expected
    checks.append(Check("signature.hashes", "Signed text matches our bytes", Status.PASS if text_ok else Status.FAIL,
                        "signature covers the exact request we sent and reply we got" if text_ok else "signed hashes differ from our request/response"))

    algo = sig.get("signing_algo", "ecdsa")
    claimed = str(sig.get("signing_address", "")).lower()
    if algo != "ecdsa":
        checks.append(Check("signature.valid", "Signature valid", Status.SKIP, f"{algo} signatures not supported here"))
        return checks, kind
    try:
        recovered = recover_ecdsa(sig["text"], sig["signature"])
        sig_ok = recovered == claimed
        checks.append(Check("signature.valid", "Signature valid", Status.PASS if sig_ok else Status.FAIL,
                            f"recovers to {recovered}" if sig_ok else f"recovers to {recovered}, not {claimed}"))
    except Exception as e:
        checks.append(Check("signature.valid", "Signature valid", Status.FAIL, f"bad signature: {e}"))

    attested = attestation.model_signing_address if kind == "provider_tee" else attestation.gateway_signing_address
    where = "model enclave" if kind == "provider_tee" else "gateway enclave"
    bound_ok = attested is not None and claimed == attested
    checks.append(Check("signature.bound", f"Signer is the attested {where}", Status.PASS if bound_ok else Status.FAIL,
                        f"{claimed} was attested before the request" if bound_ok else f"{claimed} was not attested before the request"))
    return checks, kind


def combine(attestation: Verification, sig_checks: list[Check], kind: str | None) -> Verification:
    checks = attestation.checks + sig_checks
    return Verification(
        verdict=compute_verdict(checks, kind, need_signature=True),
        checks=checks,
        model=attestation.model,
        nonce=attestation.nonce,
        gateway_signing_address=attestation.gateway_signing_address,
        model_signing_address=attestation.model_signing_address,
        signature_kind=kind,
        images=attestation.images,
        verified_at=time.time(),
    )


def verification_from_dict(d: dict[str, Any]) -> Verification:
    return Verification(
        verdict=Verdict(d["verdict"]),
        checks=[Check(c["id"], c["label"], Status(c["status"]), c.get("detail", "")) for c in d["checks"]],
        model=d["model"],
        nonce=d["nonce"],
        gateway_signing_address=d.get("gateway_signing_address"),
        model_signing_address=d.get("model_signing_address"),
        signature_kind=d.get("signature_kind"),
        images=d.get("images", []),
        verified_at=d.get("verified_at", 0.0),
    )
