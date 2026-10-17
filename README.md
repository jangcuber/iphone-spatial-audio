# iPhone Spatial Audio

Turn a handful of **jailbroken iPhones into a synchronized wireless surround speaker system**,
with a Mac (or a Windows PC) acting as the receiver.
Each phone plays one channel of a 5.0.2 layout (FL FR C SL SR HL HR) through its own speaker.
Apple Music / QuickTime Dolby Atmos is rendered by macOS to a 7.1.4 virtual device and folded down to the phones.

It is built on [Snapcast](https://github.com/snapcast/snapcast): a patched `snapserver` runs on the Mac and
a patched `snapclient` runs as a background daemon on each phone. A microphone-based calibration step lines
up arrival time and level at your listening seat.

> Hobby project. Not affiliated with Apple, Dolby or the Snapcast project.
> Requires a jailbreak, and the setup scripts print their messages in Korean (the code comments are mostly Korean too).

```
 Mac apps ──► "SpatialPhones" 12-ch virtual device (BlackHole fork, 7.1.4)
                 │
                 ▼
            sysbridge  (7.1.4 → 5.0.2 fold, per-phone delay/gain, clock drift control)
                 │  7-ch PCM pipe
                 ▼
            snapserver (patched)  ── Wi-Fi, TCP 1704 ──►  iPhone × N  (snapclient daemon, CHANNEL = 0..6)
                 ▲ control 1705                              │
                 └──────────── snapswitch (on each phone) ───┘  follows whichever computer is playing
 Windows PC (optional): VB-CABLE 7.1 ──► snaphost.py (speaks the Snapcast protocol itself) ──► same phones
```

## What is in this repo

| Path | What it is |
|---|---|
| `ios_client/` | iOS port of `snapclient` for Dopamine (rootless): `snapcast-ios.patch` on Snapcast `4fed179`, `build.sh` → `.deb`. Adds `--channel` (play one channel of a multichannel stream), `--speaker`, AVAudioSession playback that keeps running with the screen locked, RemoteIO output, a fix for the ±100 ms resync jumps of the CoreAudio player, phone→server clock sync, and `keepawake` so the phone does not sleep. Packaged with a LaunchDaemon, `snapclient-ctl` and `/var/jb/etc/snapclient.conf`. |
| `ios_client/snapswitch/` | Auto-switch daemon for the phones: polls each computer's Snapcast control port (1705) every second and moves the phone to whichever one is currently playing (Mac ↔ Windows, AirPods-style). Re-finds a computer whose DHCP address changed. |
| `tools/snapserver/` | Patch + build script for a Mac `snapserver` that does not reset the stream timeline on every late timer wake-up (that reset caused all phones to resync several times per 10 minutes). |
| `tools/sysaudio/` | `sysbridge` (Mac system audio → 7-channel pipe, Atmos fold-down, presets), `blackhole_7_1_4.patch` (12-ch virtual device with a 7.1.4 layout and a real latency report for video sync), `avlatency` (measures output latency). |
| `tools/spatial_tools/` | Python (numpy) measurement and calibration: test-signal generator, Snapcast JSON-RPC control, recording analysis (per-device offset, drift, jitter, pairwise skew), delay and level calibration. `python3 -m spatial_tools --help`, tests in `tools/tests`. |
| `tools/recorder/` | Small recorders: `macrec` (Mac mic) and `iosrec` (a jailbroken phone used as the calibration mic at your head position). |
| `tools/statusapp/` | macOS status/on-off app ("폰 스피커"): Wi-Fi, server connection and battery of every phone, plus on/off buttons. |
| `run/` | Double-click scripts for macOS (see the setup steps below). `run/phones.example.txt` → `run/phones.txt` holds your phone list. |
| `켜기.command` / `끄기.command` | Daily on / off for the Mac (켜기 = on, 끄기 = off). |
| `windows_host/` | Optional Windows sender: `snaphost.py` replaces the Mac's sysbridge + snapserver, `켜기.bat` / `끄기.bat` / `폰상태.bat` (on / off / phone status window). |
| `scripts/scan_personal.sh` | Scans the repo for LAN IPs, MAC addresses, UDIDs, keys, home paths and e-mails before you publish a fork. |

## Hardware you need

- **iPhones**: 2 to 7, jailbroken with [Dopamine](https://github.com/opa334/Dopamine) (rootless), with OpenSSH from Sileo.
  Tested on iPhone 11 Pro running iOS 16.2, 16.6.1, 17.3.1, 18.6, 18.6.2 and 26.0. The build targets iOS 15+, arm64.
  Keep them on chargers: they stay awake while the service runs.
- **Mac**: Apple Silicon recommended (tested on a MacBook Air M2, macOS 26). macOS 14.2+ for the system-audio tap.
  Needs Xcode (or the command line tools + `xcodebuild` for the virtual device), Homebrew, Python 3.10+.
- **Wi-Fi**: all devices on the same LAN; 5 GHz strongly recommended. Seven uncompressed 7-ch streams is a lot of traffic.
- **Calibration mic**: the Mac's built-in mic works if you can put the Mac at your seat; otherwise one extra jailbroken iPhone as a remote mic.
- **Optional Windows PC**: Windows 10/11, Python 3 with `numpy` and `sounddevice`, [VB-CABLE](https://vb-audio.com/Cable/).

## Setup (Mac)

1. **Prepare the Mac.** Double-click `run/01_setup.command` (installs `snapcast` and `ffmpeg` with Homebrew, creates `tools/.venv`, runs the tests).
   Then build the patched server: `tools/snapserver/build_mac.sh` → `tools/snapserver/snapserver` (the scripts fall back to Homebrew's `snapserver` if it is missing).
2. **Get the phone package.** Either download the `.deb` from the GitHub Releases page into `ios_client/dist/`, or build it:
   `ios_client/build.sh` (macOS with Homebrew `cmake ninja pkgconf dpkg`, or Ubuntu with clang/lld 18). It downloads the Snapcast source, the theos iOS SDK, Boost, libFLAC and ldid.
3. **Prepare each phone (by hand).** Jailbreak with Dopamine, install OpenSSH, set the `mobile` password, join the same Wi-Fi, and trust the Mac over USB.
4. **Install each phone.** Plug it in by USB and double-click `run/14_add_phone.command`, then pick its seat number
   (1 FL, 2 FR, 3 C, 4 SL, 5 SR, 6 HL, 7 HR, or `m` for the calibration-mic phone). It creates an SSH key if needed
   (`~/.ssh/spatial_phones_ed25519`, change it in `run/config.sh`), installs your public key and a limited passwordless sudo rule,
   installs the package, sets `NAME/SERVER/CHANNEL`, enables the daemon and records the phone in `run/phones.txt`. No sound is played.
5. **Create the virtual device and try it.** `run/10_atmos.command` builds the 12-channel "SpatialPhones" device from BlackHole 0.7.2 source
   plus `tools/sysaudio/blackhole_7_1_4.patch` and installs it (asks for your Mac password once, restarts Core Audio). It then plays the Mac's sound on the phones until you close the window.
6. **Calibrate at your seat.** `run/06_desk_calib.command` (timing; plays short chimes from each phone and records them; use `MIC_PHONE=<ip>` for a phone mic),
   then `run/09_level_calib.command` (level, pink noise). Results go to `presets/desk.json`. `run/08_phone_volume.command` adjusts levels by ear.
7. **Video sync (optional).** `run/16_video_sync.command` reinstalls the device so it reports the real ~1.1 s latency; browsers and QuickTime then delay the picture to match.
8. **Daily use.** `켜기.command` (on) / `끄기.command` (off), or build the status app with `run/20_phone_app.command`. `run/19_phone_status.command` prints a status table.
   `run/17_atmos_check.command` speaks each channel name from its seat so you can check the wiring.
   `run/07_mac_audio.command` is the driver-free alternative (stereo system audio via a Core Audio process tap, upmixed).

## Setup (Windows, optional)

1. Install Python 3, `pip install numpy sounddevice`, and VB-CABLE. Run `windows_host/cable71.ps1` once to set the cable to 7.1 / 48 kHz / 16-bit.
2. Edit `windows_host/config.json`: `mac_ip` (or `mac_wifi_mac`) so the PC can hand the phones back to the Mac, and copy `delay_ms` / `gain_db` from the Mac's `presets/desk.json`.
3. Create a key on the PC (`ssh-keygen -t ed25519 -f %USERPROFILE%\.ssh\id_ed25519_phones`), copy the `.pub` to the Mac as `run/pc_key.pub`,
   copy `windows_host/mac_add_pc_key.command` into `run/` and double-click it. Or use `phones.ps1 addkey <ip>` on the PC (asks each phone's password).
4. Build the volume helper: `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /out:volwatch.exe volwatch.cs`.
5. `켜기.bat` / `끄기.bat` switch the phones to the PC and back; `폰상태.bat` opens a status window.
6. For automatic switching instead, run `run/21_auto_switch.command [PC_IP]` on the Mac: it installs `snapswitch` on every phone. Each phone then follows whichever computer is currently playing (Mac wins if both start at once).

## Caveats

- **A jailbreak is required** on every phone, and a reboot drops it (re-run Dopamine). Phones that are not jailbroken cannot run the daemon.
- **One channel per phone, one speaker per phone.** iPhones have two small speakers; using both gave a ~7 ms double image, so the default is `--speaker 2`. There is no subwoofer channel (LFE is dropped) and very little bass. It is 5.0.2, not a real 7.1.4 system: side+rear and the four height channels are folded together.
- **Latency is about 1.1–1.2 s** (Snapcast buffer 1000 ms). Fine for music and, after `run/16`, for video; not for games or live monitoring.
- **Sync numbers are from one room.** In the author's room, calibration brought arrival differences at the seat from ~10 ms to ~0.4 ms across 7 phones and kept them under ~0.6 ms after reconnecting. Your Wi-Fi, phones and room will differ.
- **Dolby Atmos**: a 7.1.4 Atmos test file in QuickTime reached all channels. Atmos from the Music app itself was not verified (only stereo from the web player).
- **Security**: phones run OpenSSH; the sudo rule allows `snapclient-ctl`, `launchctl` and `dpkg` without a password, which is effectively root for anyone holding your SSH key. Snapcast ports 1704/1705 are unauthenticated: use only on a trusted LAN.
- **Battery**: phones are kept awake and play continuously; keep them on chargers and watch the temperature.
- iOS 18/26 and other models beyond those listed above are untested. Package IDs are `io.github.jangcuber.snapclient` and `io.github.jangcuber.snapswitch`.

## Privacy check before you share your fork

Personal values live only in ignored files: `run/config.sh`, `run/phones.txt`, `presets/*.json`, `run/logs/`, `recordings/`,
`windows_host/state/`, `windows_host/logs/`. Run `scripts/scan_personal.sh` before pushing.

## License

GPL-3.0 (see `LICENSE`), because the phone client and server are modified Snapcast (GPL-3.0) and the virtual device is modified BlackHole (GPL-3.0).
See `NOTICE.md` for upstream credits.

---

## 한국어 요약

탈옥한 아이폰 여러 대(최대 7대)를 **무선 서라운드 스피커**로 쓰는 프로젝트입니다. Mac(또는 윈도우 PC)이 앰프 역할을 하고,
폰 한 대가 5.0.2 채널(FL FR C SL SR HL HR) 중 하나를 냅니다. Snapcast를 고쳐서 씁니다(폰: snapclient 데몬, Mac: snapserver).
마이크로 청취 자리에서 도착 시각·음량을 재서 맞춥니다.

**필요한 것**: Dopamine(rootless) 탈옥 아이폰 2~7대 + OpenSSH, Apple Silicon Mac(macOS 14.2+, Xcode, Homebrew), 같은 Wi-Fi(5 GHz 권장).
윈도우는 선택(VB-CABLE, Python).

**순서**: `run/01_setup.command` → 패키지 빌드(`ios_client/build.sh`) 또는 Releases에서 받기 → 폰마다 USB로 꽂고 `run/14_add_phone.command`
→ `run/10_atmos.command`(가상 장치 설치) → `run/06_desk_calib.command`, `run/09_level_calib.command`(보정) → 평소엔 `켜기.command` / `끄기.command`.
Mac·윈도우 자동 전환은 `run/21_auto_switch.command`.

**주의**: 탈옥 필수(재부팅하면 다시 탈옥), 폰마다 한 채널·한 스피커(저음 거의 없음, LFE 버림), 지연 약 1.1초(게임 부적합),
동기 수치는 작성자 방 기준, Music 앱 Atmos는 미확인, SSH 키를 가진 사람은 폰 root 권한과 같음, 1704/1705 포트는 인증 없음(믿을 수 있는 집 네트워크에서만).
개인 설정은 git에 안 올라가는 `run/config.sh`, `run/phones.txt`, `presets/*.json`에만 들어가며, 올리기 전에 `scripts/scan_personal.sh`로 확인하세요.
