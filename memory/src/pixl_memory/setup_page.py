"""The local page where the owner approves Frogg's account in Meteor.

It asks the owner's wallet to sign ONE transaction from the owner's account:
  receiver frogg.<owner>.testnet, actions [CreateAccount, Transfer(amount), AddKey(Frogg's public key, FullAccess)].
The page never sees the owner's keys or recovery phrase: Meteor signs in its own popup.
"""

from __future__ import annotations

import html
import json

from .config import WalletConfig

# Versions pinned: wallet-selector 10.1.4 needs @near-js/* ^2.3; Meteor's SDK 1.0.24 needs near-api-js ^6.
WS = "https://esm.sh/@near-wallet-selector/core@10.1.4"
METEOR = "https://esm.sh/@near-wallet-selector/meteor-wallet@10.1.4?deps=near-api-js@6.5.1"
TX = "https://esm.sh/@near-js/transactions@2.5.1"
CRYPTO = "https://esm.sh/@near-js/crypto@2.5.1"


def render(cfg: WalletConfig, public_key: str | None, amount_near: str = "1") -> str:
    data = json.dumps({"parent": cfg.parent, "frogg": cfg.frogg, "publicKey": public_key, "rpc": cfg.rpc_url,
                       "amount": amount_near, "explorer": "https://testnet.nearblocks.io"}).replace("</", "<\\/")
    e = html.escape
    key_html = (f"<code>{e(public_key)}</code>" if public_key else
                "<b>Not created yet.</b> Run <code>cd memory &amp;&amp; uv run pixl-memory wallet init</code>, then reload.")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Create Frogg's wallet</title>
