"""The local page where the owner sends testnet NEAR from their own account: to a friend, or to
top up one of their Pixls.

It asks the owner's wallet (Meteor) to sign ONE transaction from the owner's account with ONE
action, Transfer(amount), to the recipient they typed. The owner's keys never reach this Mac:
Meteor signs in its own popup. Pixl Memory adds nothing to the transaction and holds no key for it.
"""

from __future__ import annotations

import html
import json

from .config import WalletConfig
from .setup_page import METEOR, TX, WS

# NEAR account ids (nomicon: 2-64 chars, lowercase a-z 0-9 and _ - separated by dots), testnet only here,
# or a 64-hex implicit account.
ACCOUNT_RE = r"^(([a-z\d]+[-_])*[a-z\d]+\.)+testnet$|^[0-9a-f]{64}$"


def render(cfg: WalletConfig, pets: list[str]) -> str:
    data = json.dumps({"owner": cfg.parent, "rpc": cfg.rpc_url, "explorer": "https://testnet.nearblocks.io",
                       "pets": pets, "accountRe": ACCOUNT_RE}).replace("</", "<\\/")
    e = html.escape
    pet_buttons = "".join(f'<button class="pet" data-to="{e(p)}">Top up {e(p.split(".")[0].capitalize())}</button>' for p in pets)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Send NEAR</title>
