"""Frogg's account names: testnet only, and Frogg is a direct sub-account of the owner."""

from pathlib import Path

import pytest

from pixl_memory.config import WalletConfig, WalletConfigError

REPO = Path(__file__).resolve().parents[2]
PARENT = "sylversurferr.testnet"
FROGG = "frogg.sylversurferr.testnet"


def test_example_env_names_the_owners_accounts():
    w = WalletConfig.from_env(REPO / ".env.example")
    assert w == WalletConfig("testnet", PARENT, FROGG)
    assert w.explorer == f"https://testnet.nearblocks.io/address/{FROGG}"


@pytest.mark.parametrize("network,parent,frogg,msg", [
    ("mainnet", PARENT, FROGG, "testnet"),
    ("testnet", "sylversurferr.near", "frogg.sylversurferr.near", ".testnet"),
    ("testnet", PARENT, "frogg.luca_m.testnet", "frogg.sylversurferr.testnet"),
    ("testnet", PARENT, "pet.frogg.sylversurferr.testnet", "frogg.sylversurferr.testnet"),
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
