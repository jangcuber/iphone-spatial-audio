"""Windows host for the iPhone speaker system (does the Mac's sysbridge + snapserver job).

Captures the multichannel output that Windows sends to the VB-CABLE virtual device,
folds it to 5.0.2 (FL FR C SL SR HL HR), applies the per-phone delay and gain from
config.json (same values as the Mac's presets/desk.json), and serves it to the phones'
snapclients with the Snapcast binary protocol (TCP 1704) as one 7-channel PCM stream,
48000:16:7, chunk 20 ms, buffer 1000 ms - the same stream the Mac's snapserver sent.

Timing rules carried over from the Mac (sysbridge):
- chunk timestamps advance by exactly 960 frames / 20 ms on one clock, never jump;
- the capture is resampled by up to +-500 ppm to hold a 100 ms ring at fixed fill;
- if capture stalls, silence is sent and timestamps stay continuous;
- Time requests are stamped at arrival on a dedicated reader thread and answered at once.

    python snaphost.py                  # capture from VB-CABLE
    python snaphost.py --source tone    # internal test chime, nothing is played locally
    python snaphost.py --list-devices
"""

import argparse
import json
import queue
import socket
import struct
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT_NAMES = ["FL", "FR", "C", "SL", "SR", "HL", "HR"]  # phone CHANNEL 0..6
NS = 1_000_000_000

# Snapcast message types (common/message/message.hpp)
T_CODEC_HEADER, T_WIRE_CHUNK, T_SERVER_SETTINGS, T_TIME, T_HELLO = 1, 2, 3, 4, 5
NL, CRLF = bytes([10]), bytes([13, 10])
HDR = struct.Struct("<HHHiiiiI")  # type, id, refersTo, sent.sec, sent.usec, recv.sec, recv.usec, size


def clock_ns():
    """Server clock: the one clock for chunk timestamps and time sync."""
    return time.perf_counter_ns()


def tv(ns):
    return int(ns // NS), int((ns // 1000) % 1_000_000)


def pack_msg(mtype, payload, refers_to=0, recv_ns=0):
    s, u = tv(clock_ns())
    rs, ru = tv(recv_ns) if recv_ns else (0, 0)
    return HDR.pack(mtype, 0, refers_to, s, u, rs, ru, len(payload)) + payload


def pack_str(b):
    b = b.encode() if isinstance(b, str) else b
    return struct.pack("<I", len(b)) + b


def wav_header(rate, bits, channels):
    block = channels * bits // 8
    return (b"RIFF" + struct.pack("<I", 36) + b"WAVE"
            + b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * block, block, bits)
            + b"data" + struct.pack("<I", 0))


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ----------------------------------------------------------------------------- config

def load_config(path):
    cfg = json.loads(Path(path).read_text(encoding="utf-8"))
    for k, v in {"port": 1704, "buffer_ms": 1000, "rate": 48000, "chunk_ms": 20,
                 "input_device": "CABLE Output", "input_channels": 8, "ring_ms": 100,
                 "height_from_surround_db": -9.0, "stereo_upmix": "auto"}.items():
        cfg.setdefault(k, v)
    cal = cfg.get("calibration", {})
    cfg["delay_ms"] = [max(0.0, float(cal.get("delay_ms", {}).get(n, 0.0))) for n in OUT_NAMES]
    cfg["gain_db"] = [float(cal.get("gain_db", {}).get(n, 0.0)) for n in OUT_NAMES]
    return cfg


# ----------------------------------------------------------------------------- fold + calibration

def db(x):
    return 10 ** (x / 20.0)


