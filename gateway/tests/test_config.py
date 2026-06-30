from config import load_settings

def test_load_settings_reads_env_with_defaults():
    env = {
        "OLLAMA_URL": "http://localhost:11434",
        "MODEL": "gemma-4-31B-it-GGUF",
        "OLLAMA_NUM_CTX": "65536",
        "RATE_LIMIT_RPM": "60",
        "ADMIN_TOKEN": "admintok",
        "KEYFILE": "/data/keys.txt",
        "LLM_API_KEY": "firstkey",
        "BUNDLE": "2",
    }
    s = load_settings(env)
    assert s.ollama_url == "http://localhost:11434"
    assert s.model == "gemma-4-31B-it-GGUF"
    assert s.num_ctx == 65536
    assert s.rate_limit_rpm == 60
    assert s.admin_token == "admintok"
    assert s.keyfile == "/data/keys.txt"
    assert s.bootstrap_key == "firstkey"
    assert s.bundle == 2

def test_load_settings_defaults_when_absent():
    s = load_settings({})
    assert s.ollama_url == "http://localhost:11434"
    assert s.num_ctx == 8192
    assert s.rate_limit_rpm == 60
    assert s.keyfile == "/data/keys.txt"
    assert s.bootstrap_key == ""
    assert s.bundle == 2

def test_bundle1_disables_admin():
    s = load_settings({"BUNDLE": "1"})
    assert s.bundle == 1

def test_bundle3_enables_all():
    s = load_settings({"BUNDLE": "3"})
    assert s.bundle == 3
