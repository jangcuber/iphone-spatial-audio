"""폰 스피커 상태 창 (Windows version of the Mac's 폰 스피커.app).

Every 15 s while the window is open it finds the phones on the home Wi-Fi and shows,
for the 7 speaker phones and the mic phone: Wi-Fi reachable, whether snapclient is
connected (and to the Mac or this PC), battery %, charging. Everything it runs on the
phones is read-only. The 켜기/끄기 buttons run the same host.ps1 as 켜기.bat / 끄기.bat, without a console window.
"""

import concurrent.futures as cf
import os
import json
import re
import socket
import subprocess
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import ttk

HERE = Path(__file__).resolve().parent
KEY = Path.home() / ".ssh" / "id_ed25519_phones"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
SEATS = {"0": "앞 왼쪽", "1": "앞 오른쪽", "2": "가운데", "3": "옆 왼쪽",
         "4": "옆 오른쪽", "5": "위 왼쪽", "6": "위 오른쪽"}
EXPECTED = [f"node-0{i}" for i in range(1, 8)]
try:
    _CFG = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
except (OSError, ValueError):
    _CFG = {}
# Mac Wi-Fi hardware address ("aa-bb-cc-dd-ee-ff") and fallback IP, from config.json
MAC_HW = str(_CFG.get("mac_wifi_mac", "")).lower().replace(":", "-")
MAC_IP = str(_CFG.get("mac_ip", ""))
REFRESH_S = 15

# read-only: config values, model, battery, last log line, phone clock
REMOTE = (
    "c=/var/jb/etc/snapclient.conf; [ -f $c ] && grep -E '^(NAME|CHANNEL|SERVER)=' $c; "
    "echo HW=$(sysctl -n hw.machine); "
    "echo BI=$(/var/mobile/battinfo 2>/dev/null); "
    "ioreg -rc AppleSmartBattery 2>/dev/null | grep -E '\"(CurrentCapacity|IsCharging|FullyCharged|ExternalConnected)\"'; "
    "tail -n 8 /var/mobile/Library/Logs/snapclient.log 2>/dev/null | sed 's/^/LOG=/'; "
    "echo NOW=$(date '+%Y-%m-%d %H-%M-%S')"
)


