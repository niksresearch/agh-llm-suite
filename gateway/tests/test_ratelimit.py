from ratelimit import RateLimiter


def test_allows_up_to_capacity_then_blocks():
    t = [1000.0]
    rl = RateLimiter(rpm=3, now=lambda: t[0])
    assert rl.allow("k") is True
    assert rl.allow("k") is True
    assert rl.allow("k") is True
    assert rl.allow("k") is False  # bucket empty, no time passed


def test_refills_over_time():
    t = [1000.0]
    rl = RateLimiter(rpm=60, now=lambda: t[0])  # 1 token/sec, cap 60
    for _ in range(60):
        assert rl.allow("k") is True
    assert rl.allow("k") is False
    t[0] += 2.0  # 2 seconds -> ~2 tokens refilled
    assert rl.allow("k") is True
    assert rl.allow("k") is True
    assert rl.allow("k") is False


def test_keys_are_independent():
    t = [1000.0]
    rl = RateLimiter(rpm=1, now=lambda: t[0])
    assert rl.allow("a") is True
    assert rl.allow("a") is False
    assert rl.allow("b") is True  # separate bucket