class Folder:
    """Windows channel order in -> FL FR C SL SR HL HR out, then gain -> delay (like sysbridge).

    Windows apps deliver at most 7.1 (FL FR FC LFE BL BR SL SR); there are no height
    channels, so HL/HR get the surrounds at height_from_surround_db. LFE is dropped.
    Stereo-only audio (all other channels digital zero for 1.5 s) switches to the Mac's
    stereo upmix with a 40 ms crossfade.
    """

    def __init__(self, cfg, in_ch):
        self.in_ch, self.rate = in_ch, cfg["rate"]
        self.h = db(cfg["height_from_surround_db"])
        self.mode = cfg["stereo_upmix"]           # auto | on | off
        self.mix = 1.0 if self.mode == "on" else 0.0
        self.stereo_frames = 0
        self.gain = np.array([db(g) for g in cfg["gain_db"]], dtype=np.float32)
        self.delay = np.array([round(d * self.rate / 1000.0) for d in cfg["delay_ms"]], dtype=np.int64)
        self.hist = np.zeros((int(self.delay.max()) + 1, 7), dtype=np.float32)
        self.side_hist = np.zeros(600, dtype=np.float32)   # 12.5 ms ambience delay

    def multichannel(self, x):
        n, ch = x.shape
        z = np.zeros(n, dtype=np.float32)
        fl = x[:, 0]
        fr = x[:, 1] if ch > 1 else x[:, 0]
        c = x[:, 2] if ch >= 6 else z
        r = 0.7071
        if ch >= 8:      # FL FR FC LFE BL BR SL SR: back + side share a phone, each x1/sqrt(2)
            sl, sr = r * (x[:, 4] + x[:, 6]), r * (x[:, 5] + x[:, 7])
        elif ch >= 6:    # FL FR FC LFE SL SR
            sl, sr = x[:, 4], x[:, 5]
        else:
            sl, sr = z, z
        has_rest = ch > 2 and bool(np.any(x[:, 2:]))
        return np.stack([fl, fr, c, sl, sr, self.h * sl, self.h * sr], axis=1), has_rest

    def upmix(self, x):
        L = x[:, 0]
        R = x[:, 1] if x.shape[1] > 1 else L
        side = (L - R) / 2
        buf = np.concatenate([self.side_hist, side])
        amb = buf[:len(side)]
        self.side_hist = buf[len(side):]
        return np.stack([L, R, 0.35 * (L + R), 0.8 * amb, -0.8 * amb, 0.5 * amb, -0.5 * amb], axis=1)

    def process(self, x):
        n = x.shape[0]
        if self.in_ch == 7:              # already one channel per phone (test chime)
            return self.calibrate(x * self.gain)
        multi, has_rest = self.multichannel(x)
        up = self.upmix(x)
        if self.mode == "auto":
            self.stereo_frames = 0 if has_rest else self.stereo_frames + n
            target = 1.0 if self.stereo_frames >= 1.5 * self.rate else 0.0
        else:
            target = self.mix
        step = n / (0.040 * self.rate)
        new = min(target, self.mix + step) if target > self.mix else max(target, self.mix - step)
        ramp = np.linspace(self.mix, new, n, dtype=np.float32)[:, None]
        self.mix = new
        return self.calibrate((multi * (1 - ramp) + up * ramp) * self.gain)

    def calibrate(self, out):
        n = out.shape[0]
        buf = np.concatenate([self.hist, out], axis=0)
        H = self.hist.shape[0]
        res = np.empty_like(out)
        for c in range(7):
            s = H - int(self.delay[c])
            res[:, c] = buf[s:s + n, c]
        self.hist = buf[-H:]
        return res


