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
        print(f"  {MARK[c.status]} {c.label:<38} {c.detail}")
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
    w = sub.add_parser("wallet", help="Frogg's testnet wallet: init | status | payments")
    w.add_argument("action", choices=["init", "status", "payments"])
    sub.add_parser("token", help="print the token clients use to call the local API")
    sub.add_parser("models", help="list models served from NEAR AI's own TEEs")
    args = ap.parse_args(argv)

    cfg = Config.from_env()
    if args.cmd == "token":
        print(cfg.token())
        return 0

    if args.cmd == "wallet":
        return wallet_cmd(cfg, args.action)

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
            store = Store(cfg.data_dir)
            wallet = make_wallet(cfg, store)
            app = create_app(store, client, token, cfg.model, wallet)
            if wallet:
                print(f"Frogg's wallet: {wallet.cfg.frogg} → pays {wallet.policy.payee} (testnet)")
            print(f"Pixl Memory on http://{cfg.host}:{args.port or cfg.port}  data: {cfg.data_dir}")
            print(f"API key: {'set' if cfg.api_key else 'NOT SET (polish disabled; attest works)'}")
            uvicorn.run(app, host=cfg.host, port=args.port or cfg.port, log_level="warning")
            return 0
    except NearAIError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


def make_wallet(cfg: Config, store):
    from .config import WalletConfig
    from .wallet import Wallet

    w = WalletConfig.from_env()
    return Wallet(w, cfg.data_dir, store) if w else None


def wallet_cmd(cfg: Config, action: str) -> int:
    from .config import WalletConfigError
    from .store import Store

    try:
        wallet = make_wallet(cfg, Store(cfg.data_dir))
    except WalletConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if wallet is None:
        print("Set FROGG_PARENT_ACCOUNT and FROGG_ACCOUNT in .env (see .env.example).", file=sys.stderr)
        return 1
    if action == "init":
        existed = wallet.key() is not None
        key = wallet.init_key()
        print(f"{'Frogg already has a key' if existed else 'Created Frogg’s key'} (private half: {wallet.key_path}, mode 0600)")
        print(f"\n  Frogg's account  {wallet.cfg.frogg}\n  public key       {key.public_key}\n")
        print("Next, with the service running (make -C memory serve), open:\n")
        print(f"  http://127.0.0.1:{cfg.port}/wallet/setup\n")
        print(f"and approve one transaction from {wallet.cfg.parent} in Meteor.")
        return 0
    if action == "status":
        s = wallet.status()
        for k in ["network", "account", "parent", "payee", "public_key", "balance_near", "spendable_near",
                  "spent_today_near", "caps", "explorer", "setup"]:
            if s.get(k) is not None:
                print(f"  {k:<17} {s[k]}")
        print("\n  READY: Frogg pays for its own inference." if s["ready"] else "\n  not ready yet")
        return 0 if s["ready"] else 1
    for p in wallet.store.list_payments(20):
        print(f"  {p['status']:<8} {p.get('amount_near', '?'):>10} Ⓝ  {p.get('explorer') or p.get('reason', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