<style>
:root {{ --ink:#1B2A1A; --paper:#FFFBF2; --accent:#7CD93A; --muted:#5d6b5c; --bad:#c92a2a; }}
* {{ box-sizing: border-box; }}
body {{ margin:0; background:var(--paper); color:var(--ink); font:15px/1.5 ui-monospace,"SF Mono",Menlo,monospace; }}
main {{ max-width:720px; margin:32px auto; padding:0 16px; }}
h1 {{ font-size:22px; }}
.card {{ border:3px solid var(--ink); background:#fff; box-shadow:6px 6px 0 var(--ink); padding:16px; margin:18px 0; }}
dt {{ color:var(--muted); font-size:12px; }} dd {{ margin:0 0 10px; word-break:break-all; }}
ol li {{ margin:6px 0; }}
button {{ font:inherit; font-weight:bold; border:3px solid var(--ink); background:var(--accent); padding:8px 14px;
         box-shadow:4px 4px 0 var(--ink); cursor:pointer; margin-right:10px; }}
button:disabled {{ background:#ddd; cursor:not-allowed; box-shadow:none; }}
input {{ font:inherit; border:3px solid var(--ink); padding:6px; width:7em; }}
#log {{ white-space:pre-wrap; font-size:13px; }}
.bad {{ color:var(--bad); }} .muted {{ color:var(--muted); }}
</style></head>
<body><main>
<h1>Create Frogg's wallet (testnet)</h1>
<p>Frogg gets its own account under yours and pays for its private inference from the amount you give it. That amount is the most it can ever spend; nothing on this Mac can touch your account.</p>
<div class="card"><dl>
  <dt>Your account (signs once, in Meteor)</dt><dd id="parent">{e(cfg.parent)} <span id="pbal" class="muted"></span></dd>
  <dt>Frogg's account (created by this transaction)</dt><dd>{e(cfg.frogg)} <span id="fstate" class="muted"></span></dd>
  <dt>Frogg's public key (its private half stays on this Mac)</dt><dd>{key_html}</dd>
  <dt>Amount to give Frogg (testnet NEAR)</dt><dd><input id="amount" value="{e(amount_near)}" inputmode="decimal"> Ⓝ</dd>
</dl></div>
<div class="card">
  <p><b>What Meteor will ask you to approve:</b> one transaction from <b>{e(cfg.parent)}</b> to <b>{e(cfg.frogg)}</b> with three actions:
  <i>Create account</i>, <i>Transfer</i> (the amount above), <i>Add key</i> (the public key above, full access to Frogg's account only).</p>
  <p class="muted">When connecting, approve only the connection. If Meteor asks to add an access key for a contract, decline. Never paste your recovery phrase anywhere.</p>
  <button id="connect">1. Connect Meteor</button><button id="create" disabled>2. Create Frogg</button>
</div>
<div class="card"><div id="log">Ready.</div></div>
</main>
<script type="module">
const C = {data};
const log = (m, bad) => {{ const el = document.getElementById("log"); el.textContent = m; el.className = bad ? "bad" : ""; }};
const $ = (id) => document.getElementById(id);
const toYocto = (s) => {{
  if (!/^\\d+(\\.\\d{{1,24}})?$/.test(s)) throw new Error("Amount must be a number like 1 or 0.5");
  const [i, f = ""] = s.split("."); return BigInt(i) * 10n ** 24n + BigInt((f + "0".repeat(24)).slice(0, 24));
}};
const fmt = (y) => (Number(BigInt(y) / 10n ** 18n) / 1e6).toFixed(4).replace(/\\.?0+$/, "");
async function view(account) {{
  const r = await fetch(C.rpc, {{ method: "POST", headers: {{ "content-type": "application/json" }},
    body: JSON.stringify({{ jsonrpc: "2.0", id: 1, method: "query", params: {{ request_type: "view_account", finality: "final", account_id: account }} }}) }});
  const j = await r.json(); return j.result ? j.result.amount : null;
}}
async function refresh() {{
  const p = await view(C.parent); $("pbal").textContent = p === null ? "(not found)" : `· ${{fmt(p)}} Ⓝ`;
  const f = await view(C.frogg); $("fstate").textContent = f === null ? "· doesn't exist yet" : `· exists, ${{fmt(f)}} Ⓝ`;
  return {{ p, f }};
}}
let wallet = null;
const state = await refresh().catch(() => ({{}}));
if (!C.publicKey) {{ $("connect").disabled = true; log("Create Frogg's key first (see above)."); }}
else if (state.f !== null && state.f !== undefined) {{ $("connect").disabled = true; log("Frogg's account already exists. Nothing to do here."); }}
else if (state.p !== undefined && state.p !== null && BigInt(state.p) < 10n ** 24n) {{
  log("Your account has less than 1 testnet NEAR. Get some from the faucet first: https://docs.near.org/getting-started/faucet", true);
}}
$("connect").onclick = async () => {{
  try {{
    log("Loading Meteor…");
    const [{{ setupWalletSelector }}, {{ setupMeteorWallet }}] = await Promise.all([import("{WS}"), import("{METEOR}")]);
    const selector = await setupWalletSelector({{ network: "testnet", modules: [setupMeteorWallet()] }});
    wallet = await selector.wallet("meteor-wallet");
    log("Approve the connection in Meteor…");
    const accounts = await wallet.signIn({{ contractId: undefined, methodNames: [] }});
    const ids = accounts.map((a) => a.accountId);
    if (!ids.includes(C.parent)) {{ log(`Meteor connected ${{ids.join(", ") || "no account"}}, not ${{C.parent}}. Switch accounts in Meteor and try again.`, true); return; }}
    log(`Connected as ${{C.parent}}. Next: Create Frogg.`); $("create").disabled = false;
  }} catch (e) {{ log("Connect failed: " + (e && e.message || e), true); }}
}};
$("create").onclick = async () => {{
  try {{
    const amount = toYocto($("amount").value.trim());
    const [{{ actionCreators }}, {{ PublicKey }}] = await Promise.all([import("{TX}"), import("{CRYPTO}")]);
    const actions = [actionCreators.createAccount(), actionCreators.transfer(amount),
                     actionCreators.addKey(PublicKey.fromString(C.publicKey), actionCreators.fullAccessKey())];
    log("Approve in Meteor: create " + C.frogg + ", send " + $("amount").value + " Ⓝ, add Frogg's key…");
    $("create").disabled = true;
    const out = await wallet.signAndSendTransaction({{ signerId: C.parent, receiverId: C.frogg, actions }});
    const hash = out && out.transaction && out.transaction.hash;
    log("Done. Frogg's account is created." + (hash ? `\\nTransaction: ${{C.explorer}}/txns/${{hash}}` : "") +
        "\\nBack in the terminal: uv run pixl-memory wallet status");
    await refresh();
  }} catch (e) {{ $("create").disabled = false; log("Not created: " + (e && e.message || e), true); }}
}};
</script>
</body></html>"""
