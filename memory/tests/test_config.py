

def test_data_dir_per_platform(monkeypatch, tmp_path):
    import pixl_memory.config as c
    monkeypatch.delenv("PIXL_MEMORY_DIR", raising=False)
    monkeypatch.setattr(c.sys, "platform", "darwin")
    assert c.default_data_dir().parts[-3:] == ("Library", "Application Support", "PixlMemory")
    monkeypatch.setattr(c.sys, "platform", "win32")
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "Local"))
    assert c.default_data_dir() == tmp_path / "Local" / "PixlMemory"     # where the Windows app looks for the token
    monkeypatch.setattr(c.sys, "platform", "linux")
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "share"))
    assert c.default_data_dir() == tmp_path / "share" / "pixl-memory"
    monkeypatch.setenv("PIXL_MEMORY_DIR", str(tmp_path / "x"))
    assert c.default_data_dir() == tmp_path / "x"
