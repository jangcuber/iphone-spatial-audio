"""폰별 음량 보정: 합성 녹음에서 폰별 크기 차이를 되찾는지."""
import numpy as np

from spatial_tools import levels, signals

RATE = 48_000


def test_levels_recover_gain_differences():
    names = signals.CHANNEL_NAMES_7
    active = ["FL", "FR", "C", "SL"]
    audio, bursts, period = levels.make_cycle(names, active, RATE)
    true_db = {"FL": 0.0, "FR": 4.0, "C": -3.0, "SL": 1.5}
    mono = sum(audio[:, names.index(n)] * 10 ** (g / 20) for n, g in true_db.items())
    loop = np.tile(mono, 4)
    rng = np.random.default_rng(3)
    start = int(3.7 * RATE)                               # 녹음이 주기 중간에서 시작
    rec = loop[start:start + int(period * 3 * RATE)] * 0.3 + rng.normal(0, 3e-4, int(period * 3 * RATE))
    r = levels.analyze(rec, RATE, bursts, period)
    assert r["cycles"] >= 2
    for lv in (-26.0, -16.0):
        got = {n: r["levels"][n][lv] - r["levels"]["FL"][lv] for n in active}
        for n in active:
            assert abs(got[n] - true_db[n]) < 0.3, (lv, n, got)
    for n in active:   # 두 단계 크기 차이 10 dB가 그대로
        assert abs(r["levels"][n][-16.0] - r["levels"][n][-26.0] - 10) < 0.5
    g = levels.gains_from(r["levels"], -16.0)
    assert max(g.values()) == 0 and abs(g["FR"] - (-7.0)) < 0.4 and g["C"] == 0