def wifi_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 9))  # no packet is sent; picks the LAN interface
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def port_open(ip, port=22, timeout=1.5):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def cached_ips():
    f = HERE / "phones.txt"
    if not f.exists():
        return {}
    out = {}
    for line in f.read_text(encoding="utf-8-sig").splitlines():
        m = re.match(r"(node-\d+)\s+\S+\s+(\d+\.\d+\.\d+\.\d+)", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def mac_ip():
    try:
        arp = subprocess.run(["arp", "-a"], capture_output=True, text=True, creationflags=NO_WINDOW).stdout
        for line in arp.splitlines():
            if MAC_HW and MAC_HW in line:
                return line.split()[0]
    except OSError:
        pass
    f = HERE / "state" / "mac_ip.txt"
    return f.read_text().strip() if f.exists() else MAC_IP


def ssh(ip):
    try:
        r = subprocess.run(["ssh", "-n", "-i", str(KEY), "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                            "-o", "StrictHostKeyChecking=accept-new", f"mobile@{ip}", REMOTE],
                           capture_output=True, text=True, timeout=20, creationflags=NO_WINDOW,
                           encoding="utf-8", errors="replace")
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return -1, ""


def parse(ip, text, pc, mac):
    v = {}
    logs = []
    for line in text.splitlines():
        if line.startswith("LOG="):
            logs.append(line[4:])
            continue
        line = line.strip().lstrip("| ").strip()
        m = re.match(r"(NAME|CHANNEL|SERVER|HW|BI|LOG|NOW)=(.*)", line)
        if m:
            v[m.group(1)] = m.group(2).strip().strip("'")
        m = re.match(r'"(\w+)" = (\w+)', line)
        if m:
            v[m.group(1)] = m.group(2)
    p = {"ip": ip, "wifi": "연결됨"}
    p["name"] = v.get("NAME") or ("마이크폰" if v.get("HW") == "iPhone11,8" else f"기타 ({v.get('HW', '?')})")
    p["seat"] = SEATS.get(v.get("CHANNEL", ""), "마이크" if v.get("HW") == "iPhone11,8" else "")
    # battery: battinfo (iOS 17+) prints "pct|external|charging|charged"; older iOS answers ioreg
    bi = v.get("BI", "")
    if re.match(r"\d+\|", bi):
        pct, ext, chg, full = (bi.split("|") + ["", "", ""])[:4]
        p["batt"], plugged, charging, charged = pct + "%", ext == "Yes", chg == "Yes", full == "Yes"
    elif "CurrentCapacity" in v:
        p["batt"] = v["CurrentCapacity"] + "%"
        plugged, charging, charged = v.get("ExternalConnected") == "Yes", v.get("IsCharging") == "Yes", v.get("FullyCharged") == "Yes"
    else:
        p["batt"], plugged, charging, charged = "?", False, False, False
    p["charge"] = "충전 중" if charging else "완충" if charged else "전원 연결(충전 안 함)" if plugged else "배터리 사용"
    # player: look at the last log lines. Data lines (Stats/TimeSync/Dac) after the last
    # connect attempt or error mean connected; a quiet log whose last line is not an error also counts.
    now = v.get("NOW", "")
    if "NAME" not in v:
        p["play"] = "-"
    else:
        good = bad = -1
        for i, line in enumerate(logs):
            if any(k in line for k in ("(Stats)", "(TimeSync)", "(Dac)")):
                good = i
            if any(k in line for k in ("[Error]", "Reconnect", "Connecting to host", "Resolving host")):
                bad = i
        fresh = False
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d-\d\d-\d\d)", logs[-1] if logs else "")
        if m and now:
            try:
                age = time.mktime(time.strptime(now, "%Y-%m-%d %H-%M-%S")) - time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H-%M-%S"))
                fresh = age < 10
            except ValueError:
                pass
        ok = good > bad if good >= 0 else (not fresh and bad < len(logs) - 1 and bool(logs))
        server = v.get("SERVER", "")
        who = "PC" if server == pc else "맥" if server == mac else server
        p["play"] = f"{who}에 연결" if ok else f"끊김 ({who} 기다리는 중)"
    return p


def scan():
    pc = wifi_ip()
    if not pc or not re.match(r"^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)", pc):
        return None, "이 PC가 집 Wi-Fi에 있지 않아요"
    net = pc.rsplit(".", 1)[0]
    cache = cached_ips()
    ips = [f"{net}.{i}" for i in range(2, 255) if f"{net}.{i}" != pc]
    with cf.ThreadPoolExecutor(64) as ex:
        open_ips = [ip for ip, ok in zip(ips, ex.map(port_open, ips)) if ok]
    targets = sorted(set(open_ips) | set(cache.values()), key=lambda s: int(s.rsplit(".", 1)[1]))
    mac = mac_ip()
    rows = []
    with cf.ThreadPoolExecutor(16) as ex:
        for ip, (code, out) in zip(targets, ex.map(ssh, targets)):
            if code == 0:
                rows.append(parse(ip, out, pc, mac))
    found = {r["name"] for r in rows}
    for n in EXPECTED:
        if n not in found:
            ip = cache.get(n, "")
            rows.append({"name": n, "seat": "", "ip": ip, "wifi": "응답 없음", "play": "-", "batt": "-", "charge": "-"})
    rows = [r for r in rows if not r["name"].startswith("기타")]
    rows.sort(key=lambda r: (not r["name"].startswith("node"), r["name"]))
    on_pc = sum(1 for r in rows if r["play"].startswith("PC에"))
    on_mac = sum(1 for r in rows if r["play"].startswith("맥에"))
    return rows, f"PC {pc} · 맥 {mac} · 맥에 연결 {on_mac}대 · PC에 연결 {on_pc}대"


class App:
    COLS = [("name", "폰", 110), ("seat", "자리", 80), ("ip", "주소", 110), ("wifi", "Wi-Fi", 75),
            ("play", "소리 연결", 150), ("batt", "배터리", 60), ("charge", "충전", 100)]

    def __init__(self, root):
        self.root = root
        root.title("폰 스피커 상태")
        root.geometry("760x410")
        top = ttk.Frame(root, padding=8)
        top.pack(fill="x")
        self.btn_on = ttk.Button(top, text="켜기 (노트북으로 듣기)", command=lambda: self.run_host("on"))
        self.btn_on.pack(side="left")
        self.btn_off = ttk.Button(top, text="끄기 (맥으로 되돌리기)", command=lambda: self.run_host("off"))
        self.btn_off.pack(side="left", padx=6)
        ttk.Button(top, text="지금 새로고침", command=self.refresh).pack(side="right")
        self.tree = ttk.Treeview(root, columns=[c[0] for c in self.COLS], show="headings", height=9)
        for key, title, w in self.COLS:
            self.tree.heading(key, text=title)
            self.tree.column(key, width=w, anchor="w")
        self.tree.tag_configure("bad", foreground="#c0392b")
        self.tree.tag_configure("low", foreground="#d35400")
        self.tree.pack(fill="both", expand=True, padx=8)
        self.status = tk.StringVar(value="폰을 찾는 중...")
        ttk.Label(root, textvariable=self.status, padding=(8, 4)).pack(fill="x")
        self.action = tk.StringVar(value="")
        ttk.Label(root, textvariable=self.action, padding=(8, 0, 8, 8), foreground="#1a5fb4").pack(fill="x")
        self.busy = False
        self.timer = None
        self.refresh()

    def run_host(self, cmd):
        """Runs the same steps as 켜기.bat / 끄기.bat (host.ps1) with no console window."""
        self.btn_on.state(["disabled"])
        self.btn_off.state(["disabled"])
        self.action.set("켜는 중... (15초쯤 걸려요)" if cmd == "on" else "끄는 중... (15초쯤 걸려요)")
        threading.Thread(target=self.host_work, args=(cmd,), daemon=True).start()

    def host_work(self, cmd):
        try:
            # output goes to a file, not a pipe: the sender that 켜기 starts inherits the handles
            # and would keep a pipe open forever
            outf = HERE / "state" / f"button_{cmd}.txt"
            outf.parent.mkdir(exist_ok=True)
            with open(outf, "wb") as f:
                subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                                str(HERE / "host.ps1"), cmd], stdin=subprocess.DEVNULL,
                               stdout=f, stderr=subprocess.STDOUT, timeout=180, creationflags=NO_WINDOW)
            out = outf.read_bytes().decode("cp949", "replace")
            lines = [l.strip() for l in out.splitlines() if l.strip()]
            fails = [l for l in lines if "실패" in l or "못 찾은" in l or "못했" in l or "Exception" in l]
            moved = next((l for l in lines if l.startswith("폰 ") and "→" in l), "")
            if fails:
                msg = " / ".join(fails[:3])
            elif moved:
                msg = ("켜기 완료: " if cmd == "on" else "끄기 완료: ") + moved
            else:
                msg = ("켜기" if cmd == "on" else "끄기") + " 완료"
        except subprocess.TimeoutExpired:
            msg = "시간이 너무 오래 걸려 멈췄어요. 다시 눌러 주세요."
        self.root.after(0, self.host_done, msg)

    def host_done(self, msg):
        self.action.set(f"{msg} ({time.strftime('%H:%M:%S')})")
        self.btn_on.state(["!disabled"])
        self.btn_off.state(["!disabled"])
        self.root.after(3000, self.refresh)

    def refresh(self):
        if self.timer:
            self.root.after_cancel(self.timer)
            self.timer = None
        if self.busy:
            return
        self.busy = True
        self.status.set("확인 중...")
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        try:
            rows, summary = scan()
        except Exception as e:
            rows, summary = None, f"확인 실패: {e}"
        self.root.after(0, self.show, rows, summary)

    def show(self, rows, summary):
        self.busy = False
        if rows is not None:
            self.tree.delete(*self.tree.get_children())
            for r in rows:
                tag = ()
                if r["wifi"] != "연결됨" or r["play"].startswith("끊김"):
                    tag = ("bad",)
                elif r["batt"].rstrip("%").isdigit() and int(r["batt"].rstrip("%")) < 20:
                    tag = ("low",)
                self.tree.insert("", "end", values=[r[c[0]] for c in self.COLS], tags=tag)
        self.status.set(f"{summary} · {time.strftime('%H:%M:%S')} 확인 (15초마다 자동)")
        self.timer = self.root.after(REFRESH_S * 1000, self.refresh)


if __name__ == "__main__":
    root = tk.Tk()
    App(root)
    root.mainloop()
