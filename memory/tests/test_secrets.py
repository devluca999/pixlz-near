"""Keys come only from .env, and nothing secret is tracked: this repo goes public."""

import subprocess
from pathlib import Path

from pixl_memory.config import SECRET_NAMES, WALLET_SETTINGS, Config, find_env_file, read_secret

REPO = Path(__file__).resolve().parents[2]
NAME = "NEAR_AI_API_KEY"
OTHER = "AGENT_CONNECT_API_KEY"
FROM_SHELL = "sk-" + "shell"  # short fakes, assembled so the secret scan ignores this file
FROM_DOTENV = "sk-" + "dotenv"


def test_key_read_only_from_env_file(tmp_path, monkeypatch):
    monkeypatch.setenv(NAME, FROM_SHELL)
    (tmp_path / ".git").mkdir()
    (tmp_path / ".env").write_text(f"{NAME}={FROM_DOTENV}\n{OTHER}=\n")
    assert find_env_file(tmp_path) == tmp_path / ".env"
    assert read_secret(NAME, tmp_path / ".env") == FROM_DOTENV
    assert read_secret(OTHER, tmp_path / ".env") is None
    cfg = Config.from_env(tmp_path / ".env")
    assert cfg.api_key == FROM_DOTENV
    assert "sk-" not in repr(cfg)


def test_process_env_alone_gives_no_key(tmp_path, monkeypatch):
    monkeypatch.setenv(NAME, FROM_SHELL)
    (tmp_path / ".env").write_text("OTHER=1\n")
    assert read_secret("NEAR_AI_API_KEY", tmp_path / ".env") is None


def test_env_files_are_ignored_and_template_is_empty():
    ignored = subprocess.run(["git", "check-ignore", ".env", ".env.local", "memory/.env"], cwd=REPO,
                             capture_output=True, text=True).stdout.split()
    assert ignored == [".env", ".env.local", "memory/.env"]
    assert subprocess.run(["git", "check-ignore", "-q", ".env.example"], cwd=REPO).returncode == 1
    names = []
    for line in (REPO / ".env.example").read_text().splitlines():
        if line and not line.startswith("#"):
            name, _, value = line.partition("=")
            names.append(name)
            if name in SECRET_NAMES:
                assert value == "", f"{name} must be empty in .env.example"
            else:
                assert name in WALLET_SETTINGS, f"unexpected setting {name} in .env.example"
    assert set(SECRET_NAMES) <= set(names)


def test_no_secrets_in_tracked_files():
    r = subprocess.run([str(REPO / "scripts" / "check-secrets.sh"), "--all"], cwd=REPO, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_scanner_blocks_a_staged_key_and_env_file(tmp_path):
    git = lambda *a: subprocess.run(["git", *a], cwd=tmp_path, capture_output=True, text=True)  # noqa: E731
    git("init", "-q")
    (tmp_path / "scripts").mkdir()
    script = tmp_path / "scripts" / "check-secrets.sh"
    script.write_text((REPO / "scripts" / "check-secrets.sh").read_text())
    script.chmod(0o755)
    fake = "sk-" + "a1B2" * 8  # assembled so this file doesn't match the pattern itself
    (tmp_path / "config.py").write_text(f'KEY = "{fake}"\n')
    git("add", "config.py")
    r = subprocess.run([str(script)], cwd=tmp_path, capture_output=True, text=True)
    assert r.returncode == 1 and "config.py" in r.stdout and fake not in r.stdout
    git("rm", "-q", "--cached", "config.py")
    (tmp_path / ".env").write_text("X=1\n")
    git("add", "-f", ".env")
    r = subprocess.run([str(script)], cwd=tmp_path, capture_output=True, text=True)
    assert r.returncode == 1 and "env file" in r.stdout
