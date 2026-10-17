"""Snapcast 서버 JSON-RPC 제어 (TCP, 기본 포트 1705, 줄 단위 JSON).

시험 A: 같은 스트림을 듣는 클라이언트들을 하나씩만 소리 나게(solo) 순환시킨다.
시험 B: 클라이언트마다 별도 그룹을 만들고 그룹별로 다른 스트림을 지정한다.

공식 API 문서: https://github.com/badaix/snapcast/blob/develop/doc/json_rpc_api/control.md
서버 버전에 따라 필드가 다를 수 있으므로 status 출력으로 먼저 확인한다.
"""
from __future__ import annotations

import json
import socket
import time
from dataclasses import dataclass


@dataclass
class ClientInfo:
    id: str
    name: str          # config.name 이 있으면 그것, 없으면 host.name
    host: str
    connected: bool
    muted: bool
    percent: int
    latency: int
    group_id: str
    stream_id: str


class SnapcastRPC:
    def __init__(self, host: str = "127.0.0.1", port: int = 1705, timeout: float = 5.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.file = self.sock.makefile("rwb")
        self._id = 0

    def close(self) -> None:
        try:
            self.file.close()
        finally:
            self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def call(self, method: str, params: dict | None = None):
        self._id += 1
        req = {"id": self._id, "jsonrpc": "2.0", "method": method}
        if params is not None:
            req["params"] = params
        self.file.write((json.dumps(req) + "\r\n").encode())
        self.file.flush()
        while True:
            line = self.file.readline()
            if not line:
                raise ConnectionError("Snapcast 서버 연결이 끊겼습니다")
            msg = json.loads(line)
            # 서버가 보내는 알림(notification)은 id가 없다 → 건너뜀
            if isinstance(msg, dict) and msg.get("id") == self._id:
                if "error" in msg:
                    raise RuntimeError(f"{method} 실패: {msg['error']}")
                return msg.get("result")

    # ------------------------------------------------------------ 조회
    def status(self) -> dict:
        return self.call("Server.GetStatus")["server"]

    def clients(self) -> list[ClientInfo]:
        out = []
        for g in self.status()["groups"]:
            for c in g["clients"]:
                cfg = c.get("config", {})
                vol = cfg.get("volume", {})
                host = c.get("host", {}).get("name", "")
                out.append(ClientInfo(
                    id=c["id"], name=cfg.get("name") or host, host=host,
                    connected=bool(c.get("connected", False)),
                    muted=bool(vol.get("muted", False)), percent=int(vol.get("percent", 100)),
                    latency=int(cfg.get("latency", 0)), group_id=g["id"],
                    stream_id=g.get("stream_id", "")))
        return out

    def find(self, key: str, clients: list[ClientInfo] | None = None) -> ClientInfo:
        """id / 이름 / host 이름 중 하나로 클라이언트를 찾는다."""
        clients = clients if clients is not None else self.clients()
        hits = [c for c in clients if key in (c.id, c.name, c.host)]
        if len(hits) != 1:
            names = ", ".join(f"{c.name}({c.id})" for c in clients)
            raise KeyError(f"클라이언트 '{key}' 를 하나로 찾지 못했습니다. 현재: {names}")
        return hits[0]

    # ------------------------------------------------------------ 설정
    def set_mute(self, client_id: str, muted: bool, percent: int | None = None) -> None:
        vol: dict = {"muted": muted}
        if percent is not None:
            vol["percent"] = int(percent)
        self.call("Client.SetVolume", {"id": client_id, "volume": vol})

    def set_latency(self, client_id: str, ms: int) -> None:
        self.call("Client.SetLatency", {"id": client_id, "latency": int(ms)})

    def set_name(self, client_id: str, name: str) -> None:
        self.call("Client.SetName", {"id": client_id, "name": name})

    def set_group_clients(self, group_id: str, client_ids: list[str]) -> None:
        self.call("Group.SetClients", {"id": group_id, "clients": client_ids})

    def set_group_stream(self, group_id: str, stream_id: str) -> None:
        self.call("Group.SetStream", {"id": group_id, "stream_id": stream_id})


def solo_rotation(rpc: SnapcastRPC, names: list[str], solo: float, gap: float,
                  cycles: int = 0, log=None, sleep=time.sleep, clock=time.time,
                  step: float = 5.0) -> None:
    """names 순서대로 한 대씩만 소리 나게 한다. 기기 k: (solo + k*step)초 재생 → gap초 전체 mute.

    기기마다 solo 길이를 다르게 해서, 분석기가 녹음만 보고 어느 구간이 어느 기기인지
    알아낼 수 있게 한다 (녹음을 언제 시작했는지와 무관).
    끝나거나 Ctrl-C로 멈추면 원래 mute 상태로 되돌린다.
    """
    clients = rpc.clients()
    targets = [rpc.find(n, clients) for n in names]
    original = {c.id: c.muted for c in targets}

    def emit(event: str, **kw):
        if log is not None:
            log.write(json.dumps({"t": clock(), "event": event, **kw}, ensure_ascii=False) + "\n")
            log.flush()

    try:
        for c in targets:
            rpc.set_mute(c.id, True)
        emit("all_muted")
        sleep(gap)
        n = 0
        while cycles <= 0 or n < cycles:
            for k, c in enumerate(targets):
                rpc.set_mute(c.id, False)
                emit("solo", client=c.name, id=c.id, seconds=solo + k * step)
                sleep(solo + k * step)
                rpc.set_mute(c.id, True)
                emit("gap")
                sleep(gap)
            n += 1
    finally:
        for c in targets:
            rpc.set_mute(c.id, original[c.id])
        emit("restored")


def assign_streams(rpc: SnapcastRPC, mapping: dict[str, str]) -> None:
    """클라이언트마다 단독 그룹을 만들고 지정한 스트림을 연결한다 (시험 B / 7채널)."""
    clients = rpc.clients()
    streams = {s["id"] for s in rpc.status().get("streams", [])}
    for name, stream in mapping.items():
        if stream not in streams:
            raise KeyError(f"스트림 '{stream}' 없음. 서버 스트림: {sorted(streams)}")
    for name in mapping:
        c = rpc.find(name, clients)
        members = [x.id for x in clients if x.group_id == c.group_id]
        if members != [c.id]:
            # 그룹에서 이 클라이언트만 남기면 나머지는 서버가 새 그룹으로 분리한다
            others = [m for m in members if m != c.id]
            rpc.set_group_clients(c.group_id, others)
            clients = rpc.clients()
    clients = rpc.clients()
    for name, stream in mapping.items():
        c = rpc.find(name, clients)
        rpc.set_group_stream(c.group_id, stream)
