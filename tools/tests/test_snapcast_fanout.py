"""Snapcast JSON-RPC 클라이언트와 FIFO fan-out을 가짜 서버/파이프로 확인한다."""
import json
import os
import socket
import threading

import numpy as np
import pytest

from spatial_tools import fanout
from spatial_tools.snapcast_rpc import SnapcastRPC, assign_streams, solo_rotation


class FakeSnapserver:
    """Server.GetStatus / Client.SetVolume / Group.SetClients / Group.SetStream 만 흉내낸다."""

    def __init__(self, names):
        self.groups = [{"id": "g0", "stream_id": "default",
                        "clients": [{"id": f"id-{n}", "connected": True, "host": {"name": f"host-{n}"},
                                     "config": {"name": n, "latency": 0, "volume": {"muted": False, "percent": 80}}}
                                    for n in names]}]
        self.streams = [{"id": "default", "status": "idle"}, {"id": "chL"}, {"id": "chR"}]
        self.log = []
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(1)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _client(self, cid):
        for g in self.groups:
            for c in g["clients"]:
                if c["id"] == cid:
                    return c, g
        raise KeyError(cid)

    def _serve(self):
        conn, _ = self.srv.accept()
        f = conn.makefile("rwb")
        for line in f:
            req = json.loads(line)
            m, p = req["method"], req.get("params", {})
            self.log.append((m, p))
            if m == "Server.GetStatus":
                res = {"server": {"groups": self.groups, "streams": self.streams}}
            elif m == "Client.SetVolume":
                c, _ = self._client(p["id"])
                c["config"]["volume"].update(p["volume"])
                res = {"volume": c["config"]["volume"]}
            elif m == "Group.SetClients":
                g = next(g for g in self.groups if g["id"] == p["id"])
                removed = [c for c in g["clients"] if c["id"] not in p["clients"]]
                g["clients"] = [c for c in g["clients"] if c["id"] in p["clients"]]
                for c in removed:
                    self.groups.append({"id": f"g{len(self.groups)}", "stream_id": g["stream_id"], "clients": [c]})
                res = {}
            elif m == "Group.SetStream":
                next(g for g in self.groups if g["id"] == p["id"])["stream_id"] = p["stream_id"]
                res = {}
            else:
                res = {}
            # 실제 서버처럼 알림을 응답 앞에 섞어 보낸다
            f.write(b'{"jsonrpc":"2.0","method":"Server.OnUpdate","params":{}}\r\n')
            f.write((json.dumps({"id": req["id"], "jsonrpc": "2.0", "result": res}) + "\r\n").encode())
            f.flush()


def test_solo_rotation_order_and_restore():
    srv = FakeSnapserver(["P1", "P2"])
    with SnapcastRPC("127.0.0.1", srv.port) as rpc:
        slept = []
        solo_rotation(rpc, ["P1", "P2"], solo=20, gap=3, cycles=2, sleep=slept.append, step=5)
        clients = {c.name: c for c in rpc.clients()}
    vols = [(p["id"], p["volume"]["muted"]) for m, p in srv.log if m == "Client.SetVolume"]
    # 전체 mute → P1 on/off → P2 on/off (×2) → 원래 상태(unmuted) 복원
    assert vols[:2] == [("id-P1", True), ("id-P2", True)]
    assert vols[2:6] == [("id-P1", False), ("id-P1", True), ("id-P2", False), ("id-P2", True)]
    assert vols[-2:] == [("id-P1", False), ("id-P2", False)]
    assert not clients["P1"].muted and not clients["P2"].muted
    assert slept[:5] == [3, 20, 3, 25, 3]   # 기기마다 solo 길이가 다르다


def test_assign_streams_splits_groups():
    srv = FakeSnapserver(["P1", "P2"])
    with SnapcastRPC("127.0.0.1", srv.port) as rpc:
        assign_streams(rpc, {"P1": "chL", "P2": "chR"})
        cl = {c.name: c for c in rpc.clients()}
    assert cl["P1"].group_id != cl["P2"].group_id
    assert cl["P1"].stream_id == "chL" and cl["P2"].stream_id == "chR"


def test_assign_unknown_stream_fails():
    srv = FakeSnapserver(["P1"])
    with SnapcastRPC("127.0.0.1", srv.port) as rpc, pytest.raises(KeyError):
        assign_streams(rpc, {"P1": "nope"})


def test_find_unknown_client_lists_names():
    srv = FakeSnapserver(["P1"])
    with SnapcastRPC("127.0.0.1", srv.port) as rpc, pytest.raises(KeyError, match="P1"):
        rpc.find("P9")


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="FIFO 미지원")
def test_fanout_writes_same_frames_to_each_fifo(tmp_path):
    rate = 48_000
    audio = np.zeros((rate // 10, 3))
    audio[:, 0] = 0.25
    audio[:, 1] = -0.5
    audio[:, 2] = np.linspace(-0.9, 0.9, len(audio))
    paths = [str(tmp_path / f"p{i}") for i in range(3)]
    for p in paths:
        os.mkfifo(p)
    got = {p: bytearray() for p in paths}

    def reader(p):
        with open(p, "rb") as f:
            while True:
                b = f.read(4096)
                if not b:
                    break
                got[p] += b

    ts = [threading.Thread(target=reader, args=(p,)) for p in paths]
    for t in ts:
        t.start()
    outs = [fanout.Output(paths[0], 0), fanout.Output(paths[1], 1), fanout.Output(paths[2], 2)]
    n = fanout.run(audio, rate, outs, chunk_ms=10, sleep=lambda s: None)
    for t in ts:
        t.join(timeout=5)
    assert n == 10
    for i, p in enumerate(paths):
        s = np.frombuffer(bytes(got[p]), dtype="<i2").reshape(-1, 2)
        assert len(s) == len(audio)
        assert np.array_equal(s[:, 0], s[:, 1])           # 모노 → L/R 복제
        assert np.allclose(s[:, 0] / 32767, audio[:, i], atol=1 / 32767)


def test_parse_outputs():
    o = fanout.parse_outputs(["/tmp/a:0", "/tmp/b:all"])
    assert o[0].channel == 0 and o[1].channel is None
    with pytest.raises(ValueError):
        fanout.parse_outputs(["nochannel"])
