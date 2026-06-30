import os
from keystore import KeyStore


def test_mint_validate_revoke(tmp_path):
    kf = str(tmp_path / "keys.txt")
    ks = KeyStore(kf)
    ks.load()
    rec = ks.mint(label="alice")
    assert ks.is_valid(rec["secret"]) is True
    assert ks.is_valid("nope") is False
    ids = ks.list_ids()
    assert len(ids) == 1 and ids[0]["id"] == rec["id"]
    assert "secret" not in ids[0]
    assert ks.revoke(rec["id"]) is True
    assert ks.is_valid(rec["secret"]) is False
    assert ks.revoke(rec["id"]) is False


def test_persistence_across_reload(tmp_path):
    kf = str(tmp_path / "keys.txt")
    ks = KeyStore(kf)
    ks.load()
    rec = ks.mint(label="bob")
    ks2 = KeyStore(kf)
    ks2.load()
    assert ks2.is_valid(rec["secret"]) is True


def test_add_existing_seeds_known_secret(tmp_path):
    kf = str(tmp_path / "keys.txt")
    ks = KeyStore(kf)
    ks.load()
    ks.add_existing("knownsecret", label="bootstrap")
    assert ks.is_valid("knownsecret") is True
    ks.add_existing("knownsecret", label="bootstrap")
    assert len(ks.list_ids()) == 1


def test_load_missing_file_is_empty(tmp_path):
    ks = KeyStore(str(tmp_path / "absent.txt"))
    ks.load()
    assert ks.list_ids() == []


def test_revoke_persists_across_reload(tmp_path):
    kf = str(tmp_path / "keys.txt")
    ks = KeyStore(kf); ks.load()
    rec = ks.mint(label="dave")
    assert ks.revoke(rec["id"]) is True
    ks2 = KeyStore(kf); ks2.load()
    assert ks2.is_valid(rec["secret"]) is False
    assert ks2.list_ids() == []


def test_load_tolerates_malformed_lines(tmp_path):
    kf = str(tmp_path / "keys.txt")
    with open(kf, "w", encoding="utf-8") as fh:
        fh.write("k_aaaa:sk-good:alice:2026-01-01T00:00:00+00:00\n")  # valid (split with maxsplit=3 keeps time colons in 'created')
        fh.write("garbage-no-colons\n")
        fh.write("only:two\n")
        fh.write("\n")
    ks = KeyStore(kf); ks.load()
    ids = ks.list_ids()
    assert len(ids) == 1
    assert ids[0]["id"] == "k_aaaa"
    assert ks.is_valid("sk-good") is True
