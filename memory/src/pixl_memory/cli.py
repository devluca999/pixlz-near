"""pixl-memory command line: serve, attest, polish, token, models."""

from __future__ import annotations

import argparse
import json
import sys

from . import polish
from .config import Config
from .nearai import AttestationFailed, NearAIClient, NearAIError
from .verify import Status, Verification

MARK = {Status.PASS: "✔", Status.WARN: "!", Status.FAIL: "✖", Status.SKIP: "–"}


def print_verification(v: Verification) -> None:
    d = v.to_dict()
    print(f"\n{d['verdict'].upper()}: {d['summary']}\n")
    for c in v.checks:
        print(f"  {MARK[c.status]} {c.label:<34} {c.detail}")
    if v.model_signing_address:
        print(f"\n  model signer   {v.model_signing_address}")
    if v.gateway_signing_address:
        print(f"  gateway signer {v.gateway_signing_address}")
    for img in v.images:
        print(f"  image          {img}")
    print()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pixl-memory", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="run the local API on 127.0.0.1")
    s.add_argument("--port", type=int)
    a = sub.add_parser("attest", help="verify the NEAR AI TEE for a model (no API key needed)")
    a.add_argument("--model")
    a.add_argument("--json", action="store_true")
    p = sub.add_parser("polish", help="polish text through a verified TEE (needs NEAR_AI_API_KEY in .env)")
    p.add_argument("text", nargs="?", help="text to polish (default: stdin)")
    p.add_argument("-i", "--instruction")
    p.add_argument("--model")
    p.add_argument("--json", action="store_true")
    sub.add_parser("token", help="print the token clients use to call the local API")
    sub.add_parser("models", help="list models served from NEAR AI's own TEEs")
    args = ap.parse_args(argv)

    cfg = Config.from_env()
    if args.cmd == "token":
        print(cfg.token())
        return 0

    client = NearAIClient(cfg.api_key, cfg.base_url)
    try:
        if args.cmd == "models":
            for m in client.private_models():
                print(("* " if m == cfg.model else "  ") + m)
            return 0

        if args.cmd == "attest":
            model = args.model or cfg.model
            client.require_private(model)
            v = client.attest(model)
            if args.json:
                print(json.dumps(v.to_dict(), indent=2))
            else:
                print(f"Attesting {model} on {cfg.base_url} …")
                print_verification(v)
            return 0 if v.attestation_ok else 1

        if args.cmd == "polish":
            text = args.text if args.text is not None else sys.stdin.read()
            model = args.model or cfg.model
            try:
                comp = client.chat(polish.messages(text, args.instruction), model, temperature=0.3, max_tokens=4096)
            except AttestationFailed as e:
                print("Refused: the enclave failed verification, so your text was not sent.", file=sys.stderr)
                print_verification(e.verification)
                return 2
            out = polish.clean(comp.content, text)
            if args.json:
                print(json.dumps({"suggestion": out, "diff": polish.word_diff(text, out),
                                  "verification": comp.verification.to_dict()}, indent=2))
            else:
                print(out)
                print_verification(comp.verification)
            return 0

        if args.cmd == "serve":
            import uvicorn

            from .server import create_app
            from .store import Store

            token = cfg.token()
            app = create_app(Store(cfg.data_dir), client, token, cfg.model)
            print(f"Pixl Memory on http://{cfg.host}:{args.port or cfg.port}  data: {cfg.data_dir}")
            print(f"API key: {'set' if cfg.api_key else 'NOT SET (polish disabled; attest works)'}")
            uvicorn.run(app, host=cfg.host, port=args.port or cfg.port, log_level="warning")
            return 0
    except NearAIError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
