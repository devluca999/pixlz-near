"""Frogg's account names: testnet only, and Frogg is a direct sub-account of the owner."""

from pathlib import Path

import pytest

from pixl_memory.config import WalletConfig, WalletConfigError

REPO = Path(__file__).resolve().parents[2]
PARENT = "pixlz-petz.testnet"
FROGG = "frogg.pixlz-petz.testnet"


def test_example_env_names_the_owners_accounts():
    w = WalletConfig.from_env(REPO / ".env.example")
    assert (w.network, w.parent, w.frogg, w.payee) == ("testnet", PARENT, FROGG, PARENT)
    assert (w.max_per_request_near, w.max_per_day_near, w.reserve_near) == ("0.01", "0.1", "0.05")
    assert w.rpc_url == "https://rpc.testnet.near.org"
    assert w.explorer == f"https://testnet.nearblocks.io/address/{FROGG}"


@pytest.mark.parametrize("network,parent,frogg,msg", [
    ("mainnet", PARENT, FROGG, "testnet"),
    ("testnet", "sylversurferr.near", "frogg.sylversurferr.near", ".testnet"),
    ("testnet", PARENT, "frogg.luca_m.testnet", "frogg.pixlz-petz.testnet"),
    ("testnet", PARENT, "pet.frogg.pixlz-petz.testnet", "frogg.pixlz-petz.testnet"),
    ("testnet", "Sylversurferr.testnet", "frogg.Sylversurferr.testnet", "valid NEAR account"),
    ("testnet", "", FROGG, "valid NEAR account"),
])
def test_rejects_anything_but_frogg_under_the_owner_on_testnet(network, parent, frogg, msg):
    with pytest.raises(WalletConfigError, match=msg.replace(".", r"\.")):
        WalletConfig.validated(network, parent, frogg)


def test_no_wallet_settings_means_no_wallet(tmp_path):
    (tmp_path / ".env").write_text("OTHER=1\n")
    assert WalletConfig.from_env(tmp_path / ".env") is None


def test_network_defaults_to_testnet(tmp_path):
    (tmp_path / ".env").write_text(f"FROGG_PARENT_ACCOUNT={PARENT}\nFROGG_ACCOUNT={FROGG}\n")
    assert WalletConfig.from_env(tmp_path / ".env").network == "testnet"


def env(tmp_path, extra=""):
    (tmp_path / ".env").write_text(f"FROGG_PARENT_ACCOUNT={PARENT}\nFROGG_ACCOUNT={FROGG}\n{extra}")
    return tmp_path / ".env"


def test_payee_defaults_to_the_parent_and_cant_be_frogg(tmp_path):
    assert WalletConfig.from_env(env(tmp_path)).payee == PARENT
    with pytest.raises(WalletConfigError, match="Frogg itself"):
        WalletConfig.from_env(env(tmp_path, f"FROGG_PAYEE={FROGG}\n"))
    with pytest.raises(WalletConfigError, match="testnet"):
        WalletConfig.from_env(env(tmp_path, "FROGG_PAYEE=someone.near\n"))


@pytest.mark.parametrize("extra,msg", [
    ("FROGG_MAX_PER_DAY_NEAR=-1\n", "non-negative"),
    ("FROGG_MAX_PER_REQUEST_NEAR=abc\n", "non-negative"),
    ("FROGG_MAX_PER_REQUEST_NEAR=1\nFROGG_MAX_PER_DAY_NEAR=0.5\n", "can't exceed"),
    ("NEAR_RPC_URL=https://rpc.mainnet.near.org\n", "testnet endpoint"),
    ("NEAR_RPC_URL=http://rpc.testnet.near.org\n", "testnet endpoint"),
])
def test_bad_caps_and_rpc_are_rejected(tmp_path, extra, msg):
    with pytest.raises(WalletConfigError, match=msg):
        WalletConfig.from_env(env(tmp_path, extra))
