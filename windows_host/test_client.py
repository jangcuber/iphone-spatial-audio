"""Minimal snapclient stand-in: checks the handshake, time sync and chunk stream of snaphost."""
import json, socket, struct, sys, time
import numpy as np
HDR = struct.Struct("<HHHiiiiI")
host, port, secs = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.create_connection((host, port)); s.settimeout(3)
def now():
    ns = time.perf_counter_ns(); return ns // 10**9, (ns // 1000) % 10**6
def send(t, mid, payload):
    a, b = now(); s.sendall(HDR.pack(t, mid, 0, a, b, 0, 0, len(payload)) + payload)
def recv():
    h = b""
    while len(h) < 26: h += s.recv(26 - len(h))
    t, mid, ref, a, b, c, d, size = HDR.unpack(h)
    body = b""
    while len(body) < size: body += s.recv(size - len(body))
    return t, ref, (a, b), body
hello = json.dumps({"HostName": "test", "Version": "0.35.0", "ID": "test", "Instance": 1, "SnapStreamProtocolVersion": 2}).encode()
send(5, 7, struct.pack("<I", len(hello)) + hello)
t, ref, _, body = recv(); assert t == 3 and ref == 7, (t, ref); print("ServerSettings", body[4:].decode())
t, ref, _, body = recv(); assert t == 1
n = struct.unpack("<I", body[:4])[0]; codec = body[4:4+n]; wav = body[8+n:]
ch, rate = struct.unpack("<H", wav[22:24])[0], struct.unpack("<I", wav[24:28])[0]
print("codec", codec, "channels", ch, "rate", rate)
send(4, 42, struct.pack("<ii", 0, 0))
chunks, ts, rms = 0, [], np.zeros(7); t0 = time.time(); got_time = False
while time.time() - t0 < secs:
    t, ref, sent, body = recv()
    if t == 4: got_time = ref == 42; rtt = body
    elif t == 2:
        sec, usec, size = struct.unpack("<iiI", body[:12]); ts.append(sec + usec / 1e6)
        x = np.frombuffer(body[12:], "<i2").reshape(-1, 7) / 32768; rms += (x**2).mean(0); chunks += 1
d = np.diff(ts) * 1000
print("time reply ok:", got_time, "chunks", chunks, f"spacing ms mean {d.mean():.3f} min {d.min():.3f} max {d.max():.3f}")
print("per-channel level dB:", np.round(10*np.log10(rms/chunks + 1e-12), 1))
print("server ts vs local now (ms):", round((time.perf_counter_ns()/1e9 - ts[-1]) * 1000, 1))
