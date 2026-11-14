# pixl-allowance (prototype, not deployed)

An on-chain allowance for a Pixl: the contract account holds the Pixl's funds, and the Mac's only key
for it would be a function-call key limited to `pay`. The contract then enforces what the app today
enforces in code: one payee set by the owner, a per-payment cap, a daily cap (UTC day), a pause switch,
and a storage reserve. Only the owner (a separate account, signing in their own wallet) can change the
limits or payee, pause, or withdraw.

**Status:** written and unit-tested (7 tests, `cargo test`); builds to wasm (`cargo near build non-reproducible-wasm`, ~116 KB).
It is **not deployed** and **not wired into Pixl Memory**. The shipped wallet still uses the app-level caps
described in [docs/SECURITY-MODEL.md](../../docs/SECURITY-MODEL.md). Deploying it needs a new testnet
account funded by the owner, a full-access key removed after deploy, and the pet's pay path switched to a
`FunctionCall(pay)`; none of that has been done.