def to_pcm16(x):
    return (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()


# ----------------------------------------------------------------------------- ring + resampler

class Ring:
    """Capture -> fixed-fill buffer, read out by a +-500 ppm Hermite resampler (sysbridge's loop)."""

    def __init__(self, ch, rate, target_ms):
        self.lock = threading.Lock()
        self.buf = np.zeros((0, ch), dtype=np.float32)
        self.pos = 1.0                 # fractional read position (1 sample of history before it)
        self.ch, self.rate = ch, rate
        self.target = target_ms * rate / 1000.0
        self.fill_avg = None
        self.integ = 0.0
        self.corr = 0.0
        self.running = False
        self.underruns = 0

    def write(self, x):
        with self.lock:
            self.buf = np.concatenate([self.buf, x.astype(np.float32, copy=False)])
            if len(self.buf) > self.rate * 2:        # >2 s backlog: drop the oldest, keep target fill
                drop = len(self.buf) - int(self.target) - 4
                self.buf = self.buf[drop:]
                self.pos = 1.0

    def read(self, n):
        dt = n / self.rate
        with self.lock:
            fill = len(self.buf) - self.pos
            if not self.running:
                if fill < self.target:
                    return np.zeros((n, self.ch), np.float32)
                self.running, self.fill_avg = True, fill
            self.fill_avg += (fill - self.fill_avg) * (dt / 2.0)          # ~2 s average
            err = (self.fill_avg - self.target) / self.rate
            self.integ = float(np.clip(self.integ + err * dt, -5.0, 5.0))
            self.corr = float(np.clip(0.05 * err + 6e-4 * self.integ, -500e-6, 500e-6))
            ratio = 1.0 + self.corr
            p = self.pos + np.arange(n) * ratio
            if p[-1] + 2 >= len(self.buf):                                # capture stalled
                self.underruns += 1
                self.running = False
                self.buf = self.buf[-2:] if len(self.buf) >= 2 else np.zeros((2, self.ch), np.float32)
                self.pos = 1.0
                return np.zeros((n, self.ch), np.float32)
            i = p.astype(np.int64)
            t = (p - i)[:, None].astype(np.float32)
            y0, y1, y2, y3 = self.buf[i - 1], self.buf[i], self.buf[i + 1], self.buf[i + 2]
            c1 = 0.5 * (y2 - y0)
            c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
            c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
            out = ((c3 * t + c2) * t + c1) * t + y1
            self.pos += n * ratio
            drop = int(self.pos) - 1
            self.buf = self.buf[drop:]
            self.pos -= drop
            return out


# ----------------------------------------------------------------------------- sources (write into the ring)

def run_cable(cfg, ring_box, stop):
    import sounddevice as sd
    rate = cfg["rate"]
    dev = find_device(sd, cfg["input_device"])
    info = sd.query_devices(dev)
    in_ch = min(cfg["input_channels"], info["max_input_channels"])
    ring_box.append(Ring(in_ch, rate, cfg["ring_ms"]))
    log(f"capturing '{info['name']}' ({in_ch} ch, {rate} Hz)")
    try:
        extra = sd.WasapiSettings(auto_convert=True)
    except Exception:
        extra = None

    def cb(indata, frames, t, status):
        if status:
            log(f"capture status: {status}")
        ring_box[0].write(indata.copy())

    with sd.InputStream(device=dev, channels=in_ch, samplerate=rate, blocksize=rate // 100,
                        dtype="float32", callback=cb, extra_settings=extra):
        stop.wait()


def find_device(sd, name):
    apis = sd.query_hostapis()
    best = None
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and name.lower() in d["name"].lower():
            if "WASAPI" in apis[d["hostapi"]]["name"]:
                return i
            best = i if best is None else best
    if best is None:
        raise SystemExit(f"input device containing '{name}' not found. Run with --list-devices.")
    return best


def run_chime7(cfg, ring_box, stop):
    """One soft bell per phone, FL FR C SL SR HL HR in turn (0.8 s apart), then silence."""
    rate = cfg["rate"]
    ring_box.append(Ring(7, rate, cfg["ring_ms"]))
    notes = [523.25, 587.33, 659.25, 698.46, 783.99, 880.0, 987.77]
    n, i, start = rate // 100, 0, clock_ns()
    while not stop.is_set():
        t = (i * n + np.arange(n)) / rate - 4.0           # 4 s of silence first (phones reconnect)
        x = np.zeros((n, 7), dtype=np.float32)
        for k in range(7):
            ph = t - 0.8 * k
            m = (ph >= 0) & (ph < 0.8)
            env = np.exp(-ph[m] * 6.0) * np.minimum(ph[m] * 300, 1.0)
            x[m, k] = cfg.get("chime_level", 0.1) * env * (np.sin(2 * np.pi * notes[k] * ph[m]) + 0.3 * np.sin(4 * np.pi * notes[k] * ph[m]))
        ring_box[0].write(x)
        i += 1
        d = (start + i * n * NS // rate - clock_ns()) / NS
        if d > 0:
            time.sleep(d)


def run_tone(cfg, ring_box, stop):
    """Soft bell on one 7.1 input at a time (C major notes), for silent pipeline tests."""
    rate = cfg["rate"]
    ring_box.append(Ring(8, rate, cfg["ring_ms"]))
    notes = [523.25, 587.33, 659.25, 783.99, 880.0]
    inputs = [0, 1, 2, 6, 7]
    n, i, start = rate // 100, 0, clock_ns()
    while not stop.is_set():
        t = (i * n + np.arange(n)) / rate
        which = int(t[0]) % 5
        ph = t % 1.0
        env = np.exp(-ph * 5.0) * np.minimum(ph * 200, 1.0)
        x = np.zeros((n, 8), dtype=np.float32)
        x[:, inputs[which]] = 0.2 * env * np.sin(2 * np.pi * notes[which] * t)
        ring_box[0].write(x)
        i += 1
        d = (start + i * n * NS // rate - clock_ns()) / NS
        if d > 0:
            time.sleep(d)


# ----------------------------------------------------------------------------- server

class Client:
    def __init__(self, sock, addr, server):
        self.sock, self.addr, self.server = sock, addr, server
        self.name = addr[0]
        self.q = queue.Queue(maxsize=100)
        self.send_lock = threading.Lock()
        self.alive = True
        self.streaming = False

    def send(self, data):
        with self.send_lock:
            self.sock.sendall(data)

    def reader(self):
        try:
            while True:
                h = self.recv_exact(HDR.size)
                arrived = clock_ns()          # stamp at arrival; phones trust only c2s
                mtype, mid, _ref, ss, su, _a, _b, size = HDR.unpack(h)
                body = self.recv_exact(size) if size else b""
                if mtype == T_TIME:
                    lat_us = (arrived // 1000) - (ss * 1_000_000 + su)
                    sec, usec = divmod(lat_us, 1_000_000)
                    self.send(pack_msg(T_TIME, struct.pack("<ii", sec, usec), mid, arrived))
                elif mtype == T_HELLO:
                    hello = json.loads(body[4:].decode("utf-8", "replace"))
                    self.name = f"{hello.get('HostName', '?')} ({self.addr[0]})"
                    settings = {"bufferMs": self.server.cfg["buffer_ms"], "latency": 0, "muted": False, "volume": 100}
                    self.send(pack_msg(T_SERVER_SETTINGS, pack_str(json.dumps(settings)), mid))
                    self.send(pack_msg(T_CODEC_HEADER, self.server.header))
                    self.streaming = True
                    log(f"phone connected: {self.name}, snapclient {hello.get('Version', '?')}")
        except (ConnectionError, OSError):
            pass
        finally:
            self.close()

    def writer(self):
        try:
            while self.alive:
                try:
                    data = self.q.get(timeout=1)
                except queue.Empty:
                    continue
                self.send(data)
        except (ConnectionError, OSError):
            self.close()

    def recv_exact(self, n):
        b = bytearray()
        while len(b) < n:
            part = self.sock.recv(n - len(b))
            if not part:
                raise ConnectionError
            b += part
        return bytes(b)

    def close(self):
        if self.alive:
            self.alive = False
            self.server.drop(self)
            try:
                self.sock.close()
            except OSError:
                pass


class Server:
    def __init__(self, cfg):
        self.cfg = cfg
        self.last_sound = None      # monotonic time of the last non-silent chunk
        self.clients = []
        self.lock = threading.Lock()
        self.header = pack_str("pcm") + pack_str(wav_header(cfg["rate"], 16, 7))

    def listen(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.cfg.get("bind", "0.0.0.0"), self.cfg["port"]))
        s.listen(16)
        while True:
            sock, addr = s.accept()
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            c = Client(sock, addr, self)
            with self.lock:
                self.clients.append(c)
            threading.Thread(target=c.reader, daemon=True).start()
            threading.Thread(target=c.writer, daemon=True).start()

    def drop(self, c):
        with self.lock:
            if c in self.clients:
                self.clients.remove(c)
                log(f"phone disconnected: {c.name}")

    def playing(self):
        """Like snapserver's idle_threshold=5000: idle after 5 s of continuous silence."""
        return self.last_sound is not None and time.monotonic() - self.last_sound < 5.0

    def control(self):
        """Minimal Snapcast JSON-RPC on TCP 1705 so the phones' snapswitch can see if this PC plays."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.cfg.get("bind", "0.0.0.0"), self.cfg.get("control_port", 1705)))
        s.listen(16)
        while True:
            sock, _ = s.accept()
            threading.Thread(target=self.control_client, args=(sock,), daemon=True).start()

    def control_client(self, sock):
        sock.settimeout(30)
        buf = b""
        try:
            while True:
                part = sock.recv(4096)
                if not part:
                    break
                buf += part
                while NL in buf:
                    line, buf = buf.split(NL, 1)
                    if not line.strip():
                        continue
                    try:
                        req = json.loads(line)
                    except ValueError:
                        continue
                    rid = req.get("id")
                    if req.get("method") == "Server.GetStatus":
                        status = "playing" if self.playing() else "idle"
                        resp = {"id": rid, "jsonrpc": "2.0",
                                "result": {"server": {"streams": [{"id": "Ch7", "status": status}]}}}
                    else:
                        resp = {"id": rid, "jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}}
                    sock.sendall(json.dumps(resp, separators=(",", ":")).encode() + CRLF)
        except OSError:
            pass
        finally:
            sock.close()

    def broadcast(self, ts_ns, pcm):
        s, u = tv(ts_ns)
        msg = pack_msg(T_WIRE_CHUNK, struct.pack("<iiI", s, u, len(pcm)) + pcm)
        with self.lock:
            for c in self.clients:
                if c.streaming:
                    try:
                        c.q.put_nowait(msg)
                    except queue.Full:
                        pass


class Master:
    """Windows volume of the VB-CABLE device (VB-CABLE itself ignores it), from volwatch.exe."""

    def __init__(self, device):
        self.gain = 1.0
        self.desc = "100%"
        exe = HERE / "volwatch.exe"
        if not exe.exists():
            log("volwatch.exe missing: Windows volume keys will not work")
            return
        import subprocess
        self.proc = subprocess.Popen([str(exe), device], stdout=subprocess.PIPE, text=True,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.proc.stdout:
            try:
                scalar, level_db, muted = line.split()
                self.gain = 0.0 if muted == "1" else db(float(level_db))
                self.desc = "mute" if muted == "1" else f"{float(scalar) * 100:.0f}% ({float(level_db):.1f} dB)"
            except ValueError:
                pass


def producer(cfg, server, ring_box, stop):
    """Emits exactly one 20 ms chunk per 20 ms; timestamps are start + k*20 ms, never adjusted."""
    rate, n = cfg["rate"], cfg["rate"] * cfg["chunk_ms"] // 1000
    while not ring_box and not stop.is_set():
        time.sleep(0.05)
    ring = ring_box[0]
    folder = Folder(cfg, ring.ch)
    master = Master(cfg.get("volume_device", "CABLE Input")) if cfg.get("_source") == "cable" else None
    cur = master.gain if master else 1.0
    start = clock_ns()
    k = 0
    last_log = time.monotonic()
    while not stop.is_set():
        ts = start + k * n * NS // rate
        out = folder.process(ring.read(n))
        if master:
            # smooth volume changes over ~40 ms, like the Mac
            target = master.gain
            nxt = cur + (target - cur) * min(1.0, n / (0.040 * rate))
            out *= np.linspace(cur, nxt, n, dtype=np.float32)[:, None]
            cur = nxt
        pcm = to_pcm16(out)
        if np.abs(np.frombuffer(pcm, "<i2")).max() > 2:
            server.last_sound = time.monotonic()
        server.broadcast(ts, pcm)
        k += 1
        d = (start + k * n * NS // rate - clock_ns()) / NS
        if d > 0:
            time.sleep(d)
        if time.monotonic() - last_log > cfg.get("status_every_s", 30):
            last_log = time.monotonic()
            names = ", ".join(c.name for c in server.clients) or "none"
            log(f"{len(server.clients)} phone(s): {names} | rate corr {ring.corr * 1e6:+.0f} ppm, "
                f"{'playing' if server.playing() else 'idle'}, volume {master.desc if master else '-'}, fill {(len(ring.buf) - ring.pos) / rate * 1000:.0f} ms, stalls {ring.underruns}, stereo upmix {folder.mix:.0f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(HERE / "config.json"))
    ap.add_argument("--source", choices=["cable", "tone", "silence", "chime7"], default="cable")
    ap.add_argument("--bind")
    ap.add_argument("--port", type=int)
    ap.add_argument("--list-devices", action="store_true")
    a = ap.parse_args()
    if a.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return
    cfg = load_config(a.config)
    cfg["_source"] = a.source
    if a.bind:
        cfg["bind"] = a.bind
    if a.port:
        cfg["port"] = a.port
    server = Server(cfg)
    stop = threading.Event()
    ring_box = []
    if a.source == "silence":
        ring_box.append(Ring(8, cfg["rate"], cfg["ring_ms"]))
    else:
        src = {"cable": run_cable, "tone": run_tone, "chime7": run_chime7}[a.source]

        def guarded():
            try:
                src(cfg, ring_box, stop)
            except BaseException as e:
                log(f"audio source stopped: {e!r}")
                stop.set()
        threading.Thread(target=guarded, daemon=True).start()
    threading.Thread(target=server.listen, daemon=True).start()
    threading.Thread(target=server.control, daemon=True).start()
    threading.Thread(target=producer, args=(cfg, server, ring_box, stop), daemon=True).start()
    log(f"serving 7-ch PCM {cfg['rate']}:16:7 on TCP {cfg['port']}, buffer {cfg['buffer_ms']} ms, source={a.source}")
    try:
        while not stop.is_set():
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