<style>
:root {{ --ink:#1B2A1A; --paper:#FFFBF2; --accent:#7CD93A; --muted:#5d6b5c; --bad:#c92a2a; }}
* {{ box-sizing: border-box; }}
body {{ margin:0; background:var(--paper); color:var(--ink); font:15px/1.5 ui-monospace,"SF Mono",Menlo,monospace; }}
main {{ max-width:720px; margin:32px auto; padding:0 16px; }}
h1 {{ font-size:22px; }}
.card {{ border:3px solid var(--ink); background:#fff; box-shadow:6px 6px 0 var(--ink); padding:16px; margin:18px 0; }}
dt {{ color:var(--muted); font-size:12px; }} dd {{ margin:0 0 10px; word-break:break-all; }}
button {{ font:inherit; font-weight:bold; border:3px solid var(--ink); background:var(--accent); padding:8px 14px;
         box-shadow:4px 4px 0 var(--ink); cursor:pointer; margin:0 10px 10px 0; }}
button.pet {{ background:#fff; }}
button:disabled {{ background:#ddd; cursor:not-allowed; box-shadow:none; }}
input {{ font:inherit; border:3px solid var(--ink); padding:6px; width:100%; max-width:28em; }}
#amount {{ width:8em; }}
#log {{ white-space:pre-wrap; font-size:13px; }}
.bad {{ color:var(--bad); }} .muted {{ color:var(--muted); }}
</style></head>
<body><main>
<h1>Send NEAR (testnet)</h1>
<p>Send testnet NEAR from <b>your</b> account to a friend, or top up one of your Pixls. Meteor signs it in its own window: this Mac never sees your keys, and Pixl Memory can't change the recipient or the amount after you approve.</p>
<div class="card"><dl>
  <dt>From (your account, signs in Meteor)</dt><dd>{e(cfg.parent)} <span id="bal" class="muted"></span></dd>
  <dt>To (a .testnet account)</dt><dd><input id="to" placeholder="friend.testnet" autocomplete="off" spellcheck="false"> <span id="tostate" class="muted"></span></dd>
  <dt>Amount (testnet NEAR)</dt><dd><input id="amount" value="0.1" inputmode="decimal"> Ⓝ</dd>
</dl>{pet_buttons}</div>
<div class="card">
  <p><b>What Meteor will ask you to approve:</b> one transaction from <b>{e(cfg.parent)}</b> to the account above, with one action: <i>Transfer</i> of the amount above. Nothing else.</p>
  <p class="muted">Approve only the connection when connecting. If Meteor asks to add an access key for a contract, decline. Never paste your recovery phrase anywhere.</p>
  <button id="connect">1. Connect Meteor</button><button id="send" disabled>2. Send</button>
</div>
<div class="card"><div id="log">Ready.</div></div>
</main>
<script type="module">
const C = {data};
const RE = new RegExp(C.accountRe);
const $ = (id) => document.getElementById(id);
const log = (m, bad) => {{ const el = $("log"); el.textContent = m; el.className = bad ? "bad" : ""; }};
const toYocto = (s) => {{
  if (!/^\\d+(\\.\\d{{1,24}})?$/.test(s)) throw new Error("Amount must be a number like 1 or 0.5");
  const [i, f = ""] = s.split("."); const y = BigInt(i) * 10n ** 24n + BigInt((f + "0".repeat(24)).slice(0, 24));
  if (y <= 0n) throw new Error("Amount must be more than 0"); return y;
}};
const fmt = (y) => (Number(BigInt(y) / 10n ** 18n) / 1e6).toFixed(4).replace(/\\.?0+$/, "");
async function view(account) {{
  const r = await fetch(C.rpc, {{ method: "POST", headers: {{ "content-type": "application/json" }},
    body: JSON.stringify({{ jsonrpc: "2.0", id: 1, method: "query", params: {{ request_type: "view_account", finality: "final", account_id: account }} }}) }});
  const j = await r.json(); return j.result ? j.result.amount : null;
}}
view(C.owner).then((b) => $("bal").textContent = b === null ? "(not found)" : `· ${{fmt(b)}} Ⓝ`).catch(() => {{}});
const checkTo = async () => {{
  const to = $("to").value.trim();
  if (!to) {{ $("tostate").textContent = ""; return null; }}
  if (!RE.test(to)) {{ $("tostate").textContent = "· not a testnet account id"; return null; }}
  if (to === C.owner) {{ $("tostate").textContent = "· that's you"; return null; }}
  const b = await view(to).catch(() => null);
  $("tostate").textContent = b === null ? "· doesn't exist on testnet (NEAR would refuse)" : `· exists, ${{fmt(b)}} Ⓝ`;
  return b === null ? null : to;
}};
$("to").addEventListener("change", checkTo);
document.querySelectorAll("button.pet").forEach((b) => b.onclick = () => {{ $("to").value = b.dataset.to; checkTo(); }});
let wallet = null;
$("connect").onclick = async () => {{
  try {{
    log("Loading Meteor…");
    const [{{ setupWalletSelector }}, {{ setupMeteorWallet }}] = await Promise.all([import("{WS}"), import("{METEOR}")]);
    const selector = await setupWalletSelector({{ network: "testnet", modules: [setupMeteorWallet()] }});
    wallet = await selector.wallet("meteor-wallet");
    log("Approve the connection in Meteor…");
    const accounts = await wallet.signIn({{ contractId: undefined, methodNames: [] }});
    const ids = accounts.map((a) => a.accountId);
    if (!ids.includes(C.owner)) {{ log(`Meteor connected ${{ids.join(", ") || "no account"}}, not ${{C.owner}}. Switch accounts in Meteor and try again.`, true); return; }}
    log(`Connected as ${{C.owner}}. Next: Send.`); $("send").disabled = false;
  }} catch (e) {{ log("Connect failed: " + (e && e.message || e), true); }}
}};
$("send").onclick = async () => {{
  try {{
    const to = await checkTo();
    if (!to) throw new Error("Enter an existing .testnet account to send to");
    const amount = toYocto($("amount").value.trim());
    const {{ actionCreators }} = await import("{TX}");
    log(`Approve in Meteor: send ${{$("amount").value}} Ⓝ from ${{C.owner}} to ${{to}}…`);
    $("send").disabled = true;
    const out = await wallet.signAndSendTransaction({{ signerId: C.owner, receiverId: to, actions: [actionCreators.transfer(amount)] }});
    const hash = out && out.transaction && out.transaction.hash;
    log(`Sent ${{$("amount").value}} Ⓝ to ${{to}}.` + (hash ? `\\nTransaction: ${{C.explorer}}/txns/${{hash}}` : ""));
    $("send").disabled = false;
    view(C.owner).then((b) => $("bal").textContent = b === null ? "" : `· ${{fmt(b)}} Ⓝ`).catch(() => {{}});
  }} catch (e) {{ $("send").disabled = false; log("Not sent: " + (e && e.message || e), true); }}
}};
</script>
</body></html>"""
