# ios_client — 탈옥 아이폰용 snapclient

Snapcast 공식 클라이언트(snapclient, GPL-3.0)를 Dopamine(rootless) 탈옥 iOS용으로 빌드한 것입니다.
유료 App Store 앱 대신 쓰며, 백그라운드 데몬으로 돌아갑니다.

| 파일 | 내용 |
|---|---|
| `snapcast-ios.patch` | snapcast `4fed179`(2026-06-12)에 대한 수정: iOS 빌드 대상, AVAudioSession(Playback, 무음 스위치 무시), `--channel` 옵션, iOS에 없는 macOS API 제외 |
| `build.sh` | 재현 빌드 (Linux x86_64에서 검증). SDK·boost·ldid를 받아 `.deb` 생성 |
| `pkg/` | 패키지 구성: 래퍼, `snapclient-ctl`, LaunchDaemon, 설정 파일 |
| `keepawake.c` | 화면이 꺼져도 폰이 잠들지 않게 전원 assertion을 쥐는 작은 도우미(sa6). 래퍼가 snapclient와 함께 띄움 |
| `dist/*.deb` | 빌드 결과 (iphoneos-arm64, 최소 iOS 15) |

## 설치 후 폰에 생기는 것

- `/var/jb/usr/bin/snapclient` — 클라이언트 (ad-hoc 서명, entitlements: platform-application 등)
- `/var/jb/etc/snapclient.conf` — `NAME`(서버에 보일 이름), `SERVER`(Mac IP, 비우면 Bonjour 자동 검색), `CHANNEL`, `LATENCY`, `EXTRA_ARGS`, `KEEPAWAKE`(기본 1), `STATS`(1 = 1초마다 동기 상태 로그)
- `/var/jb/usr/bin/keepawake` — 서버가 꺼진 동안 폰이 잠들면 1초 재접속 타이머가 몇 분씩 멈춰서(2026-10-08 로그) 넣음. 화면은 꺼진 채 CPU·Wi-Fi만 깨어 있음. 업그레이드는 `dpkg -i --force-confold`(기존 설정 유지)
- `/var/jb/Library/LaunchDaemons/io.github.jangcuber.snapclient.plist` — mobile 사용자로 실행, 꺼지면 자동 재시작. 설치 직후에는 꺼져 있음
- `snapclient-ctl {enable|disable|start|stop|restart|status|log|test|set}` — 관리 명령. `sudo snapclient-ctl set NAME=node-03 SERVER=192.168.1.97` 로 설정 변경(무비밀번호 sudo 범위 안)
- 로그: `/var/mobile/Library/Logs/snapclient.log` (AVAudioSession 결과, 출력 지연값 포함)

설치는 `run/14_add_phone.command`가 SSH로 한 대씩 처리합니다(키·sudo 규칙 → 복사 → `dpkg -i` → 설정 → 자동 실행).

## `--channel`

7채널 스트림 하나를 7대가 함께 받고, 각 폰은 자기 채널만 상·하단 스피커에 똑같이 냅니다.
모든 폰이 같은 스트림·같은 타임스탬프를 쓰므로, 채널별로 스트림을 따로 보내는 방식보다 공통 시간축 문제가 적습니다.
설정 파일의 `CHANNEL=0~6` (FL, FR, C, SL, SR, HL, HR 순서).

## 실기 확인 상태 (작성자 환경, iPhone 11 Pro 7대)

- iOS 16.2 / 16.6.1 / 17.3.1 / 18.6 / 18.6.2 / 26.0 에서 데몬 재생·화면 잠금 중 재생 확인
- 아이폰 실제 출력 지연은 snapclient 추정값과 다르므로 마이크 보정(`run/06_desk_calib.command`)으로 맞춤
- 폰 스피커 두 개를 다 쓰면 약 7 ms 이중음이 생겨 `--speaker 2`(한쪽만) 사용

문제가 생기면 `snapclient-ctl log 100` 출력이 원인 파악에 가장 중요합니다.
