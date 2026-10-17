from spatial_tools import phonelog

LOG = """2026-10-09 00-02-29.294 [Info] (Controller) Reconnecting
2026-10-09 00-02-30.298 [Info] (Connection) Connecting to host: 192.168.1.97:1704, port: 1704, protocol: tcp
2026-10-09 00-02-30.373 [Error] (Connection) Failed to connect to host '192.168.1.97', error: Connection refused
2026-10-09 00-02-30.374 [Info] (Controller) Reconnecting
2026-10-09 00-07-38.814 [Info] (Connection) Resolving host IP for: 192.168.1.97
2026-10-09 00-07-38.900 [Notice] (Connection) Connected to 192.168.1.97
2026-10-09 00-07-40.000 [Debug] (Stats) Chunk: 3\t2\t-1\t0\t500\t185.3\t0
2026-10-09 00-07-41.000 [Debug] (Stats) Chunk: -5\t2\t1\t0\t500\t185.3\t0
2026-10-09 00-32-18.541 [Info] (Stream) pMiniBuffer->full() && (abs(pMiniBuffer->mean()) > 50): 490806
2026-10-09 00-33-13.351 [Error] (Controller) Error receiving next message: asio.misc:2
""".replace("\\t", "\t")


def test_parse_events():
    lg = phonelog.parse(LOG, "node-04")
    assert len(lg.connects) == 1 and len(lg.drops) == 1
    assert lg.resyncs and abs(lg.resyncs[0][1] - 490.806) < 1e-6
    assert len(lg.stalls) == 1 and lg.stalls[0][1] > 300   # 재시도 사이 5분 = 잠듦
    assert lg.stats_age_ms == [0.3, -0.5]
    assert "node-04" in phonelog.summary([lg])


def test_since_filters():
    lg = phonelog.parse(LOG, "x", since=phonelog._time("2026-10-09 00-30-00.0"))
    assert not lg.connects and len(lg.resyncs) == 1 and not lg.stalls
